#!/usr/bin/env bash
#
# Run Claude Code in Docker as YOUR host user, so files it creates in the mounted
# project ($(pwd) -> /home/dev/repo) are owned by you, not root. Working dir is
# that mount; `claude` runs there.
#
# Script args are forwarded verbatim to `claude`. Extra host folders mount via
# CLAUDE_MOUNTS (env, not flags) so they don't consume claude's positional args.

set -euo pipefail

BASE_IMAGE="claude-code:local"
HOME_IN_CONTAINER="/home/dev"
REPO_IN_CONTAINER="${HOME_IN_CONTAINER}/repo"

# Directory of THIS script = build context (where the Dockerfile lives), kept
# separate from $(pwd) so you can run the script from any project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# User-managed config lives OUTSIDE the repo, under an XDG-style dir. See
# scripts/paths.sh — the single source of truth for that location and the
# per-project key, shared with proxy/up.sh and cid. `make init` seeds it.
source "${SCRIPT_DIR}/scripts/paths.sh"
CONFIG_DIR="$(config_dir)"

# Every message below — and in the guards, which are sourced into this scope —
# goes through the emitters in scripts/colors.sh: say/kv/ok on stdout,
# warn/fail on stderr. See that file for the grammar and the palette.
source "${SCRIPT_DIR}/scripts/colors.sh"
color_init 1

# Refuse to run against an un-initialized config dir (points first-timers at
# `make init`). Sourced so it can `exit`. See the guard file.
source "${SCRIPT_DIR}/guards/config-initialized.sh"

# Pre-flight security guards, each sourced (not subprocessed) so it can abort the
# run with `exit` before any build/volume/container work. They read PROJECT_DIR /
# HOME / MCP_GH_BEARER / CLAUDE_ALLOW_PROJECT_SETTINGS / CLAUDE_DOCKER_BRIDGE /
# CLAUDE_CHROME_DEVTOOLS from this scope.
source "${SCRIPT_DIR}/guards/no-home-dir.sh"
source "${SCRIPT_DIR}/guards/project-settings.sh"
source "${SCRIPT_DIR}/guards/mcp-bearer-no-push.sh"
source "${SCRIPT_DIR}/guards/docker-bridge.sh"
source "${SCRIPT_DIR}/guards/chrome-devtools.sh"
# Sets EGRESS_CA_CRT, used just below and at step 4.
source "${SCRIPT_DIR}/guards/egress-ca.sh"

# 0. The container must trust the CA the proxy signs intercepted TLS with, and
#    the only way into the image is the build context (= this repo dir), so the
#    PUBLIC half is copied here — the same exception install_additional_packages.sh
#    makes, for the same reason. Gitignored, derived, never edited by hand;
#    context_hash below covers it, so rotating the CA rebuilds the image.
#    See docs/tls-inspection.md.
CA_IN_CONTEXT="${SCRIPT_DIR}/egress-ca.crt"
if ! cmp -s "${EGRESS_CA_CRT}" "${CA_IN_CONTEXT}"; then
  cp "${EGRESS_CA_CRT}" "${CA_IN_CONTEXT}"
  kv "egress CA copied into the build context" "${CA_IN_CONTEXT}" "image will rebuild"
fi

# 1. Build the image when missing or when the build context changed. A SHA-256
#    of the key files is stored as an image label at build time; each run
#    recomputes it and rebuilds on mismatch.
context_hash() {
  local files=(
    "${SCRIPT_DIR}/Dockerfile"
    "${SCRIPT_DIR}/entrypoint.sh"
    "${SCRIPT_DIR}/init-firewall.sh"
    "${SCRIPT_DIR}/install_additional_packages.sh"
    "${CA_IN_CONTEXT}"
    "${SCRIPT_DIR}/package.json"
    "${SCRIPT_DIR}/package-lock.json"
  )
  local existing=()
  for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done
  # Include caller identity: the image embeds host UID/GID/username via
  # --build-arg, so a different user must get a fresh image.
  { sha256_ "${existing[@]}"
    printf 'uid=%s gid=%s user=%s\n' "$(id -u)" "$(id -g)" "$(id -un)"
  } | sha256_ - | cut -c1-16
}

