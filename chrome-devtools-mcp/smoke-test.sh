#!/bin/bash
# Smoke-test the bridge + real chrome-devtools-mcp over Streamable HTTP.
# Run on the HOST while host-chrome-devtools-mcp.sh is running in another
# terminal. Drives the full MCP handshake with curl (no container involved):
# initialize -> notifications/initialized -> tools/list -> delete.
# Override the port with CHROME_DEVTOOLS_MCP_PORT (default 9333).
set -u
PORT="${CHROME_DEVTOOLS_MCP_PORT:-9333}"
BASE="http://localhost:${PORT}/mcp"
INIT_BODY="$(mktemp)"

echo ">> POST initialize (first run may take 10-30s while npx fetches chrome-devtools-mcp)"
SID="$(curl -s --max-time 120 -D - -o "$INIT_BODY" \
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
  -H "mcp-session-id: $SID" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$BASE"

echo ">> POST tools/list (expect the chrome-devtools tools)"
curl -sN --max-time 30 \
  -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
  -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$BASE" | sed 's/^/     /'

echo ""
echo ">> DELETE session (teardown; the bridge stays up)"
curl -s -o /dev/null -w '   delete status=%{http_code}\n' -X DELETE -H "mcp-session-id: $SID" "$BASE"
echo ">> Done."
