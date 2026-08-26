#!/bin/bash
# Smoke-test the bridge + real chrome-devtools-mcp over Streamable HTTP.
# Run on the HOST while host-chrome-devtools-mcp.sh is running in another
# terminal. Drives the full MCP handshake with curl (no container involved):
# initialize -> notifications/initialized -> tools/list -> delete.
#
# The token identifies the project, so point this at one:
#   ./chrome-devtools-mcp/smoke-test.sh ~/code/my-project
# With no argument it uses $PWD. Override the port with CHROME_DEVTOOLS_MCP_PORT
# and the profile with CLAUDE_CHROME_PROFILE (default "default").
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/paths.sh disable=SC1091
. "${SCRIPT_DIR}/../scripts/paths.sh"

PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)"
TOKEN_FILE="$(projects_dir)/$(project_key "${PROJECT_DIR}")/chrome-devtools.token"
if [ ! -f "${TOKEN_FILE}" ]; then
  echo "!! no token for ${PROJECT_DIR}"
  echo "   expected: ${TOKEN_FILE}"
  echo "   run \`CLAUDE_CHROME_DEVTOOLS=1 ./run.sh\` in that project once to create it."
  exit 1
fi
TOKEN="$(cat "${TOKEN_FILE}")"
PORT="${CHROME_DEVTOOLS_MCP_PORT:-9333}"
BASE="http://localhost:${PORT}/mcp"
AUTH="Authorization: Bearer ${TOKEN}"
PROFILE="X-Claude-Profile: ${CLAUDE_CHROME_PROFILE:-default}"
INIT_BODY="$(mktemp)"

echo ">> project: ${PROJECT_DIR}"

echo ">> GET with no token (expect 401)"
curl -s -o /dev/null -w '   status=%{http_code}\n' "${BASE}"

echo ">> POST initialize (first run may take 10-30s while npx fetches chrome-devtools-mcp)"
SID="$(curl -s --max-time 120 -D - -o "$INIT_BODY" \
  -H "$AUTH" -H "$PROFILE" \
  -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0"}}}' \
  "$BASE" | awk -F': ' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"");print $2}')"

if [ -z "$SID" ]; then
  echo "!! FAILED: no Mcp-Session-Id returned. Check the bridge terminal for errors."
  echo "   initialize response body was:"
  sed 's/^/     /' "$INIT_BODY"
  rm -f "$INIT_BODY"
  exit 1
fi
echo "   session=$SID"
echo "   initialize response:"
sed 's/^/     /' "$INIT_BODY"
rm -f "$INIT_BODY"

echo ">> POST notifications/initialized"
curl -s --max-time 10 -o /dev/null \
  -H "$AUTH" -H "mcp-session-id: $SID" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$BASE"

echo ">> POST tools/list (expect the chrome-devtools tools)"
curl -sN --max-time 30 \
  -H "$AUTH" -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
  -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$BASE" | sed 's/^/     /'

echo ""
echo ">> DELETE session (teardown; the bridge stays up)"
curl -s -o /dev/null -w '   delete status=%{http_code}\n' -X DELETE -H "$AUTH" -H "mcp-session-id: $SID" "$BASE"
echo ">> Done."
