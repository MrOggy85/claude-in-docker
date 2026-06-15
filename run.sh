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

IMAGE="claude-code:local"
HOME_IN_CONTAINER="/home/dev"
REPO_IN_CONTAINER="${HOME_IN_CONTAINER}/repo"
HOST_CLAUDE_DIR="${HOME}/.claude"

# Directory of THIS script = build context (where the Dockerfile lives), kept
# separate from $(pwd) so you can run the script from any project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# Guard: refuse to run from the user's home directory to prevent accidental
# exposure of home directory contents to the container.
if [[ "${PROJECT_DIR}" == "${HOME}" ]]; then
  echo "ERROR: Running claude-in-docker from your home directory is not allowed." >&2
  echo "  This would mount your entire home directory into the container," >&2
  echo "  defeating the purpose of the sandboxed environment." >&2
  echo "  Please cd into a project subdirectory first." >&2
  exit 1
fi

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

# 2b. Container name: human-readable base (no path hash) + a random suffix, so
#     several sessions can run in the same folder against the SAME shared volume
#     without colliding on --name. Decoupled from VOLUME on purpose. The
#     container is removed on exit (--rm), so the suffix is throwaway. $RANDOM is
#     a bash builtin (no pipe → safe under pipefail); two of them give 30 bits,
#     ample for a handful of concurrent containers. Override with
#     CLAUDE_CONTAINER_NAME=... to pin a specific name.
CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-${SAFE_NAME:-repo}-$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")}"
echo ">> container name: ${CONTAINER_NAME}"

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
add_ro_mount "${SCRIPT_DIR}/container-CLAUDE.md" "${HOME_IN_CONTAINER}/.claude/CLAUDE.md"
add_ro_mount "${SCRIPT_DIR}/.gitconfig"      "${HOME_IN_CONTAINER}/.gitconfig"

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
    /*|*..*) echo ">> skipping volume path (must be repo-relative, no '..'): $rel" >&2; return ;;
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
  --env HOME="${HOME_IN_CONTAINER}" \
  --env COLORTERM=truecolor \
  --env MCP_GH_BEARER \
  --env CONTAINER_OPEN_PORTS="${CONTAINER_OPEN_PORTS}" \
  ${PUBLISH_ARGS[@]+"${PUBLISH_ARGS[@]}"} \
  --volume "${PROJECT_DIR}:${REPO_IN_CONTAINER}" \
  ${VOLUME_PATH_MOUNTS[@]+"${VOLUME_PATH_MOUNTS[@]}"} \
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