CURRENT_HASH="$(context_hash)"
BASE_IMAGE_HASH="$(docker image inspect "${BASE_IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"

if [[ "$BASE_IMAGE_HASH" != "$CURRENT_HASH" ]]; then
  if [[ -n "$BASE_IMAGE_HASH" ]]; then kv "rebuilding — build context changed" "${BASE_IMAGE}"
  else                                 kv "building" "${BASE_IMAGE}"
  fi
  docker build \
    --tag "${BASE_IMAGE}" \
    --label "build.context-hash=${CURRENT_HASH}" \
    --build-arg "USER_ID=$(id -u)" \
    --build-arg "GROUP_ID=$(id -g)" \
    --build-arg "USERNAME=$(id -un)" \
    "${SCRIPT_DIR}"
fi

# 2. Stable per-project volume name: claude-<dirname>-<short hash of full path>.
#    The hash disambiguates same-named dirs; the stable name lets re-running in
#    this folder reuse the volume (enables resume). Override with CLAUDE_VOLUME.
#    path_hash()/safe_name() come from scripts/paths.sh.
SAFE_NAME="$(safe_name "${PROJECT_DIR}")"
VOLUME="${CLAUDE_VOLUME:-claude-${SAFE_NAME:-repo}-$(path_hash "${PROJECT_DIR}")}"
kv "session volume" "${VOLUME}" "docker volume inspect ${VOLUME}"

# 2b. Container name: readable base + random suffix, so several sessions can run
#     in the same folder against the SAME shared volume without colliding on
#     --name (decoupled from VOLUME). Throwaway since --rm. Two $RANDOM give 30
#     bits, ample for concurrent containers. Override with CLAUDE_CONTAINER_NAME.
CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-${SAFE_NAME:-repo}-$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")}"
kv "container name" "${CONTAINER_NAME}"

# 2c. Per-project config dir: <config-dir>/projects/<safe-name>-<path-hash>/.
#     Files here override root-level defaults file-by-file (more specific wins);
#     created and seeded on first run. Overrides: allowed-domains.txt, .env,
#     container-CLAUDE.md, install_additional_packages.sh. See `cid project`.
PROJECT_KEY="$(project_key "${PROJECT_DIR}")"
# Base dir for all per-project config dirs (see scripts/paths.sh). Override with
# CLAUDE_PROJECTS_DIR (the test suite points this at a throwaway dir).
PROJECTS_DIR="$(projects_dir)"
PROJECT_CONFIG_DIR="${PROJECTS_DIR}/${PROJECT_KEY}"
if [[ ! -d "${PROJECT_CONFIG_DIR}" ]]; then
  mkdir -p "${PROJECT_CONFIG_DIR}"
  kv "created per-project config dir" "${PROJECT_CONFIG_DIR}"
else
  kv "per-project config dir" "${PROJECT_CONFIG_DIR}"
fi
# Seed per FILE, not per directory: a guard may already have written into this
# dir (guards/project-settings.sh records its approval there) before we get here.
if [[ ! -e "${PROJECT_CONFIG_DIR}/install_additional_packages.sh" ]]; then
  # Seed an install_additional_packages.sh stub. While comments/blank-only it
  # counts as empty (see 2d) and the base image is used as-is; add commands and
  # the next run bakes them into a per-project image.
  cat > "${PROJECT_CONFIG_DIR}/install_additional_packages.sh" <<'STUB'
#!/bin/bash
#
# Per-project packages.
# Add commands below and the next run bakes them into per-project Docker image (FROM the shared base).
# Installed once at build time.
# Comments/blank lines only = treated as empty, base image used unchanged.
#
# Example:
#   set -euo pipefail
#   curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s v2.3.1
STUB
fi
# Empty per-project allowlist; Squid already applies the baseline (see 3f).
[[ -e "${PROJECT_CONFIG_DIR}/allowed-domains.txt" ]] || touch "${PROJECT_CONFIG_DIR}/allowed-domains.txt"
# Private per-project claude.json: Claude Code keys its own trust/onboarding
# state and MCP-server approvals in this file by working-directory path, but
# every project mounts at the SAME in-container path, so a single shared file
# would collapse every project onto that one key (one project's MCP approval
# could silently apply to an unrelated one). Seed from the global file on
# first run so existing onboarding state carries over; from then on mutations
# stay local to this project. See docs/attack-vectors.md.
if [[ ! -e "${PROJECT_CONFIG_DIR}/claude.json" ]]; then
  if [[ -f "${CONFIG_DIR}/claude.json" ]]; then
    cp "${CONFIG_DIR}/claude.json" "${PROJECT_CONFIG_DIR}/claude.json"
  else
    echo '{}' > "${PROJECT_CONFIG_DIR}/claude.json"
  fi
fi

# Returns the per-project path if the file exists there, otherwise the root path.
resolve_config_file() {  # <filename>
  local fname="$1"
  if [[ -f "${PROJECT_CONFIG_DIR}/${fname}" ]]; then
    echo "${PROJECT_CONFIG_DIR}/${fname}"
  else
    echo "${CONFIG_DIR}/${fname}"
  fi
}

# 2d. Per-project image. The base image already carries the root-level install
#     script. When a project supplies its OWN, bake those packages into a thin
#     image FROM the base — once, at build time — so they persist across
#     container starts. The Dockerfile is generated on the fly and piped via
#     `--file -`; nothing is written into the project dir. An all-comments stub
#     counts as empty and runs the base image directly.
IMAGE="${BASE_IMAGE}"
_PROJECT_INSTALL="${PROJECT_CONFIG_DIR}/install_additional_packages.sh"
# "active" = at least one line that is neither blank nor a pure comment.
if [[ -f "${_PROJECT_INSTALL}" ]] && grep -qvE '^[[:space:]]*(#.*)?$' "${_PROJECT_INSTALL}"; then
  DERIVED_IMAGE="claude-code:${PROJECT_KEY}"
  # Rebuild when either the base context or the project script changes.
  DERIVED_HASH="$(
    { printf '%s\n' "${CURRENT_HASH}"
      sha256_ "${_PROJECT_INSTALL}"
    } | sha256_ - | cut -c1-16
  )"
  DERIVED_IMAGE_HASH="$(docker image inspect "${DERIVED_IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"
  if [[ "${DERIVED_IMAGE_HASH}" != "${DERIVED_HASH}" ]]; then
    if [[ -n "${DERIVED_IMAGE_HASH}" ]]; then kv "rebuilding — project install script changed" "${DERIVED_IMAGE}"
    else                                      kv "building per-project image" "${DERIVED_IMAGE}"
    fi
    docker build \
      --tag "${DERIVED_IMAGE}" \
      --label "build.context-hash=${DERIVED_HASH}" \
      --file - \
      "${PROJECT_CONFIG_DIR}" <<DOCKERFILE
FROM ${BASE_IMAGE}
COPY install_additional_packages.sh /usr/local/bin/project-install.sh
RUN chmod +x /usr/local/bin/project-install.sh \\
 && /usr/local/bin/project-install.sh \\
 && rm -f /usr/local/bin/project-install.sh
DOCKERFILE
  fi
  IMAGE="${DERIVED_IMAGE}"
  kv "per-project image" "${IMAGE}"
fi

# 3. Config mounts, added only if the host path exists.
RO_MOUNTS=()
add_ro_mount() {  # <host_path> <container_path>
  if [ -e "$1" ]; then RO_MOUNTS+=(--volume "$1:$2:ro")
  else kv "skipping (not found on host)" "$1"; fi
}
add_rw_mount() {  # <host_path> <container_path>
  if [ -e "$1" ]; then RO_MOUNTS+=(--volume "$1:$2")
  else kv "skipping (not found on host)" "$1"; fi
}
# --- harmless config to share (edit as needed) ---
# Each file lives in the config dir, seeded by `make init`, mounted only if
# present. View with `cid list` / `cid show <file>`.
add_ro_mount "${CONFIG_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
# Per-project (seeded above), not from CONFIG_DIR directly — see the seeding block.
add_rw_mount "${PROJECT_CONFIG_DIR}/claude.json" "${HOME_IN_CONTAINER}/.claude.json"
add_rw_mount "${CONFIG_DIR}/.credentials.json" "${HOME_IN_CONTAINER}/.claude/.credentials.json"
add_ro_mount "$(resolve_config_file container-CLAUDE.md)" "${HOME_IN_CONTAINER}/.claude/CLAUDE.md"
add_ro_mount "${CONFIG_DIR}/.gitconfig"      "${HOME_IN_CONTAINER}/.gitconfig"
# Convention-based global gitignore: git reads ~/.config/git/ignore automatically
# when core.excludesFile is unset (XDG default), so this needs no .gitconfig entry.
# Mounted only if the user has created one (seeded by `make init`).
add_ro_mount "${CONFIG_DIR}/.gitignore_global" "${HOME_IN_CONTAINER}/.config/git/ignore"

# 3a. MCP servers from a dedicated file, kept OUT of the mutable claude.json
#     state blob. mcp-servers.json holds just {"mcpServers": {...}}, mounted
#     read-only with `claude --mcp-config` pointed at it. Required (a per-project
#     copy overrides the root); ${MCP_GH_BEARER} is expanded by claude from the
#     container env. See docs/mcp-servers.md.
MCP_FILE="$(resolve_config_file mcp-servers.json)"
if [[ ! -f "${MCP_FILE}" ]]; then
  fail "no mcp-servers.json found in ${PROJECT_CONFIG_DIR} or ${CONFIG_DIR}" \
       "Run \`make init\` to seed the baseline one, then re-run."
  exit 1
fi
add_ro_mount "${MCP_FILE}" "${HOME_IN_CONTAINER}/.mcp-servers.json"
kv "mcp config" "${MCP_FILE}"

# 3b. Extra project mounts. scripts/extra-mounts.sh turns CLAUDE_MOUNTS (comma-
#     separated host folders) into `--volume=...` tokens; see it for the syntax
#     (ro default, ":rw"/":ro", ~ and relative paths). The primary repo and
#     session volume are unaffected; usage tracking keys off the primary repo.
#     Each token is also recorded as "<target>=<host path>:<mode>" for the sandbox
#     skill to report (see 3h).
EXTRA_MOUNT_LIST=()
while IFS= read -r vol; do
  RO_MOUNTS+=("$vol")
  _spec="${vol#--volume=}"          # <host>:<target>:<mode>
  _tgt="${_spec#*:}"; _tgt="${_tgt%:*}"
  EXTRA_MOUNT_LIST+=("${_tgt}=${_spec%%:*}:${_spec##*:}")
done < <(
  PROJECT_DIR="${PROJECT_DIR}" \
  HOME_IN_CONTAINER="${HOME_IN_CONTAINER}" \
  REPO_IN_CONTAINER="${REPO_IN_CONTAINER}" \
  "${SCRIPT_DIR}/scripts/extra-mounts.sh"
)

# 3c. Published ports. scripts/extra-ports.sh turns CLAUDE_PORTS into --publish
#     specs so the host can reach a server in the container. Each line is
#     "<spec>\t<cport/proto>\t<host endpoint>": the spec becomes --publish; the
#     container ports go into CONTAINER_OPEN_PORTS for the firewall to open
#     explicitly (its INPUT policy is DROP — publishing alone isn't enough); the
#     host endpoint is the one part the container cannot derive, so the full
#     mapping goes in too for the sandbox skill to report (see 3h). See that
#     script's syntax.
PUBLISH_ARGS=()
OPEN_PORTS=()
PUBLISHED_PORTS=()
while IFS=$'\t' read -r spec cport hostep; do
  [[ -z "$spec" ]] && continue
  PUBLISH_ARGS+=(--publish "$spec")
  OPEN_PORTS+=("$cport")
  PUBLISHED_PORTS+=("${hostep}:${cport}")
done < <(CLAUDE_PORTS="${CLAUDE_PORTS:-}" "${SCRIPT_DIR}/scripts/extra-ports.sh")
CONTAINER_OPEN_PORTS="$(IFS=,; printf '%s' "${OPEN_PORTS[*]+${OPEN_PORTS[*]}}")"
CONTAINER_PUBLISHED_PORTS="$(IFS=,; printf '%s' "${PUBLISHED_PORTS[*]+${PUBLISHED_PORTS[*]}}")"

# 3c-b. Host-outbound ports. The container egresses only via Squid (see 3f),
#       except for direct connections to the Docker host on this explicit port
#       allowlist. SOUND_PORT (default 4767, the host sound server) is merged with
#       any CLAUDE_HOST_OUTBOUND_PORTS the user sets; init-firewall.sh opens one
#       OUTPUT rule per port. See docs/host-outbound-ports.md.
CONTAINER_HOST_OUTBOUND_PORTS="${SOUND_PORT:-4767}${CLAUDE_HOST_OUTBOUND_PORTS:+,${CLAUDE_HOST_OUTBOUND_PORTS}}"
# Labels for the ports whose purpose is known here, so the sandbox skill can name
# them instead of printing a bare number (see 3h). The user's own entries stay
# unlabelled; CHROME_DEVTOOLS_MCP_PORT is labelled only if they opened it.
CONTAINER_HOST_PORT_LABELS="${SOUND_PORT:-4767}=sound server"
# The trailing-comma pattern also accepts a "/tcp" suffix on the user's entry.
case ",${CLAUDE_HOST_OUTBOUND_PORTS:-}," in
  *",${CHROME_DEVTOOLS_MCP_PORT:-9333},"*|*",${CHROME_DEVTOOLS_MCP_PORT:-9333}/tcp,"*)
    CONTAINER_HOST_PORT_LABELS+=",${CHROME_DEVTOOLS_MCP_PORT:-9333}=chrome-devtools MCP bridge (browser runs on the host)" ;;
