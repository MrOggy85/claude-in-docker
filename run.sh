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

# 1. Build the image once (rebuild manually with: docker build -t claude-code:local "$SCRIPT_DIR").
#    The image bakes in NO user/UID, so this same image works on macOS and Debian.
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo ">> Building ${IMAGE} (first run only)..."
  docker build --tag "${IMAGE}" "${SCRIPT_DIR}"
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

# 3. Read-only config mounts, added only if the host path exists.
RO_MOUNTS=()
add_ro_mount() {  # <host_path> <container_path>
  if [ -e "$1" ]; then RO_MOUNTS+=(--volume "$1:$2:ro")
  else echo ">> skipping (not found on host): $1" >&2; fi
}
# --- harmless config to share (edit as needed) ---
add_ro_mount "${SCRIPT_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
add_ro_mount "${SCRIPT_DIR}/claude.json"   "${HOME_IN_CONTAINER}/.claude.json"
add_ro_mount "${HOME}/.claude/CLAUDE.md"     "${HOME_IN_CONTAINER}/.claude/CLAUDE.md"
# add_ro_mount "${HOME}/.claude/commands"      "${HOME_IN_CONTAINER}/.claude/commands"
add_ro_mount "${HOME}/.gitconfig"            "${HOME_IN_CONTAINER}/.gitconfig"
add_ro_mount "${SCRIPT_DIR}/sounds"          "${HOME_IN_CONTAINER}/sounds"

# Retrieve a secret from macOS Keychain
# Usage: sec-get "Entry Name"
function keychain_get {
  local entry="$1"

  if [[ -z "$entry" ]]; then
    echo "Usage: sec-get \"Entry Name\""
    return 1
  fi

  security find-generic-password -a "$USER" -s "$entry" -w
}

# 4. Run as your host UID:GID; HOME forced so "~" resolves for the passwd-less UID.
#    The named volume mounts the whole ~/.claude; RO files layer on top of it.
#    "${ARR[@]+...}" keeps it safe under `set -u` on macOS bash 3.2.
exec docker run \
  --interactive --tty --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME="${HOME_IN_CONTAINER}" \
  --env CLAUDE_CODE_OAUTH_TOKEN="$(keychain_get "claude_ouath_token")" \
  --env COLORTERM=truecolor \
  --volume "${PROJECT_DIR}:${REPO_IN_CONTAINER}" \
  --volume "${VOLUME}:${HOME_IN_CONTAINER}/.claude" \
  ${RO_MOUNTS[@]+"${RO_MOUNTS[@]}"} \
  --workdir "${REPO_IN_CONTAINER}" \
  "${IMAGE}" \
  claude "$@"
