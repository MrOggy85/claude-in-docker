#!/usr/bin/env bash
#
# Run Claude Code in Docker as YOUR host user, so any files it creates in the
# mounted project are owned by you (not root).
#
# Mounts:
#   - $(pwd)    -> /home/dev/repo     (the project you launch this from)
#   - ~/.claude -> /home/dev/.claude  (your settings/config/credentials)
#   - $CLAUDE_MOUNTS                   (optional extra folders, see step 3b)
# By default every node_modules location is backed by a named volume and hidden
# from the host (step 3d). Add more in-repo paths with $CLAUDE_VOLUME_PATHS, or
# opt out with $SKIP_CLAUDE_VOLUME_PATHS.
# Working dir is set to /home/dev/repo, then `claude` runs.
#
# All script arguments are forwarded verbatim to `claude`. Extra host folders
# are mounted via the CLAUDE_MOUNTS env var (not flags), so they don't consume
# any positional args meant for claude.

set -euo pipefail

BASE_IMAGE="claude-code:local"
HOME_IN_CONTAINER="/home/dev"
REPO_IN_CONTAINER="${HOME_IN_CONTAINER}/repo"
HOST_CLAUDE_DIR="${HOME}/.claude"

# Directory of THIS script = build context (where the Dockerfile lives), kept
# separate from $(pwd) so you can run the script from any project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# Pre-flight security guards. Each lives in guards/ and is sourced (not run as a
# subprocess) so it can abort the whole run with `exit` before any build, volume,
# or container work happens. They read PROJECT_DIR / HOME / MCP_GH_BEARER /
# CLAUDE_ALLOW_PROJECT_SETTINGS from this scope. See each file for details.
source "${SCRIPT_DIR}/guards/no-home-dir.sh"
source "${SCRIPT_DIR}/guards/project-settings.sh"
source "${SCRIPT_DIR}/guards/mcp-bearer-readonly.sh"

# 1. Build the image when it doesn't exist or when the build context has changed.
#    A SHA-256 hash of the key files is stored as an image label at build time;
#    on each run we recompute it and rebuild if it differs.
context_hash() {
  local files=(
    "${SCRIPT_DIR}/Dockerfile"
    "${SCRIPT_DIR}/entrypoint.sh"
    "${SCRIPT_DIR}/init-firewall.sh"
    "${SCRIPT_DIR}/allowed-domains.txt"
    "${SCRIPT_DIR}/install_additional_packages.sh"
    "${SCRIPT_DIR}/package.json"
    "${SCRIPT_DIR}/package-lock.json"
  )
  # Filter to files that actually exist, then hash them
  local existing=()
  for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done
  # Include caller identity: the image embeds the host UID/GID/username via
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
#    The hash disambiguates same-named dirs in different locations; the name is
#    stable so re-running in this folder reuses the same volume (enables resume).
#    Override with CLAUDE_VOLUME=... if you want a specific/throwaway one.
path_hash() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-10
  else printf '%s' "$1" | shasum -a 256 | cut -c1-10; fi
}
SAFE_NAME="$(printf '%s' "$(basename "${PROJECT_DIR}")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
SAFE_NAME="$(printf '%s' "${SAFE_NAME}" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
VOLUME="${CLAUDE_VOLUME:-claude-${SAFE_NAME:-repo}-$(path_hash "${PROJECT_DIR}")}"
echo ">> session volume: ${VOLUME}  (docker volume inspect ${VOLUME})"

# 2b. Container name: human-readable base (no path hash) + a random suffix, so
#     several sessions can run in the same folder against the SAME shared volume
#     without colliding on --name. Decoupled from VOLUME on purpose. The
#     container is removed on exit (--rm), so the suffix is throwaway. $RANDOM is
#     a bash builtin (no pipe → safe under pipefail); two of them give 30 bits,
#     ample for a handful of concurrent containers. Override with
#     CLAUDE_CONTAINER_NAME=... to pin a specific name.
CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-${SAFE_NAME:-repo}-$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")}"
echo ">> container name: ${CONTAINER_NAME}"