esac

# 3c-c. Host docker bridge — OPT-IN, off by default. CLAUDE_DOCKER_BRIDGE=1 mints
#       a per-project token, forwards it, and opens the bridge port; with the
#       switch off there is no firewall rule, so the port is unreachable even if
#       the host daemon is running. The token both authenticates and identifies the
#       project: the bridge maps it to this project's docker-containers.txt, so the
#       container never asserts which allowlist applies to it. Exported and passed
#       by bare name (like MCP_GH_BEARER) to keep it out of `docker run`'s argv,
#       which host `ps` exposes. Sanity checks live in guards/docker-bridge.sh;
#       see docs/docker-bridge.md.
DOCKER_BRIDGE_ARGS=()
case "${CLAUDE_DOCKER_BRIDGE:-}" in
  1|true|yes|on|TRUE|YES|ON)
    _DB_PORT="${DOCKER_BRIDGE_PORT:-9334}"
    _DB_TOKEN_FILE="${PROJECT_CONFIG_DIR}/docker-bridge.token"
    if [[ ! -s "${_DB_TOKEN_FILE}" ]]; then
      # 32 random bytes, hex. od+/dev/urandom rather than openssl: no extra dep.
      od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "${_DB_TOKEN_FILE}"
      chmod 600 "${_DB_TOKEN_FILE}"
      kv "minted docker bridge token" "${_DB_TOKEN_FILE}"
    fi
    DOCKER_BRIDGE_TOKEN="$(cat "${_DB_TOKEN_FILE}")"
    export DOCKER_BRIDGE_TOKEN
    DOCKER_BRIDGE_ARGS=(--env DOCKER_BRIDGE_TOKEN)
    CONTAINER_HOST_OUTBOUND_PORTS+=",${_DB_PORT}"
    CONTAINER_HOST_PORT_LABELS+=",${_DB_PORT}=read-only docker bridge"
    kv "docker bridge" "read-only docker via host.docker.internal:${_DB_PORT}"
    ;;
