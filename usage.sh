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
# Privacy: this is an allowlist, not a denylist. Each record is rebuilt from
# scratch keeping ONLY the fields ccusage reads to compute cost (timestamp,
# message.usage, message.model, message.id, requestId, costUSD,
# isApiErrorMessage), plus a relabeled cwd for per-project grouping. Records that
# carry no token usage are dropped entirely. Everything else — conversation text,
# thinking, tool inputs/outputs, file snapshots, AI titles, attachments — never
# leaves the volume because it is never copied in the first place.
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

# Allowlist copy, run inside the image (which ships jq). The PROJ env var (the
# real host project name) is supplied per volume below. For every *.jsonl in the
# volume it writes a copy under /archive/projects/<PROJ>/ containing only the
# records that carry token usage, each rebuilt from scratch with just the fields
# ccusage reads:
#   - timestamp             date grouping
#   - message.usage         token counts — the basis of every cost number; only
#                           input_tokens, output_tokens, cache_read_input_tokens,
#                           cache_creation_input_tokens and the cache_creation
#                           5m/1h split are kept (the split is priced separately).
#                           The rest of the usage blob — iterations (a full second
#                           copy of these counts), server_tool_use, service_tier,
#                           inference_geo, speed — is dropped: ccusage never reads it.
#   - message.model         which price list to apply
#   - message.id, requestId ccusage's dedup keys, so resynced/resumed sessions
#                           are never double-counted
#   - costUSD               precomputed cost, when Claude Code already recorded it
#   - isApiErrorMessage     lets ccusage exclude API-error turns from the total
#   - cwd, rewritten to /home/dev/<PROJ> for per-project reporting (the in-volume
#     path is always the fixed container dir, which would otherwise collapse every
#     project into one); the destination folder carries the real name too.
# Any record without message.usage is dropped, and any field not listed above is
# never copied — so conversation text, thinking, tool I/O, file snapshots, AI
# titles, and attachments cannot leak even if Claude Code adds new record types.
# A file with any unparseable line is skipped wholesale, never copied verbatim.
STRIP_SCRIPT='DEST="/archive/projects/${PROJ}"
export CWD_VAL="/home/dev/${PROJ}"
mkdir -p "$DEST"
cd /data/projects 2>/dev/null || exit 0
find . -name "*.jsonl" -type f | while IFS= read -r f; do
  b="$(basename "$f")"
  if jq -c "def clean: with_entries(select(.value != null)); if .message.usage then { timestamp: .timestamp, cwd: env.CWD_VAL, requestId: .requestId, costUSD: .costUSD, isApiErrorMessage: .isApiErrorMessage, message: ({ id: .message.id, model: .message.model, usage: (.message.usage | { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation } | clean) } | clean) } | clean else empty end" "$f" > "$DEST/$b.tmp" 2>/dev/null; then
    mv "$DEST/$b.tmp" "$DEST/$b"
  else
    rm -f "$DEST/$b.tmp"
    echo "skip (parse error): $f" >&2
  fi
done'

# The archive contains plaintext session transcripts, so restrict it to the
# owner (0700) before anything is written into it.
mkdir -p "${ARCHIVE}/projects"
chmod 700 "${ARCHIVE}" "${ARCHIVE}/projects"

# All per-project session volumes created by run.sh are named claude-*.
# Read into an array via a loop rather than `mapfile`, which macOS bash 3.2 lacks.
VOLUMES=()
while IFS= read -r v; do
  [ -n "$v" ] && VOLUMES+=("$v")
done < <(docker volume ls --quiet --filter 'name=claude-')
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

  # Strip-and-relabel copy into the shared host archive. We override the image
  # entrypoint (skip the firewall init — no NET_ADMIN needed here) and run as the
  # host UID so the copied files are owned by you. Refreshing resumed sessions is
  # safe: ccusage dedups by message id, so re-running never inflates totals.
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint sh \
    --env PROJ="${PROJ}" \
    --volume "${v}:/data:ro" \
    --volume "${ARCHIVE}:/archive" \
    "${IMAGE}" \
    -c "${STRIP_SCRIPT}"
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
