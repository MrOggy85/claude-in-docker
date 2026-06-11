#!/usr/bin/env bash
#
# Emit `docker run` --volume arguments for the extra host folders named in
# CLAUDE_MOUNTS (comma-separated). Each entry is mounted read-only at
# /home/dev/<basename>; append ":rw" to make it writable (":ro" is accepted to
# be explicit). Paths may use ~ and may be relative (resolved against
# PROJECT_DIR). One `--volume=...` token is printed per accepted mount on
# stdout; human-readable progress/skip messages go to stderr.
#
# Inputs (environment):
#   CLAUDE_MOUNTS      comma-separated list of host folders (optional; no output
#                      and exit 0 when unset/empty)
#   PROJECT_DIR        dir to resolve relative paths against        (default: $PWD)
#   HOME_IN_CONTAINER  container home, parent of each mount target  (default: /home/dev)
#   REPO_IN_CONTAINER  primary repo target, reserved      (default: $HOME_IN_CONTAINER/repo)
#   HOME               used to expand a leading ~ in entries        (from the environment)
#
# Reserved targets (the primary repo and ~/.claude) and duplicate basenames are
# skipped with a warning, as are entries that don't exist on the host.
set -euo pipefail

[[ -z "${CLAUDE_MOUNTS:-}" ]] && exit 0

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
HOME_IN_CONTAINER="${HOME_IN_CONTAINER:-/home/dev}"
REPO_IN_CONTAINER="${REPO_IN_CONTAINER:-${HOME_IN_CONTAINER}/repo}"

USED_TARGETS=" ${REPO_IN_CONTAINER} ${HOME_IN_CONTAINER}/.claude "
IFS=',' read -r -a ENTRIES <<< "${CLAUDE_MOUNTS}"
for entry in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
  # trim surrounding whitespace
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [[ -z "$entry" ]] && continue
  # optional :rw / :ro suffix selects mode (default read-only)
  mode="ro"
  case "$entry" in
    *:rw) mode="rw"; entry="${entry%:rw}" ;;
    *:ro)            entry="${entry%:ro}" ;;
  esac
  # expand leading ~, resolve relative paths against the launch dir
  # (the "~" below are case patterns matching a literal tilde, not expansions)
  # shellcheck disable=SC2088
  case "$entry" in
    "~")   entry="${HOME}" ;;
    "~/"*) entry="${HOME}/${entry#\~/}" ;;
    /*)    ;;
    *)     entry="${PROJECT_DIR}/${entry}" ;;
  esac
  if [[ ! -e "$entry" ]]; then
    echo ">> skipping extra mount (not found on host): $entry" >&2; continue
  fi
  # canonicalise without relying on realpath (absent on stock macOS)
  if [[ -d "$entry" ]]; then host="$(cd "$entry" && pwd)"
  else                       host="$(cd "$(dirname "$entry")" && pwd)/$(basename "$entry")"; fi
  base="$(basename "$host")"
  target="${HOME_IN_CONTAINER}/${base}"
  if [[ "$USED_TARGETS" == *" ${target} "* ]]; then
    echo ">> skipping extra mount (target ${target} already in use): $host" >&2; continue
  fi
  USED_TARGETS+="${target} "
  echo ">> extra mount (${mode}): ${host} -> ${target}" >&2
  printf -- '--volume=%s:%s:%s\n' "$host" "$target" "$mode"
done