esac

# 3c-d. Host chrome-devtools bridge — OPT-IN, off by default, same shape as the
#       docker bridge above: CLAUDE_CHROME_DEVTOOLS=1 mints a per-project token,
#       forwards it, and opens the bridge port (with the switch off there is no
#       firewall rule, so the port is unreachable even if the host daemon runs).
#       The token identifies the project to the bridge, which picks that project's
#       Chrome profile — CLAUDE_CHROME_PROFILE names one within it, so two
#       containers on one project can each keep their own browser state. Token
#       passed by bare name (like MCP_GH_BEARER) to keep it out of `docker run`'s
#       argv, which host `ps` exposes. See docs/chrome-devtools-mcp.md.
CHROME_DEVTOOLS_ARGS=()
case "${CLAUDE_CHROME_DEVTOOLS:-}" in
  1|true|yes|on|TRUE|YES|ON)
    _CD_PORT="${CHROME_DEVTOOLS_MCP_PORT:-9333}"
    _CD_TOKEN_FILE="${PROJECT_CONFIG_DIR}/chrome-devtools.token"
    if [[ ! -s "${_CD_TOKEN_FILE}" ]]; then
      # 32 random bytes, hex. od+/dev/urandom rather than openssl: no extra dep.
      od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "${_CD_TOKEN_FILE}"
      chmod 600 "${_CD_TOKEN_FILE}"
      kv "minted chrome-devtools token" "${_CD_TOKEN_FILE}"
    fi
    CHROME_DEVTOOLS_MCP_TOKEN="$(cat "${_CD_TOKEN_FILE}")"
    # Host and container spell the same directory differently and the bridge runs
    # host-side, so a container filePath means nothing to it until translated.
    # Record the READ-WRITE bind mounts for it to map both ways; ro mounts are
    # left out deliberately — translating one would let the agent write, through
    # the host bridge, to a path its own container is denied. See
    # docs/chrome-devtools-mcp.md#file-outputs.
    {
      printf '%s\t%s\n' "${REPO_IN_CONTAINER}" "${PROJECT_DIR}"
      for _m in ${EXTRA_MOUNT_LIST[@]+"${EXTRA_MOUNT_LIST[@]}"}; do
        _hm="${_m#*=}"                    # "<host>:<mode>" (target is before '=')
        if [[ "${_hm##*:}" == "rw" ]]; then
          printf '%s\t%s\n' "${_m%%=*}" "${_hm%:*}"
        fi
      done
    } > "${PROJECT_CONFIG_DIR}/mounts.txt"
    # Always exported, so the ${CLAUDE_CHROME_PROFILE} expansion in
    # mcp-servers.json never resolves empty.
    CLAUDE_CHROME_PROFILE="${CLAUDE_CHROME_PROFILE:-default}"
    export CHROME_DEVTOOLS_MCP_TOKEN CLAUDE_CHROME_PROFILE
    CHROME_DEVTOOLS_ARGS=(--env CHROME_DEVTOOLS_MCP_TOKEN --env CLAUDE_CHROME_PROFILE)
    # Merged only if the user has not already listed it by hand (step 3c-b), which
    # would otherwise duplicate both the firewall rule and the label.
    case ",${CONTAINER_HOST_OUTBOUND_PORTS}," in
      *",${_CD_PORT},"*|*",${_CD_PORT}/tcp,"*) ;;
      *) CONTAINER_HOST_OUTBOUND_PORTS+=",${_CD_PORT}"
         CONTAINER_HOST_PORT_LABELS+=",${_CD_PORT}=chrome-devtools MCP bridge (browser runs on the host)" ;;
    esac
    kv "chrome-devtools bridge" "profile '${CLAUDE_CHROME_PROFILE}' via host.docker.internal:${_CD_PORT}"
    ;;
