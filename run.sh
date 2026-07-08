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
# per-project key, shared with proxy/up.sh and config.sh. `make init` seeds it.
source "${SCRIPT_DIR}/scripts/paths.sh"
CONFIG_DIR="$(config_dir)"

# Refuse to run against an un-initialized config dir (points first-timers at
# `make init`). Sourced so it can `exit`. See the guard file.
source "${SCRIPT_DIR}/guards/config-initialized.sh"

# Pre-flight security guards, each sourced (not subprocessed) so it can abort the
# run with `exit` before any build/volume/container work. They read PROJECT_DIR /
# HOME / MCP_GH_BEARER / CLAUDE_ALLOW_PROJECT_SETTINGS from this scope.
source "${SCRIPT_DIR}/guards/no-home-dir.sh"
source "${SCRIPT_DIR}/guards/project-settings.sh"
source "${SCRIPT_DIR}/guards/mcp-bearer-readonly.sh"

# 1. Build the image when missing or when the build context changed. A SHA-256
#    of the key files is stored as an image label at build time; each run
#    recomputes it and rebuilds on mismatch.
context_hash() {
  local files=(
    "${SCRIPT_DIR}/Dockerfile"
    "${SCRIPT_DIR}/entrypoint.sh"
    "${SCRIPT_DIR}/init-firewall.sh"
    "${SCRIPT_DIR}/install_additional_packages.sh"
    "${SCRIPT_DIR}/package.json"
    "${SCRIPT_DIR}/package-lock.json"
  )
  local existing=()
  for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done
  # Include caller identity: the image embeds host UID/GID/username via
  # --build-arg, so a different user must get a fresh image.
  { if command -v sha256sum >/dev/null 2>&1; then sha256sum "${existing[@]}"
    else shasum -a 256 "${existing[@]}"; fi
    printf 'uid=%s gid=%s user=%s\n' "$(id -u)" "$(id -g)" "$(id -un)"
  } | sha256sum | cut -c1-16
}