# 2c. Per-project config directory: projects/<safe-name>-<path-hash>/ inside the
#     claude-in-docker repo. Files placed here override the root-level defaults on
#     a file-by-file basis (more specific wins). The directory is created — and
#     seeded with editable starting points — automatically on first run.
#     Supported overrides: allowed-domains.txt, .env, container-CLAUDE.md,
#     install_additional_packages.sh
PROJECT_KEY="${SAFE_NAME:-repo}-$(path_hash "${PROJECT_DIR}")"
# Base dir holding all per-project config dirs. Defaults to projects/ next to
# run.sh; override with CLAUDE_PROJECTS_DIR (the test suite points this at a
# throwaway dir so test runs never write into the repo's projects/).
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${SCRIPT_DIR}/projects}"
PROJECT_CONFIG_DIR="${PROJECTS_DIR}/${PROJECT_KEY}"
if [[ ! -d "${PROJECT_CONFIG_DIR}" ]]; then
  mkdir -p "${PROJECT_CONFIG_DIR}"
  # Seed an install_additional_packages.sh stub. While it holds only comments /
  # blank lines it counts as empty (see 2d) and the shared base image is used
  # as-is; add real commands and the next run bakes them into a per-project image.
  cat > "${PROJECT_CONFIG_DIR}/install_additional_packages.sh" <<'STUB'
#!/bin/bash
#
# Per-project packages. Add commands below and the next run bakes them into a
# per-project Docker image (FROM the shared base), so they install once at build
# time instead of on every container start. While this file holds only comments
# and blank lines it is treated as empty and the base image is used unchanged.
#
# Example:
#   set -euo pipefail
#   curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s v2.3.1
STUB
  # Seed allowed-domains.txt: prefer the active root list, else the committed
  # template (the root copy is gitignored and absent on a fresh checkout). It is
  # mounted over /etc/allowed-domains.txt at runtime (see 3f) — edit, no rebuild.
  _seed_domains="${SCRIPT_DIR}/allowed-domains.txt"
  [[ -f "${_seed_domains}" ]] || _seed_domains="${SCRIPT_DIR}/templates/allowed-domains.txt"
  [[ -f "${_seed_domains}" ]] && \
    cp "${_seed_domains}" "${PROJECT_CONFIG_DIR}/allowed-domains.txt"
  echo ">> created per-project config dir: ${PROJECT_CONFIG_DIR}"
  echo ">>   edit install_additional_packages.sh / allowed-domains.txt there to"
  echo ">>   override defaults; .env and container-CLAUDE.md also work"
else
  echo ">> per-project config dir: ${PROJECT_CONFIG_DIR}"
fi

# Returns the per-project path if the file exists there, otherwise the root path.
resolve_config_file() {  # <filename>
  local fname="$1"
  if [[ -f "${PROJECT_CONFIG_DIR}/${fname}" ]]; then
    echo "${PROJECT_CONFIG_DIR}/${fname}"
  else
    echo "${SCRIPT_DIR}/${fname}"
  fi
}

# 2d. Per-project image. The base image (built above) already carries the
#     root-level install_additional_packages.sh. When a project supplies its OWN
#     install script, bake those packages into a thin image FROM the base — once,
#     at build time — so they persist instead of being reinstalled by the
#     entrypoint on every container start. The Dockerfile is generated on the fly
#     and piped in via `--file -`; nothing is written into the project dir. A
#     project whose script is still the all-comments stub counts as empty and
#     runs the base image directly.
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
# Each file is seeded by `make init` (run once) and mounted only if present.
add_ro_mount "${SCRIPT_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
add_rw_mount "${SCRIPT_DIR}/claude.json"   "${HOME_IN_CONTAINER}/.claude.json"
add_rw_mount "${SCRIPT_DIR}/.credentials.json" "${HOME_IN_CONTAINER}/.claude/.credentials.json"
add_ro_mount "$(resolve_config_file container-CLAUDE.md)" "${HOME_IN_CONTAINER}/.claude/CLAUDE.md"
add_ro_mount "${SCRIPT_DIR}/.gitconfig"      "${HOME_IN_CONTAINER}/.gitconfig"
# Convention-based global gitignore: git reads ~/.config/git/ignore automatically
# when core.excludesFile is unset (XDG default), so this needs no .gitconfig entry.
# Mounted only if the user has created one (gitignored; seeded by `make init`).
add_ro_mount "${SCRIPT_DIR}/.gitignore_global" "${HOME_IN_CONTAINER}/.config/git/ignore"

# 3a. MCP servers from a dedicated file, kept OUT of the mutable claude.json
#     state blob. mcp-servers.json holds just {"mcpServers": {...}}; we mount it
#     read-only and point `claude --mcp-config` at it, so it's the single source
#     of truth — edit it and the next container start picks up the change, no
#     rebuild. A per-project projects/<key>/mcp-servers.json overrides the root
#     copy. ${MCP_GH_BEARER} inside the file is still expanded by claude from the
#     container env. See docs/mcp-servers.md.
MCP_ARGS=()
_MCP_FILE="$(resolve_config_file mcp-servers.json)"
if [[ -f "${_MCP_FILE}" ]]; then
  add_ro_mount "${_MCP_FILE}" "${HOME_IN_CONTAINER}/.mcp-servers.json"
  MCP_ARGS=(--mcp-config "${HOME_IN_CONTAINER}/.mcp-servers.json")
  echo ">> mcp config: ${_MCP_FILE}"