esac

# 3d. In-repo paths backed by named volumes — SECURE BY DEFAULT: node_modules and
#     pnpm's store live in per-project volumes, so installed (untrusted) packages
#     stay off the host disk yet persist across runs. Everything — the automatic
#     coverage, CLAUDE_VOLUME_PATHS, SKIP_CLAUDE_VOLUME_PATHS, volume creation, the
#     per-run ownership pass, pnpm's store — lives in the script; it prints one
#     `docker run` token per line. See it and docs/volume-backed-paths.md.
#
#     Command substitution, not process substitution: a failure in there must abort
#     the run, not silently start a container with an unwritable volume.
PATH_VOLUME_ARGS=()
_path_volume_out="$(
  PROJECT_DIR="${PROJECT_DIR}" \
  REPO_IN_CONTAINER="${REPO_IN_CONTAINER}" \
  IMAGE="${IMAGE}" \
  CLAUDE_VOLUME_PATHS="${CLAUDE_VOLUME_PATHS:-}" \
  SKIP_CLAUDE_VOLUME_PATHS="${SKIP_CLAUDE_VOLUME_PATHS:-}" \
    "${SCRIPT_DIR}/scripts/path-volumes.sh"
)"
#     The `--volume=` targets are also recorded for the sandbox skill (see 3h);
#     the `--env=` token pnpm gets is not a path, so it is skipped.
VOLUME_PATH_LIST=()
while IFS= read -r _tok; do
  [[ -n "${_tok}" ]] || continue
  PATH_VOLUME_ARGS+=("${_tok}")
  case "${_tok}" in --volume=*) VOLUME_PATH_LIST+=("${_tok##*:}") ;; esac
