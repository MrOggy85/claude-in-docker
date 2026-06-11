#!/usr/bin/env bash
#
# Strip-and-copy the usage records from ONE session volume into the shared host
# archive, so `ccusage` can read them from the host. This is the single home of
# the transform — run.sh (after each session) and usage.sh (across every
# volume) both delegate here, so the allowlist cannot drift between them.
#
# Usage: sync-volume.sh <volume> <project-name> <archive-dir>
# Env:   IMAGE  image that ships jq (default: claude-code:local)
#
# Privacy: this is an allowlist, not a denylist. For every *.jsonl in the
# volume it writes a copy under <archive-dir>/projects/<project-name>/
# containing only the records that carry token usage, each rebuilt from
# scratch with just the fields ccusage reads:
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
set -euo pipefail

USAGE="usage: sync-volume.sh <volume> <project-name> <archive-dir>"
VOLUME="${1:?${USAGE}}"
PROJ="${2:?${USAGE}}"
ARCHIVE="${3:?${USAGE}}"
IMAGE="${IMAGE:-claude-code:local}"

# jq ships in the image, not necessarily on the host, so the transform runs in
# a throwaway container. The image is built locally by run.sh and cannot be
# pulled, so fail with a hint rather than a raw docker error when it is missing
# (e.g. usage.sh before the first session, or after an image prune).
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Image ${IMAGE} not found — run ./run.sh once to build it." >&2
  exit 1
fi

# The archive contains usage metadata, so restrict it to the owner (0700)
# before anything is written into it.
mkdir -p "${ARCHIVE}/projects"
chmod 700 "${ARCHIVE}" "${ARCHIVE}/projects"

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

# Mount the session volume read-only (live sessions are never touched) and the
# archive read-write. We override the image entrypoint (skip the firewall init —
# no NET_ADMIN needed here) and run as the host UID so the copied files are
# owned by you. Refreshing resumed sessions is safe: ccusage dedups by message
# id, so re-running never inflates totals.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --entrypoint sh \
  --env PROJ="${PROJ}" \
  --volume "${VOLUME}:/data:ro" \
  --volume "${ARCHIVE}:/archive" \
  "${IMAGE}" \
  -c "${STRIP_SCRIPT}"
