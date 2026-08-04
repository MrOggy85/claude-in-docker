#!/usr/bin/env bash
#
# Back in-repo paths with per-project named volumes, so anything an in-container
# install writes (node_modules, the pnpm store) lives in the volume and NOT on the
# host disk, while still persisting across runs. Emit the `docker run` arguments
# that mount them: one self-contained token per line on stdout
# (`--volume=<name>:<target>`, plus one `--env=` for pnpm), progress and warnings
# on stderr.
#
# SECURE BY DEFAULT: every package.json dir is covered with no configuration (see
# find-node-modules-paths.sh), as is pnpm's store, which otherwise defaults to a
# path in the project tree. Non-JS projects just pay one cheap `find`.
#
# Side effects: creates each missing volume and asserts ownership of ALL of them,
# created here or not. Both are fatal on failure, so run.sh aborts rather than
# starting a container whose volumes the runtime user cannot write.
#
# Inputs (environment):
#   PROJECT_DIR               host project dir                        (default: $PWD)
#   REPO_IN_CONTAINER         where PROJECT_DIR is mounted     (default: /home/dev/repo)
#   IMAGE                     image for the ownership pass  (default: claude-code:local)
#   CLAUDE_VOLUME_PATHS       extra repo-relative paths, comma-separated (optional;
#                             "auto" re-triggers the package.json scan)
#   SKIP_CLAUDE_VOLUME_PATHS  non-empty = back nothing, installs land on the host
#
# See docs/volume-backed-paths.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# path_hash()/safe_name(): the volume name must be derived exactly the way run.sh
# derives the session volume, so both stay stable per project path.
# shellcheck source=paths.sh disable=SC1091
source "${SCRIPT_DIR}/paths.sh"

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
REPO_IN_CONTAINER="${REPO_IN_CONTAINER:-/home/dev/repo}"
IMAGE="${IMAGE:-claude-code:local}"

if [[ -n "${SKIP_CLAUDE_VOLUME_PATHS:-}" ]]; then
  echo ">> SKIP_CLAUDE_VOLUME_PATHS set — not isolating in-repo paths; node_modules etc. will land on the host" >&2
  exit 0
fi

SAFE_NAME="$(safe_name "${PROJECT_DIR}")"
MOUNT_ARGS=()   # tokens printed on stdout
CHOWN_MOUNTS=() # the same volumes, mounted flat for the ownership pass
_vol_count=0
_seen=" "

# Nesting a volume over the repo bind mount is standard Docker: no conflict, the
# deeper and more specific mount wins for that subtree.
prepare() {  # <repo-relative path>
  local rel="$1" name target
  case "$rel" in
    /*|*..*|"~"*) echo ">> skipping volume path (must be repo-relative, no '..' or '~'): $rel" >&2; return ;;
  esac
  case "$_seen" in *" ${rel} "*) return ;; esac   # dedup (auto + explicit may overlap)
  _seen+="${rel} "
  # If the host already holds files here, the volume masks them in the container
  # but the host copy persists — warn so the host can be kept clean.
  if [ -n "$(ls -A "${PROJECT_DIR}/${rel}" 2>/dev/null)" ]; then
    echo ">> WARNING: ${rel} already has contents on the host; the volume hides them in the container but the host copy remains — delete it to keep the host clean." >&2
  fi
  name="claude-vol-${SAFE_NAME:-repo}-$(path_hash "${PROJECT_DIR}/${rel}")"
  target="${REPO_IN_CONTAINER}/${rel}"
  if ! docker volume inspect "$name" >/dev/null 2>&1; then
    docker volume create "$name" >/dev/null
    echo ">> created path volume: ${name} -> ${target}" >&2
  fi
  MOUNT_ARGS+=("--volume=${name}:${target}")
  # Every volume gets a slot in the ownership pass — not just the ones created here.
  CHOWN_MOUNTS+=(--volume "${name}:/v/${_vol_count}")
  _vol_count=$((_vol_count + 1))
}

# Back ./node_modules for every package.json dir in the project.
expand_auto() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && prepare "$p"
  done < <("${SCRIPT_DIR}/find-node-modules-paths.sh" "${PROJECT_DIR}")
}

expand_auto

# pnpm keeps its content-addressable store on the same filesystem as the project —
# with $HOME on another device it defaults to <repo>/.pnpm-store, i.e. ON THE HOST.
# Back the root node_modules (a pnpm workspace root need not carry a package.json,
# so the scan above can miss it) so the store can live inside that volume; see the
# store_dir env below.
if [[ -f "${PROJECT_DIR}/pnpm-lock.yaml" || -f "${PROJECT_DIR}/pnpm-workspace.yaml" ]]; then
  prepare node_modules
fi

# Extra user-specified paths on top of the automatic coverage.
if [[ -n "${CLAUDE_VOLUME_PATHS:-}" ]]; then
  IFS=',' read -r -a _extra <<< "${CLAUDE_VOLUME_PATHS}"
  for rel in ${_extra[@]+"${_extra[@]}"}; do
    rel="${rel#"${rel%%[![:space:]]*}"}"; rel="${rel%"${rel##*[![:space:]]}"}"  # trim
    rel="${rel#./}"; rel="${rel%/}"                                              # tidy ./ and trailing /
    [[ -z "$rel" ]] && continue
    if [[ "$rel" == "auto" ]]; then expand_auto; else prepare "$rel"; fi
  done
fi

# pnpm store INSIDE the root node_modules volume: off the host, persisted across
# runs, and on the same filesystem as node_modules/.pnpm so pnpm hardlinks instead
# of copying (a hardlink cannot cross two volumes). Only set when that volume
# exists, else the store would be redirected onto the host bind mount. npm-style
# env config, so npm and yarn accept and ignore the key.
case "$_seen" in
  *" node_modules "*)
    MOUNT_ARGS+=("--env=npm_config_store_dir=${REPO_IN_CONTAINER}/node_modules/.pnpm-store") ;;
esac

# A fresh volume is root-owned, so it is chowned to the runtime UID (the container
# entrypoint can't — no NET_ADMIN there). Asserted on EVERY run, not just at
# creation: a run interrupted between `volume create` and the chown used to leave a
# root-owned volume that the creation-time gate never revisited, so in-container
# installs kept failing with EACCES. One batch container covers all paths and
# chowns only what is not already ours. Single-user by design — the volume belongs
# to whoever ran last.
if [[ "${_vol_count}" -gt 0 ]]; then
  docker run --rm --user 0:0 --entrypoint sh \
    --env "VOL_UID=$(id -u)" --env "VOL_GID=$(id -g)" \
    ${CHOWN_MOUNTS[@]+"${CHOWN_MOUNTS[@]}"} \
    "${IMAGE}" -c 'for d in /v/*; do
      [ "$(stat -c %u "$d")" = "$VOL_UID" ] || chown -R "$VOL_UID:$VOL_GID" "$d"
    done' >&2
fi

# Printed last so nothing docker writes can interleave with the token stream.
printf '%s\n' ${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"}
