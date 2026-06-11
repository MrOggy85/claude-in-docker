#!/usr/bin/env bash
#
# Aggregate ccusage across ALL claude-code container sessions.
#
# run.sh gives each project its own persistent Docker volume (claude-<name>-<hash>)
# holding that project's ~/.claude — including the JSONL transcript logs that
# ccusage reads. Those volumes outlive the --rm container, so a whole month of
# sessions is retained, just split one-volume-per-project.
#
# This script copies the usage records out of every claude-* volume into a single
# host directory, then runs ccusage over the combined set. It does NOT touch the
# live session volumes, so per-project resume/isolation is unaffected.
#
# Privacy: the copy is an allowlist, not a denylist — each record is rebuilt
# from scratch keeping ONLY the fields ccusage reads to compute cost, plus a
# relabeled cwd for per-project grouping. The transform lives in sync-volume.sh
# (shared with run.sh's per-session auto-sync); see that file for the
# field-by-field breakdown.
#
# Usage:
#   ./usage.sh                # monthly report (default)
#   ./usage.sh daily          # any ccusage subcommand / flags pass through
#   ./usage.sh monthly --json
#
# Env:
#   CLAUDE_USAGE_DIR   where to keep the aggregated logs (default: ~/.claude-docker-usage)
#   CCUSAGE_VERSION    npm version used for the npx fallback (default: latest). A
#                      globally installed `ccusage` is preferred over npx when present.
set -euo pipefail

IMAGE="claude-code:local"
ARCHIVE="${CLAUDE_USAGE_DIR:-${HOME}/.claude-docker-usage}"
CCUSAGE_VERSION="${CCUSAGE_VERSION:-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All per-project session volumes created by run.sh are named claude-*. Docker's
# name filter matches substrings anywhere in the name, so anchor the prefix with
# grep to keep unrelated volumes (e.g. mydata-claude-store) out of the archive.
# Read into an array via a loop rather than `mapfile`, which macOS bash 3.2 lacks.
VOLUMES=()
while IFS= read -r v; do
  [ -n "$v" ] && VOLUMES+=("$v")
done < <(docker volume ls --quiet | grep '^claude-' || true)
if [ "${#VOLUMES[@]}" -eq 0 ]; then
  echo "No claude-* session volumes found — run a session via ./run.sh first." >&2
  exit 1
fi

echo ">> Collecting transcripts from ${#VOLUMES[@]} session volume(s) into ${ARCHIVE}"
for v in "${VOLUMES[@]}"; do
  # Recover the project name from the volume name (run.sh names volumes
  # claude-<name>-<hash>; the hash is 10 hex chars with no dashes, so trimming the
  # claude- prefix and the trailing -<hash> leaves the name). Fall back to the full
  # volume name for any volume not following that pattern (e.g. a custom CLAUDE_VOLUME).
  tmp="${v#claude-}"
  PROJ="${tmp%-*}"
  [ -n "${PROJ}" ] && [ "${PROJ}" != "${tmp}" ] || PROJ="${v}"

  # Strip-and-relabel copy into the shared host archive (see sync-volume.sh).
  # Refreshing resumed sessions is safe: ccusage dedups by message id, so
  # re-running never inflates totals.
  IMAGE="${IMAGE}" "${SCRIPT_DIR}/sync-volume.sh" "${v}" "${PROJ}" "${ARCHIVE}"
done

echo ">> Running ccusage over ${ARCHIVE}"
# Prefer a globally installed `ccusage` (install once with `npm i -g ccusage` so
# the package can be audited and is not re-fetched each run). Fall back to npx,
# pinned to CCUSAGE_VERSION, rather than always pulling the latest release.
if command -v ccusage >/dev/null 2>&1; then
  CLAUDE_CONFIG_DIR="${ARCHIVE}" exec ccusage "${@:-monthly}"
else
  CLAUDE_CONFIG_DIR="${ARCHIVE}" exec npx --yes "ccusage@${CCUSAGE_VERSION}" "${@:-monthly}"
fi