done <<< "${_path_volume_out}"

# 3e. Env vars from the config-dir `.env` via `docker --env-file`. A per-project
#     projects/<key>/.env takes precedence; the config-initialized guard
#     guarantees the baseline exists, so --env-file is unconditional (the file
#     may be empty). Emitted before the explicit `--env` flags so it can't
#     clobber them (last duplicate wins). See docs/passing-env-vars.md.
ENV_FILE="$(resolve_config_file .env)"
kv "env file" "${ENV_FILE}"

# 3f. Centralized egress proxy — the sole egress path. The container joins the
#     shared Squid network (proxy/up.sh); its HTTP(S)_PROXY points at Squid with
#     PROJECT_KEY as the proxy username, and EGRESS_PROXY_HOST tells
#     init-firewall.sh to lock egress to Squid only. Squid enforces this
#     project's allowed-domains.txt, keyed by that username. See docs/egress-proxy.md.
EGRESS_NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
EGRESS_PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
PROXY_URL="http://${PROJECT_KEY}:x@squid:3128"
# Bring the shared proxy up if it isn't already running, or recreate it if its
# HEALTHCHECK (proxy/Dockerfile) says the allowlist helper stopped answering —
# Docker itself acts on neither. up.sh is idempotent either way.
PROXY_STATE="$(docker container inspect \
  -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  "${EGRESS_PROXY_NAME}" 2>/dev/null || true)"
PROXY_ACTION=""
if [[ "${PROXY_STATE}" != true* ]]; then
  PROXY_ACTION="starting egress proxy (not running)"
elif [[ "${PROXY_STATE}" == *unhealthy ]]; then
  PROXY_ACTION="recreating egress proxy (unhealthy — allowlist helper not answering)"
fi
if [[ -n "${PROXY_ACTION}" ]]; then
  kv "${PROXY_ACTION}" "${EGRESS_PROXY_NAME}"
  # Forward config/projects locations so the proxy reads the SAME baseline
  # allowlist and per-project dirs that run.sh mounts from.
  CLAUDE_EGRESS_NETWORK="${EGRESS_NETWORK}" \
  CLAUDE_EGRESS_PROXY_NAME="${EGRESS_PROXY_NAME}" \
  CLAUDE_DOCKER_CONFIG_DIR="${CONFIG_DIR}" \
  CLAUDE_PROJECTS_DIR="${PROJECTS_DIR}" \
    "${SCRIPT_DIR}/proxy/up.sh"
fi
# 3f-2. Compromise detection, such as it can be: a host-side watcher on the
#     proxy's access log that notifies the moment any project reaches a host it
#     never has before, or is denied. Started here rather than installed, so it
#     is running whenever a session is; it survives this run.sh and is shared by
#     every project. Never fatal — a missing notifier must not block a session.
#     CLAUDE_EGRESS_ALERTS=0 disables it. See docs/egress-alerts.md.
case "${CLAUDE_EGRESS_ALERTS:-1}" in
  0|false|no|off|FALSE|NO|OFF) kv "egress alerts" "disabled (CLAUDE_EGRESS_ALERTS)" ;;
  *)
    CLAUDE_EGRESS_PROXY_NAME="${EGRESS_PROXY_NAME}" \
    CLAUDE_DOCKER_CONFIG_DIR="${CONFIG_DIR}" \
    CLAUDE_PROJECTS_DIR="${PROJECTS_DIR}" \
      "${SCRIPT_DIR}/proxy/watch.sh" start \
      || warn "egress alert watcher not started" \
              "First-time-host and denial alerts are OFF for this session." \
              "Check: cid watch status"
    ;;
esac