CURRENT_HASH="$(context_hash)"
BASE_IMAGE_HASH="$(docker image inspect "${BASE_IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"

if [[ "$BASE_IMAGE_HASH" != "$CURRENT_HASH" ]]; then
  [[ -n "$BASE_IMAGE_HASH" ]] && echo ">> Build context changed — rebuilding ${BASE_IMAGE}..." \
                              || echo ">> Building ${BASE_IMAGE}..."
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
echo ">> session volume: ${VOLUME}  (docker volume inspect ${VOLUME})"

# 2b. Container name: readable base + random suffix, so several sessions can run
#     in the same folder against the SAME shared volume without colliding on
#     --name (decoupled from VOLUME). Throwaway since --rm. Two $RANDOM give 30
#     bits, ample for concurrent containers. Override with CLAUDE_CONTAINER_NAME.
CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-${SAFE_NAME:-repo}-$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")}"
echo ">> container name: ${CONTAINER_NAME}"

# 2c. Per-project config dir: <config-dir>/projects/<safe-name>-<path-hash>/.
#     Files here override root-level defaults file-by-file (more specific wins);
#     created and seeded on first run. Overrides: allowed-domains.txt, .env,
#     container-CLAUDE.md, install_additional_packages.sh. See `config.sh project`.
PROJECT_KEY="$(project_key "${PROJECT_DIR}")"
# Base dir for all per-project config dirs (see scripts/paths.sh). Override with
# CLAUDE_PROJECTS_DIR (the test suite points this at a throwaway dir).
PROJECTS_DIR="$(projects_dir)"
PROJECT_CONFIG_DIR="${PROJECTS_DIR}/${PROJECT_KEY}"
if [[ ! -d "${PROJECT_CONFIG_DIR}" ]]; then
  mkdir -p "${PROJECT_CONFIG_DIR}"
  echo ">> created per-project config dir: ${PROJECT_CONFIG_DIR}"
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
  # Empty per-project allowlist; Squid already applies the baseline (see 3f).
  touch "${PROJECT_CONFIG_DIR}/allowed-domains.txt"
else
  echo ">> per-project config dir: ${PROJECT_CONFIG_DIR}"
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
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "${_PROJECT_INSTALL}"
      else shasum -a 256 "${_PROJECT_INSTALL}"; fi
    } | sha256sum | cut -c1-16
  )"
  DERIVED_IMAGE_HASH="$(docker image inspect "${DERIVED_IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"
  if [[ "${DERIVED_IMAGE_HASH}" != "${DERIVED_HASH}" ]]; then
    [[ -n "${DERIVED_IMAGE_HASH}" ]] && echo ">> project install script changed — rebuilding ${DERIVED_IMAGE}..." \
                                      || echo ">> building per-project image ${DERIVED_IMAGE}..."
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
  echo ">> per-project image: ${IMAGE}"
fi

# 3. Config mounts, added only if the host path exists.
RO_MOUNTS=()
add_ro_mount() {  # <host_path> <container_path>
  if [ -e "$1" ]; then RO_MOUNTS+=(--volume "$1:$2:ro")
  else echo ">> skipping (not found on host): $1" >&2; fi
}
add_rw_mount() {  # <host_path> <container_path>
  if [ -e "$1" ]; then RO_MOUNTS+=(--volume "$1:$2")
  else echo ">> skipping (not found on host): $1" >&2; fi
}
# --- harmless config to share (edit as needed) ---
# Each file lives in the config dir, seeded by `make init`, mounted only if
# present. View with `config.sh list` / `config.sh show <file>`.
add_ro_mount "${CONFIG_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
add_rw_mount "${CONFIG_DIR}/claude.json"   "${HOME_IN_CONTAINER}/.claude.json"
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
  echo "ERROR: no mcp-servers.json found in ${PROJECT_CONFIG_DIR} or ${CONFIG_DIR}" >&2
  echo "  Run \`make init\` to seed the baseline one, then re-run." >&2
  exit 1
fi
add_ro_mount "${MCP_FILE}" "${HOME_IN_CONTAINER}/.mcp-servers.json"
echo ">> mcp config: ${MCP_FILE}"

# 3b. Extra project mounts. scripts/extra-mounts.sh turns CLAUDE_MOUNTS (comma-
#     separated host folders) into `--volume=...` tokens; see it for the syntax
#     (ro default, ":rw"/":ro", ~ and relative paths). The primary repo and
#     session volume are unaffected; usage tracking keys off the primary repo.
while IFS= read -r vol; do
  RO_MOUNTS+=("$vol")
done < <(
  PROJECT_DIR="${PROJECT_DIR}" \
  HOME_IN_CONTAINER="${HOME_IN_CONTAINER}" \
  REPO_IN_CONTAINER="${REPO_IN_CONTAINER}" \
  "${SCRIPT_DIR}/scripts/extra-mounts.sh"
)

# 3c. Published ports. scripts/extra-ports.sh turns CLAUDE_PORTS into --publish
#     specs so the host can reach a server in the container. Each line is
#     "<spec>\t<cport/proto>": the spec becomes --publish; the container ports go
#     into CONTAINER_OPEN_PORTS for the firewall to open explicitly (its INPUT
#     policy is DROP — publishing alone isn't enough). See that script's syntax.
PUBLISH_ARGS=()
OPEN_PORTS=()
while IFS=$'\t' read -r spec cport; do
  [[ -z "$spec" ]] && continue
  PUBLISH_ARGS+=(--publish "$spec")
  OPEN_PORTS+=("$cport")
done < <(CLAUDE_PORTS="${CLAUDE_PORTS:-}" "${SCRIPT_DIR}/scripts/extra-ports.sh")
CONTAINER_OPEN_PORTS="$(IFS=,; printf '%s' "${OPEN_PORTS[*]+${OPEN_PORTS[*]}}")"

# 3d. In-repo paths backed by named volumes — SECURE BY DEFAULT. Each path gets
#     its own per-project volume mounted at that path INSIDE the repo bind mount,
#     so it lives only in the container/volume and NOT on the host — keeping
#     installed (untrusted) packages off the host disk while persisting them
#     across runs. Nesting a volume over the bind mount is standard Docker (the
#     deeper mount wins). A fresh volume is root-owned, so we chown it to the
#     runtime UID once on creation (the entrypoint can't — no NET_ADMIN here).
#
#     By default every package.json dir is covered (find-node-modules-paths.sh);
#     non-JS projects just pay one cheap find. Add paths via CLAUDE_VOLUME_PATHS
#     (comma-separated, repo-relative; "auto" re-triggers the scan). Opt out with
#     SKIP_CLAUDE_VOLUME_PATHS set to any non-empty value.
VOLUME_PATH_MOUNTS=()
_seen_vol_paths=" "
prepare_path_volume() {  # <repo-relative path>
  local rel="$1" name target
  case "$rel" in
    /*|*..*|"~"*) echo ">> skipping volume path (must be repo-relative, no '..' or '~'): $rel" >&2; return ;;
  esac
  case "$_seen_vol_paths" in *" ${rel} "*) return ;; esac   # dedup (auto + explicit may overlap)
  _seen_vol_paths+="${rel} "
  # If the host already holds files here, the volume masks them in the container
  # but the host copy persists — warn so the host can be kept clean.
  if [ -n "$(ls -A "${PROJECT_DIR}/${rel}" 2>/dev/null)" ]; then
    echo ">> WARNING: ${rel} already has contents on the host; the volume hides them in the container but the host copy remains — delete it to keep the host clean." >&2
  fi
  name="claude-vol-${SAFE_NAME:-repo}-$(path_hash "${PROJECT_DIR}/${rel}")"
  target="${REPO_IN_CONTAINER}/${rel}"
  if ! docker volume inspect "$name" >/dev/null 2>&1; then
    docker volume create "$name" >/dev/null
    docker run --rm --user 0:0 --entrypoint chown \
      --volume "${name}:/v" "${IMAGE}" "$(id -u):$(id -g)" /v
    echo ">> created path volume: ${name} -> ${target}" >&2
  fi
  VOLUME_PATH_MOUNTS+=(--volume "${name}:${target}")
}
expand_auto() {  # back ./node_modules for every package.json dir in the project
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && prepare_path_volume "$_p"
  done < <("${SCRIPT_DIR}/scripts/find-node-modules-paths.sh" "${PROJECT_DIR}")
}
if [[ -n "${SKIP_CLAUDE_VOLUME_PATHS:-}" ]]; then
  echo ">> SKIP_CLAUDE_VOLUME_PATHS set — not isolating in-repo paths; node_modules etc. will land on the host" >&2
else
  expand_auto  # secure by default
  # plus any user-specified extra paths
  if [[ -n "${CLAUDE_VOLUME_PATHS:-}" ]]; then
    IFS=',' read -r -a _vol_paths <<< "${CLAUDE_VOLUME_PATHS}"
    for rel in ${_vol_paths[@]+"${_vol_paths[@]}"}; do
      rel="${rel#"${rel%%[![:space:]]*}"}"; rel="${rel%"${rel##*[![:space:]]}"}"  # trim
      rel="${rel#./}"; rel="${rel%/}"                                              # tidy ./ and trailing /
      [[ -z "$rel" ]] && continue
      if [[ "$rel" == "auto" ]]; then expand_auto; else prepare_path_volume "$rel"; fi
    done
  fi
fi

# 3e. Env vars from the config-dir `.env` via `docker --env-file`. A per-project
#     projects/<key>/.env takes precedence; the config-initialized guard
#     guarantees the baseline exists, so --env-file is unconditional (the file
#     may be empty). Emitted before the explicit `--env` flags so it can't
#     clobber them (last duplicate wins). See docs/passing-env-vars.md.
ENV_FILE="$(resolve_config_file .env)"
echo ">> env file: ${ENV_FILE}"

# 3f. Centralized egress proxy — the sole egress path. The container joins the
#     shared Squid network (proxy/up.sh); its HTTP(S)_PROXY points at Squid with
#     PROJECT_KEY as the proxy username, and EGRESS_PROXY_HOST tells
#     init-firewall.sh to lock egress to Squid only. Squid enforces this
#     project's allowed-domains.txt, keyed by that username. See docs/egress-proxy.md.
EGRESS_NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
EGRESS_PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
PROXY_URL="http://${PROJECT_KEY}:x@squid:3128"
# Bring the shared proxy up if it isn't already running (up.sh is idempotent).
if [[ "$(docker container inspect -f '{{.State.Running}}' "${EGRESS_PROXY_NAME}" 2>/dev/null || true)" != "true" ]]; then
  echo ">> egress proxy '${EGRESS_PROXY_NAME}' not running — starting it"
  # Forward config/projects locations so the proxy reads the SAME baseline
  # allowlist and per-project dirs that run.sh mounts from.
  CLAUDE_EGRESS_NETWORK="${EGRESS_NETWORK}" \
  CLAUDE_EGRESS_PROXY_NAME="${EGRESS_PROXY_NAME}" \
  CLAUDE_DOCKER_CONFIG_DIR="${CONFIG_DIR}" \
  CLAUDE_PROJECTS_DIR="${PROJECTS_DIR}" \
    "${SCRIPT_DIR}/proxy/up.sh"
fi
PROXY_NET_ARGS=(--network "${EGRESS_NETWORK}")
PROXY_ENV_ARGS=(
  --env "HTTP_PROXY=${PROXY_URL}"   --env "http_proxy=${PROXY_URL}"
  --env "HTTPS_PROXY=${PROXY_URL}"  --env "https_proxy=${PROXY_URL}"
  --env "NO_PROXY=localhost,127.0.0.1,::1,host.docker.internal"
  --env "no_proxy=localhost,127.0.0.1,::1,host.docker.internal"
  --env "EGRESS_PROXY_HOST=squid"
)
echo ">> egress via central proxy: network ${EGRESS_NETWORK}, project key ${PROJECT_KEY}"

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
  ${PROXY_NET_ARGS[@]+"${PROXY_NET_ARGS[@]}"} \
  --env-file "${ENV_FILE}" \
  ${PROXY_ENV_ARGS[@]+"${PROXY_ENV_ARGS[@]}"} \
  --env HOME="${HOME_IN_CONTAINER}" \
  --env COLORTERM=truecolor \
  --env CLAUDE_HOST_PROJECT_DIR="${PROJECT_DIR}" \
  --env MCP_GH_BEARER \
  --env CONTAINER_OPEN_PORTS="${CONTAINER_OPEN_PORTS}" \
  --env SOUND_PORT="${SOUND_PORT:-4767}" \
  ${PUBLISH_ARGS[@]+"${PUBLISH_ARGS[@]}"} \
  --volume "${PROJECT_DIR}:${REPO_IN_CONTAINER}" \
  ${VOLUME_PATH_MOUNTS[@]+"${VOLUME_PATH_MOUNTS[@]}"} \
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
    echo ">> WARNING: usage sync failed — run ${SCRIPT_DIR}/usage.sh to retry" >&2
  fi
fi

exit "${STATUS}"
