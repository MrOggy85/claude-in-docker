#!/usr/bin/env bash
#
# Run Claude Code in Docker as YOUR host user, so any files it creates in the
# mounted project are owned by you (not root).
#
# Mounts:
#   - $(pwd)    -> /home/dev/repo     (the project you launch this from)
#   - ~/.claude -> /home/dev/.claude  (your settings/config/credentials)
# Working dir is set to /home/dev/repo, then `claude` runs.

set -euo pipefail

IMAGE="claude-code:local"
HOME_IN_CONTAINER="/home/dev"
REPO_IN_CONTAINER="${HOME_IN_CONTAINER}/repo"
HOST_CLAUDE_DIR="${HOME}/.claude"

# Directory of THIS script = build context (where the Dockerfile lives), kept
# separate from $(pwd) so you can run the script from any project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# 1. Build the image when it doesn't exist or when the build context has changed.
#    A SHA-256 hash of the key files is stored as an image label at build time;
#    on each run we recompute it and rebuild if it differs.
context_hash() {
  local files=(
    "${SCRIPT_DIR}/Dockerfile"
    "${SCRIPT_DIR}/entrypoint.sh"
    "${SCRIPT_DIR}/init-firewall.sh"
    "${SCRIPT_DIR}/allowed-domains.txt"
  )
  # Filter to files that actually exist, then hash them
  local existing=()
  for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "${existing[@]}"
  else shasum -a 256 "${existing[@]}"; fi | sha256sum | cut -c1-16
}

CURRENT_HASH="$(context_hash)"
IMAGE_HASH="$(docker image inspect "${IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"

if [[ "$IMAGE_HASH" != "$CURRENT_HASH" ]]; then
  [[ -n "$IMAGE_HASH" ]] && echo ">> Build context changed — rebuilding ${IMAGE}..." \
                          || echo ">> Building ${IMAGE}..."
  docker build --tag "${IMAGE}" --label "build.context-hash=${CURRENT_HASH}" "${SCRIPT_DIR}"
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
# Credentials persist across all projects via a single host file bind-mounted
# read-write over ~/.claude/.credentials.json (the rest of ~/.claude stays
# per-project). Pre-create it (seeded "{}", mode 600) so Docker mounts it as a
# file, not a directory, and `/login` writes the real token in place.
CRED_FILE="${SCRIPT_DIR}/.credentials.json"
[ -e "$CRED_FILE" ] || { printf '{}' > "$CRED_FILE"; chmod 600 "$CRED_FILE"; }

# --- harmless config to share (edit as needed) ---
add_ro_mount "${SCRIPT_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
add_rw_mount "${SCRIPT_DIR}/claude.json"   "${HOME_IN_CONTAINER}/.claude.json"
add_rw_mount "${CRED_FILE}"                 "${HOME_IN_CONTAINER}/.claude/.credentials.json"
add_ro_mount "${SCRIPT_DIR}/CLAUDE.md"       "${HOME_IN_CONTAINER}/.claude/CLAUDE.md"
add_ro_mount "${SCRIPT_DIR}/.gitconfig"      "${HOME_IN_CONTAINER}/.gitconfig"
add_ro_mount "${SCRIPT_DIR}/sound-effects/sounds" "${HOME_IN_CONTAINER}/sounds"

# 4. Run as your host UID:GID; HOME forced so "~" resolves for the passwd-less UID.
#    NET_ADMIN is required for iptables/ipset; it is only exercisable via the
#    sudo rule scoped to /usr/local/bin/init-firewall.sh — no other escalation
#    is possible from the non-root runtime user.
#    "${ARR[@]+...}" keeps it safe under `set -u` on macOS bash 3.2.
# Run without `exec` so control returns to this script after the session ends,
# allowing the usage archive to be updated below.
STATUS=0
docker run \
  --name "${VOLUME}" \
  --interactive --tty --rm \
  --user "$(id -u):$(id -g)" \
  --cap-add=NET_ADMIN \
  --env HOME="${HOME_IN_CONTAINER}" \
  --env COLORTERM=truecolor \
  --env MCP_GH_BEARER \
  --volume "${PROJECT_DIR}:${REPO_IN_CONTAINER}" \
  --volume "${VOLUME}:${HOME_IN_CONTAINER}/.claude" \
  ${RO_MOUNTS[@]+"${RO_MOUNTS[@]}"} \
  --workdir "${REPO_IN_CONTAINER}" \
  "${IMAGE}" \
  claude "$@" || STATUS=$?

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
