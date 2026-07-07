#!/usr/bin/env bash
#
# Aggregate ccusage across ALL claude-code container sessions.
#
# run.sh gives each project a persistent volume (claude-<name>-<hash>) holding
# its ~/.claude, including the JSONL transcripts ccusage reads. Those outlive the
# --rm container, so a month of sessions is retained, one volume per project.
#
# This copies usage records out of every claude-* volume into one host directory,
# then runs ccusage over the combined set. It does NOT touch the live volumes.
#
# Privacy: the copy is an allowlist keeping ONLY the cost fields, plus a
# relabeled cwd. The transform lives in sync-volume.sh — see it for the breakdown.
#
# Usage:
#   ./usage.sh                # monthly report (default)
#   ./usage.sh daily          # any ccusage subcommand / flags pass through
#   ./usage.sh monthly --json
#
# ccusage comes from the local image (no host Node/npm/npx required); a
# host-installed `ccusage` is preferred when present. Runs fully offline by default.
#
# Env:
#   CLAUDE_USAGE_DIR     where to keep the aggregated logs (default: ~/.claude-docker-usage)
#   CLAUDE_USAGE_ONLINE  set to fetch live LiteLLM pricing instead of the image's
#                        bundled snapshot (drops --offline and --network none)
set -euo pipefail

IMAGE="claude-code:local"
ARCHIVE="${CLAUDE_USAGE_DIR:-${HOME}/.claude-docker-usage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run.sh names session volumes claude-*. Docker's name filter matches substrings
# anywhere, so anchor the prefix with grep to exclude unrelated volumes (e.g.
# mydata-claude-store). Loop-read into an array since macOS bash 3.2 lacks mapfile.
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
  # Recover the project name from claude-<name>-<hash> (trim the prefix and the
  # trailing -<hash>). Fall back to the full name for volumes not matching (e.g.
  # a custom CLAUDE_VOLUME).
  tmp="${v#claude-}"
  PROJ="${tmp%-*}"
  [ -n "${PROJ}" ] && [ "${PROJ}" != "${tmp}" ] || PROJ="${v}"

  # Strip-and-relabel copy into the shared host archive (see sync-volume.sh).
  IMAGE="${IMAGE}" "${SCRIPT_DIR}/sync-volume.sh" "${v}" "${PROJ}" "${ARCHIVE}"
done

echo ">> Running ccusage over ${ARCHIVE}"
# ccusage's only network use is fetching the LiteLLM pricing table (it never
# uploads your data). --offline serves it from the bundled snapshot, so by
# default we run fully offline with --network none. Set CLAUDE_USAGE_ONLINE=1 to
# fetch live pricing — useful when a model is too new for the snapshot (those
# sessions otherwise show $0.00, though records with costUSD stay correct).
OFFLINE=(--offline); NET=(--network none)
[ -n "${CLAUDE_USAGE_ONLINE:-}" ] && OFFLINE=() && NET=()

# Prefer a host ccusage (fast path, no container spin-up); else run the copy in
# the image, so no host Node/npm/npx is needed.
if command -v ccusage >/dev/null 2>&1; then
  CLAUDE_CONFIG_DIR="${ARCHIVE}" exec ccusage ${OFFLINE[@]+"${OFFLINE[@]}"} "${@:-monthly}"
fi

# Run ccusage in the local image. Mirrors sync-volume.sh: --rm, host UID, and
# --entrypoint ccusage to skip firewall init. Allocate a TTY only when stdout is
# one, so the table renders interactively but piped/--json output isn't corrupted.
TTY=(); [ -t 1 ] && TTY=(-t)
exec docker run --rm ${TTY[@]+"${TTY[@]}"} ${NET[@]+"${NET[@]}"} \
  --user "$(id -u):$(id -g)" \
  --entrypoint ccusage \
  --env CLAUDE_CONFIG_DIR=/archive \
  --volume "${ARCHIVE}:/archive" \
  "${IMAGE}" \
  ${OFFLINE[@]+"${OFFLINE[@]}"} "${@:-monthly}"