PROXY_NET_ARGS=(--network "${EGRESS_NETWORK}")
# The proxy decrypts TLS, so the container has to trust its CA. The image bakes it
# into the system store (see the Dockerfile); Node reads neither that nor
# SSL_CERT_FILE, so it gets the file by name here — the one runtime that fails
# silently otherwise, and the one `claude` itself runs on. Set at runtime, not as
# an image ENV, so a config-less build never warns about a missing file.
CONTAINER_CA_CRT="/usr/local/share/ca-certificates/claude-egress-ca.crt"
PROXY_ENV_ARGS=(
  --env "HTTP_PROXY=${PROXY_URL}"   --env "http_proxy=${PROXY_URL}"
  --env "HTTPS_PROXY=${PROXY_URL}"  --env "https_proxy=${PROXY_URL}"
  --env "NO_PROXY=localhost,127.0.0.1,::1,host.docker.internal"
  --env "no_proxy=localhost,127.0.0.1,::1,host.docker.internal"
  --env "EGRESS_PROXY_HOST=squid"
  --env "NODE_EXTRA_CA_CERTS=${CONTAINER_CA_CRT}"
)
kv "egress via central proxy" "network ${EGRESS_NETWORK}, project key ${PROJECT_KEY}"
kv "TLS intercepted by the proxy" "CA ${EGRESS_CA_CRT}" "exempt a host: cid skip-decryption add <host>"

# 3g. Resource limits — SECURE BY DEFAULT: cap memory, CPU and process count so a
#     runaway (or hostile) process is killed inside its OWN cgroup instead of
#     leaving the host's OOM killer to shoot whichever container is biggest, which
#     is usually a bystander. Defaults are derived from the Docker host and every
#     one is overridable; the script owns the derivation, the validation and the
#     "swap off" default. See it and docs/resource-limits.md.
#
#     Command substitution, like 3d: a malformed CLAUDE_MEMORY must abort the run,
#     not silently start an uncapped container.
LIMIT_ARGS=()
_limits_out="$(
  CLAUDE_MEMORY="${CLAUDE_MEMORY:-}" \
  CLAUDE_MEMORY_SWAP="${CLAUDE_MEMORY_SWAP:-}" \
  CLAUDE_CPUS="${CLAUDE_CPUS:-}" \
  CLAUDE_PIDS_LIMIT="${CLAUDE_PIDS_LIMIT:-}" \
    "${SCRIPT_DIR}/scripts/resource-limits.sh"
)"
#     The values are also handed to the sandbox skill (see 3h): a session that
#     hits a limit sees exit 137 and nothing else, so it needs to be able to read
#     the ceiling it just hit.
CONTAINER_MEMORY_LIMIT=""; CONTAINER_CPU_LIMIT=""; CONTAINER_PIDS_LIMIT=""
while IFS= read -r _tok; do
  [[ -n "${_tok}" ]] || continue
  LIMIT_ARGS+=("${_tok}")
  case "${_tok}" in
    --memory=*)      CONTAINER_MEMORY_LIMIT="${_tok#*=}" ;;
    --cpus=*)        CONTAINER_CPU_LIMIT="${_tok#*=}" ;;
    --pids-limit=*)  CONTAINER_PIDS_LIMIT="${_tok#*=}" ;;
  esac
done <<< "${_limits_out}"

# 3h. Sandbox self-awareness, ON DEMAND: mount the `sandbox` skill so the session
#     can look up the one thing it cannot derive — which host port maps to which
#     container port — plus its mounts, volume-backed paths, egress policy and how
#     to get a package installed instead of reaching for apt-get. The
#     skill's script reads the env vars collected above, so parallel sessions each
#     report their own shape with nothing generated on the host. A bind nested
#     under the ~/.claude volume; CLAUDE_SANDBOX_INFO=0 removes it entirely.
#     See docs/sandbox-info.md.
SANDBOX_ENV_ARGS=()
case "${CLAUDE_SANDBOX_INFO:-1}" in
  0|false|no|off|FALSE|NO|OFF) kv "sandbox skill" "disabled (CLAUDE_SANDBOX_INFO)" ;;
  *)
    add_ro_mount "${SCRIPT_DIR}/skills/sandbox" "${HOME_IN_CONTAINER}/.claude/skills/sandbox"
    SANDBOX_ENV_ARGS=(
      --env "CONTAINER_PUBLISHED_PORTS=${CONTAINER_PUBLISHED_PORTS}"
      --env "CONTAINER_HOST_PORT_LABELS=${CONTAINER_HOST_PORT_LABELS}"
      --env "CONTAINER_EXTRA_MOUNTS=$(IFS=,; printf '%s' "${EXTRA_MOUNT_LIST[*]+${EXTRA_MOUNT_LIST[*]}}")"
      --env "CONTAINER_VOLUME_PATHS=$(IFS=,; printf '%s' "${VOLUME_PATH_LIST[*]+${VOLUME_PATH_LIST[*]}}")"
      --env "REPO_IN_CONTAINER=${REPO_IN_CONTAINER}"
      # So the session reads a proxy-signed certificate as policy, not as an
      # attack, and knows `cid skip-decryption add` is the fix for a pinning client.
      --env "EGRESS_TLS_CA=${CONTAINER_CA_CRT}"
      # The host file to edit to add a system package (see 2d) — passed whether or
      # not it exists yet, since "create this file" is the answer either way.
      --env "CONTAINER_PROJECT_INSTALL_SCRIPT=${_PROJECT_INSTALL}"
      # The ceilings from 3g, so an exit 137 reads as policy rather than a crash.
      --env "CONTAINER_MEMORY_LIMIT=${CONTAINER_MEMORY_LIMIT}"
      --env "CONTAINER_CPU_LIMIT=${CONTAINER_CPU_LIMIT}"
      --env "CONTAINER_PIDS_LIMIT=${CONTAINER_PIDS_LIMIT}"
    )
    # Only when 2d actually derived one, so the session never claims a per-project
    # image that isn't in play.
    if [[ "${IMAGE}" != "${BASE_IMAGE}" ]]; then
      SANDBOX_ENV_ARGS+=(--env "CONTAINER_PROJECT_IMAGE=${IMAGE}")
    fi
    kv "sandbox skill" "the session can read its own ports/mounts on demand"
    ;;