fi

# 3b. Extra project mounts. scripts/extra-mounts.sh turns CLAUDE_MOUNTS (a
#     comma-separated list of host folders) into `--volume=...` tokens, one per
#     line, which we append to the mount list. See that script for the syntax
#     (read-only default, ":rw"/":ro", ~ and relative paths). The primary repo
#     and the per-project session volume are unaffected; usage tracking still
#     keys off the primary repo only.
while IFS= read -r vol; do
  RO_MOUNTS+=("$vol")
done < <(
  PROJECT_DIR="${PROJECT_DIR}" \
  HOME_IN_CONTAINER="${HOME_IN_CONTAINER}" \
  REPO_IN_CONTAINER="${REPO_IN_CONTAINER}" \
  "${SCRIPT_DIR}/scripts/extra-mounts.sh"
)

# 3c. Published ports. scripts/extra-ports.sh turns CLAUDE_PORTS (a
#     comma-separated list) into `docker run --publish` specs so the host can
#     reach a server inside the container. Each line is "<spec>\t<cport/proto>":
#     the spec becomes a --publish flag; the container ports are collected into
#     CONTAINER_OPEN_PORTS and passed to the in-container firewall, which must
#     open them explicitly (its INPUT policy is DROP — publishing alone is not
#     enough). See that script for the entry syntax.
PUBLISH_ARGS=()
OPEN_PORTS=()
while IFS=$'\t' read -r spec cport; do
  [[ -z "$spec" ]] && continue
  PUBLISH_ARGS+=(--publish "$spec")
  OPEN_PORTS+=("$cport")
done < <(CLAUDE_PORTS="${CLAUDE_PORTS:-}" "${SCRIPT_DIR}/scripts/extra-ports.sh")
CONTAINER_OPEN_PORTS="$(IFS=,; printf '%s' "${OPEN_PORTS[*]+${OPEN_PORTS[*]}}")"

