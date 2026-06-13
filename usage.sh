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
# ccusage itself comes from the local image (baked in at build time), so no host
# Node/npm/npx is required. A host-installed `ccusage` is used in preference when
# present. The report runs fully offline with no network by default.
#
# Env:
#   CLAUDE_USAGE_DIR     where to keep the aggregated logs (default: ~/.claude-docker-usage)
#   CLAUDE_USAGE_ONLINE  set to fetch live LiteLLM pricing instead of the image's
#                        bundled snapshot (drops --offline and --network none)
set -euo pipefail

IMAGE="claude-code:local"
ARCHIVE="${CLAUDE_USAGE_DIR:-${HOME}/.claude-docker-usage}"
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
# ccusage's only network use is downloading the LiteLLM model-pricing table to
# turn token counts into costs (it never uploads your data). --offline serves
# that from the snapshot bundled into the package at build time, so by default we
# run fully offline and cut the container off from the network (--network none).
# Set CLAUDE_USAGE_ONLINE=1 to fetch live pricing instead — useful when a model
# is so new the bundled snapshot lacks it (such sessions would otherwise show
# $0.00, though records already carrying Claude Code's costUSD stay correct).
OFFLINE=(--offline); NET=(--network none)
[ -n "${CLAUDE_USAGE_ONLINE:-}" ] && OFFLINE=() && NET=()

# Prefer a host ccusage if one is installed (fast path, no container spin-up);
# otherwise run the copy baked into the image, so no host Node/npm/npx is needed.
if command -v ccusage >/dev/null 2>&1; then
  CLAUDE_CONFIG_DIR="${ARCHIVE}" exec ccusage ${OFFLINE[@]+"${OFFLINE[@]}"} "${@:-monthly}"
fi

# Run ccusage inside the local image. Mirrors sync-volume.sh: --rm, host UID so
# any cache files ccusage writes are owned by you, and --entrypoint ccusage to
# skip the firewall-init entrypoint (with --network none the container has no
# network at all). Allocate a TTY only when stdout is one, so the table renders
# interactively but piped/--json output isn't corrupted by escape codes.
TTY=(); [ -t 1 ] && TTY=(-t)
exec docker run --rm ${TTY[@]+"${TTY[@]}"} ${NET[@]+"${NET[@]}"} \
  --user "$(id -u):$(id -g)" \
  --entrypoint ccusage \
  --env CLAUDE_CONFIG_DIR=/archive \
  --volume "${ARCHIVE}:/archive" \
  "${IMAGE}" \
  ${OFFLINE[@]+"${OFFLINE[@]}"} "${@:-monthly}"