esac

# 4. Run as your host UID:GID; HOME forced so "~" resolves for the passwd-less
#    UID. NET_ADMIN is needed for the nftables egress-lock, only exercisable via
#    the sudo rule scoped to init-firewall.sh — no other escalation is possible.
#    "${ARR[@]+...}" keeps it safe under `set -u` on macOS bash 3.2. No `exec` so
#    control returns here to update the usage archive below.
STATUS=0
docker run \
  --name "${CONTAINER_NAME}" \
  --interactive --tty --rm \
  --user "$(id -u):$(id -g)" \
  --cap-add=NET_ADMIN \
  ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} \
  ${PROXY_NET_ARGS[@]+"${PROXY_NET_ARGS[@]}"} \
  --env-file "${ENV_FILE}" \
  ${PROXY_ENV_ARGS[@]+"${PROXY_ENV_ARGS[@]}"} \
  --env HOME="${HOME_IN_CONTAINER}" \
  --env COLORTERM=truecolor \
  --env CLAUDE_HOST_PROJECT_DIR="${PROJECT_DIR}" \
  --env MCP_GH_BEARER \
  ${DOCKER_BRIDGE_ARGS[@]+"${DOCKER_BRIDGE_ARGS[@]}"} \
  ${CHROME_DEVTOOLS_ARGS[@]+"${CHROME_DEVTOOLS_ARGS[@]}"} \
  --env CONTAINER_OPEN_PORTS="${CONTAINER_OPEN_PORTS}" \
  --env CONTAINER_HOST_OUTBOUND_PORTS="${CONTAINER_HOST_OUTBOUND_PORTS}" \
  ${SANDBOX_ENV_ARGS[@]+"${SANDBOX_ENV_ARGS[@]}"} \
  ${PUBLISH_ARGS[@]+"${PUBLISH_ARGS[@]}"} \
  --volume "${PROJECT_DIR}:${REPO_IN_CONTAINER}" \
  ${PATH_VOLUME_ARGS[@]+"${PATH_VOLUME_ARGS[@]}"} \
  --volume "${VOLUME}:${HOME_IN_CONTAINER}/.claude" \
  ${RO_MOUNTS[@]+"${RO_MOUNTS[@]}"} \
  --workdir "${REPO_IN_CONTAINER}" \
  "${IMAGE}" \
  claude --mcp-config "${HOME_IN_CONTAINER}/.mcp-servers.json" "$@" || STATUS=$?

# 5. Copy this session's usage records into the shared archive so `ccusage` can
#    read them from the host. The transform lives in sync-volume.sh (shared with
#    usage.sh): an allowlist keeping only the cost fields, cwd relabeled to
#    /home/dev/<PROJ> — conversation text, tool I/O, and attachments never leave
#    the volume. Set CLAUDE_AUTO_USAGE=0 (or false/no/off) to skip.
case "${CLAUDE_AUTO_USAGE:-1}" in 0|false|no|off|FALSE|NO|OFF) AUTO_USAGE=0 ;; *) AUTO_USAGE=1 ;; esac
if [[ "${AUTO_USAGE}" == "1" ]]; then
  ARCHIVE="${CLAUDE_USAGE_DIR:-${HOME}/.claude-docker-usage}"
  if ! IMAGE="${IMAGE}" "${SCRIPT_DIR}/sync-volume.sh" "${VOLUME}" "${SAFE_NAME:-repo}" "${ARCHIVE}"; then
    warn "usage sync failed" "Run ${SCRIPT_DIR}/usage.sh to retry."
  fi
fi

exit "${STATUS}"