# 3d. In-repo paths backed by named volumes — SECURE BY DEFAULT. Each path gets
#     its own per-project named volume mounted at that path INSIDE the bind-
#     mounted repo, so the path lives only in the container/volume and NOT on the
#     host — keeping installed (untrusted) packages off the host disk while
#     persisting them across runs. Nesting a volume over the repo bind mount is a
#     standard Docker pattern (no conflict; the deeper mount wins for that
#     subtree). A fresh volume is root-owned, so we chown it to the runtime UID
#     once on creation (bypassing the entrypoint, which needs NET_ADMIN it isn't
#     granted here).
#
#     By default every node_modules location is covered automatically: each
#     directory containing a package.json (scripts/find-node-modules-paths.sh).
#     Non-JS projects just pay one cheap find. Add more paths (e.g. a Deno cache)
#     via CLAUDE_VOLUME_PATHS (comma-separated, repo-relative; "auto" re-triggers
#     the node_modules scan). Opt OUT entirely by setting SKIP_CLAUDE_VOLUME_PATHS
#     to any non-empty value (e.g. 1 or true).
VOLUME_PATH_MOUNTS=()
_seen_vol_paths=" "
prepare_path_volume() {  # <repo-relative path>
  local rel="$1" name target
  case "$rel" in
    /*|*..*|"~"*) echo ">> skipping volume path (must be repo-relative, no '..' or '~'): $rel" >&2; return ;;
  esac
  case "$_seen_vol_paths" in *" ${rel} "*) return ;; esac   # dedup (auto + explicit may overlap)
  _seen_vol_paths+="${rel} "
  # If the host already holds files here, the volume masks them inside the
  # container but the host copy persists — warn so the host can be kept clean.
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

# 3e. Optional arbitrary env vars from a gitignored `.env` next to run.sh, via
#     `docker --env-file`. Per-project .env in projects/<key>/.env takes
#     precedence when present. Emitted before the explicit `--env` flags so it
#     can't clobber them (last duplicate wins). See docs/passing-env-vars.md.
ENV_FILE="$(resolve_config_file .env)"
ENV_FILE_ARGS=()
if [ -f "$ENV_FILE" ]; then
  ENV_FILE_ARGS+=(--env-file "$ENV_FILE")
  echo ">> env file: ${ENV_FILE}"
fi

# 3f. Per-project allowed-domains.txt: if present, mount it over the baked-in
#     /etc/allowed-domains.txt so the firewall uses the project-specific list.
_PROJECT_DOMAINS="${PROJECT_CONFIG_DIR}/allowed-domains.txt"
if [[ -f "${_PROJECT_DOMAINS}" ]]; then
  RO_MOUNTS+=(--volume "${_PROJECT_DOMAINS}:/etc/allowed-domains.txt:ro")
  echo ">> per-project allowed-domains.txt: ${_PROJECT_DOMAINS}"
fi

# (Per-project install packages are baked into a derived image at build time;
#  see 2d. There is no longer a runtime install mount.)

# 3g. Centralized egress proxy (opt-in via CLAUDE_EGRESS_PROXY). When enabled,
#     the container egresses through the shared Squid proxy (proxy/up.sh) rather
#     than the per-container IP allowlist: it joins the proxy network, its
#     HTTP(S)_PROXY points at Squid carrying PROJECT_KEY as the proxy username,
#     and EGRESS_PROXY_HOST flips init-firewall.sh into proxy mode (egress
#     allowed only to Squid). Squid enforces this project's allowed-domains.txt,
#     keyed by that username. See docs/egress-proxy.md.
PROXY_NET_ARGS=()
PROXY_ENV_ARGS=()
case "${CLAUDE_EGRESS_PROXY:-}" in
  1|true|yes|on|TRUE|YES|ON)
    EGRESS_NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
    EGRESS_PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
    PROXY_URL="http://${PROJECT_KEY}:x@squid:3128"
    # Bring the shared proxy up if it isn't already running (up.sh is idempotent).
    if [[ "$(docker container inspect -f '{{.State.Running}}' "${EGRESS_PROXY_NAME}" 2>/dev/null || true)" != "true" ]]; then
      echo ">> egress proxy '${EGRESS_PROXY_NAME}' not running — starting it"
      CLAUDE_EGRESS_NETWORK="${EGRESS_NETWORK}" \
      CLAUDE_EGRESS_PROXY_NAME="${EGRESS_PROXY_NAME}" \
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
    ;;
esac

# 4. Run as your host UID:GID; HOME forced so "~" resolves for the passwd-less UID.
#    NET_ADMIN is required for iptables/ipset; it is only exercisable via the
#    sudo rule scoped to /usr/local/bin/init-firewall.sh — no other escalation
#    is possible from the non-root runtime user.
#    "${ARR[@]+...}" keeps it safe under `set -u` on macOS bash 3.2.
# Run without `exec` so control returns to this script after the session ends,
# allowing the usage archive to be updated below.
STATUS=0
docker run \
  --name "${CONTAINER_NAME}" \
  --interactive --tty --rm \
  --user "$(id -u):$(id -g)" \
  --cap-add=NET_ADMIN \
  ${PROXY_NET_ARGS[@]+"${PROXY_NET_ARGS[@]}"} \
  ${ENV_FILE_ARGS[@]+"${ENV_FILE_ARGS[@]}"} \
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
  claude ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} "$@" || STATUS=$?

# 5. Copy this session's usage records into the shared archive
#    (~/.claude-docker-usage) so `ccusage` can read them from the host. The
#    transform lives in sync-volume.sh (shared with usage.sh): an allowlist that
#    keeps only the cost fields ccusage reads, with cwd relabeled to
#    /home/dev/<PROJ> for per-project reporting — conversation text, tool I/O,
#    file snapshots, and attachments never leave the volume. See usage.sh for
#    the same sync across every volume, plus the report. Set CLAUDE_AUTO_USAGE=0
#    (or false/no/off) to skip.
case "${CLAUDE_AUTO_USAGE:-1}" in 0|false|no|off|FALSE|NO|OFF) AUTO_USAGE=0 ;; *) AUTO_USAGE=1 ;; esac
if [[ "${AUTO_USAGE}" == "1" ]]; then
  ARCHIVE="${CLAUDE_USAGE_DIR:-${HOME}/.claude-docker-usage}"
  if ! IMAGE="${IMAGE}" "${SCRIPT_DIR}/sync-volume.sh" "${VOLUME}" "${SAFE_NAME:-repo}" "${ARCHIVE}"; then
    echo ">> WARNING: usage sync failed — run ${SCRIPT_DIR}/usage.sh to retry" >&2
  fi
fi

exit "${STATUS}"
