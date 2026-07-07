#!/usr/bin/env bash
#
# Strip-and-copy the usage records from ONE session volume into the shared host
# archive so `ccusage` can read them. The single home of the transform — run.sh
# (per session) and usage.sh (all volumes) both delegate here, so the allowlist
# can't drift between them.
#
# Usage: sync-volume.sh <volume> <project-name> <archive-dir>
# Env:   IMAGE  image that ships jq (default: claude-code:local)
#
# Privacy: an allowlist, not a denylist. For every *.jsonl it writes a copy under
# <archive-dir>/projects/<project-name>/ keeping only records with token usage,
# each rebuilt from scratch with just the fields ccusage reads:
#   - timestamp             date grouping
#   - message.usage         token counts — only input/output_tokens, the two
#                           cache_* counts, and the cache_creation 5m/1h split
#                           (priced separately). The rest (iterations,
#                           server_tool_use, service_tier, …) is dropped.
#   - message.model         which price list to apply
#   - message.id, requestId ccusage's dedup keys (resumed sessions never double-count)
#   - costUSD               precomputed cost, when Claude Code recorded it
#   - isApiErrorMessage     lets ccusage exclude API-error turns
#   - cwd, rewritten to /home/dev/<PROJ> for per-project grouping (the in-volume
#     path is a fixed container dir that would collapse every project into one)
# Any field not listed is never copied, so conversation text, tool I/O, and
# attachments can't leak even if new record types appear. A file with any
# unparseable line is skipped wholesale.
set -euo pipefail

USAGE="usage: sync-volume.sh <volume> <project-name> <archive-dir>"
VOLUME="${1:?${USAGE}}"
PROJ="${2:?${USAGE}}"
ARCHIVE="${3:?${USAGE}}"
IMAGE="${IMAGE:-claude-code:local}"

# jq ships in the image (not necessarily the host), so the transform runs in a
# throwaway container. The image is built locally and can't be pulled, so fail
# with a hint when missing (e.g. before the first session, or after a prune).
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Image ${IMAGE} not found — run ./run.sh once to build it." >&2
  exit 1
fi

# The archive holds usage metadata, so restrict it to the owner (0700).
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

# Mount the session volume read-only (live sessions untouched) and the archive
# read-write. Override the entrypoint (skip firewall init — no NET_ADMIN needed)
# and run as the host UID so copied files are owned by you. Re-running is safe:
# ccusage dedups by message id, so totals never inflate.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --entrypoint sh \
  --env PROJ="${PROJ}" \
  --volume "${VOLUME}:/data:ro" \
  --volume "${ARCHIVE}:/archive" \
  "${IMAGE}" \
  -c "${STRIP_SCRIPT}"
