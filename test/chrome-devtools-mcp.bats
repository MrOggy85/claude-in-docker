#!/usr/bin/env bats
#
# Unit tests for chrome-devtools-mcp/host-chrome-devtools-mcp.js — the host
# bridge that re-exposes the stdio chrome-devtools-mcp server over MCP's
# Streamable HTTP transport. These exercise the HTTP<->stdio translation only:
# a fake `npx` on PATH runs a tiny stdio JSON-RPC stub in place of the real
# chrome-devtools-mcp, so no Chrome or network fetch is involved.
#
# Run with: bats test/chrome-devtools-mcp.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
BRIDGE="${SCRIPT_DIR}/chrome-devtools-mcp/host-chrome-devtools-mcp.js"

# Start a fresh bridge per test (unique port to avoid rebind races), backed by a
# stdio stub standing in for chrome-devtools-mcp. Requires node + curl; skips if
# either is missing so the wider suite still runs on minimal hosts.
setup() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  command -v curl >/dev/null 2>&1 || skip "curl not installed"

  PORT=$(( 20000 + BATS_TEST_NUMBER ))
  BASE="http://127.0.0.1:${PORT}/mcp"

  # Stub MCP server: answers initialize (plus one unsolicited notification) and
  # echoes any other request's method back in its result.
  cat > "${BATS_TEST_TMPDIR}/stub.js" <<'EOF'
const rl = require('readline').createInterface({ input: process.stdin });
const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');
rl.on('line', (line) => {
  if (!line.trim()) return;
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.method === 'initialize') {
    send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', serverInfo: { name: 'stub' }, capabilities: {} } });
    send({ jsonrpc: '2.0', method: 'notifications/message', params: { data: 'stub-ready' } });
  } else if (m.id != null) {
    send({ jsonrpc: '2.0', id: m.id, result: { echoed: m.method } });
  }
});
EOF

  # Fake `npx`: ignore the chrome-devtools-mcp args, run the stub instead.
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/npx" <<EOF
#!/bin/sh
exec node "${BATS_TEST_TMPDIR}/stub.js"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/npx"

  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" CHROME_DEVTOOLS_MCP_PORT="${PORT}" \
    node "${BRIDGE}" >/dev/null 2>&1 &
  BRIDGE_PID=$!

  # Wait for the listener (curl succeeds on any HTTP response, incl. 404).
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "${BASE}" && break
    sleep 0.1
  done
}

teardown() {
  [ -n "${BRIDGE_PID:-}" ] && kill "${BRIDGE_PID}" 2>/dev/null || true
}

# initialize -> capture session id (headers to h, SSE body to b), echo the id.
init_sid() {
  curl -s -D "${BATS_TEST_TMPDIR}/h" -o "${BATS_TEST_TMPDIR}/b" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  awk -F': ' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"");print $2}' "${BATS_TEST_TMPDIR}/h"
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

@test "initialize returns an Mcp-Session-Id and the server's init response" {
  sid="$(init_sid)"
  [ -n "$sid" ]
  grep -q 'protocolVersion' "${BATS_TEST_TMPDIR}/b"
  grep -q '"id":1' "${BATS_TEST_TMPDIR}/b"
}

@test "DELETE tears the session down (200)" {
  sid="$(init_sid)"
  run curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "mcp-session-id: ${sid}" "${BASE}"
  [ "$output" = "200" ]
}

# ---------------------------------------------------------------------------
# Request/response correlation on the POST stream
# ---------------------------------------------------------------------------

@test "a request's response is streamed back, correlated by id" {
  sid="$(init_sid)"
  run curl -s --max-time 5 \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -H "mcp-session-id: ${sid}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "${BASE}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":2'* ]]
  [[ "$output" == *'"echoed":"tools/list"'* ]]
}

@test "a notification-only POST returns 202 Accepted" {
  sid="$(init_sid)"
  run curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' -H "mcp-session-id: ${sid}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "${BASE}"
  [ "$output" = "202" ]
}

# ---------------------------------------------------------------------------
# Server-initiated messages on the GET stream
# ---------------------------------------------------------------------------

@test "server-initiated notifications are delivered on the GET stream" {
  sid="$(init_sid)"
  # GET stream stays open; --max-time returns after the queued notification.
  run curl -s --max-time 2 -H "mcp-session-id: ${sid}" "${BASE}"
  [[ "$output" == *'stub-ready'* ]]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "a GET with no active session returns 404" {
  run curl -s -o /dev/null -w '%{http_code}' "${BASE}"
  [ "$output" = "404" ]
}

@test "a malformed JSON body returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' -d 'not json' "${BASE}"
  [ "$output" = "400" ]
}

@test "an unknown path returns 404" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/nope"
  [ "$output" = "404" ]
}
