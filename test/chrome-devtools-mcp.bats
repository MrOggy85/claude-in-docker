#!/usr/bin/env bats
#
# Unit tests for chrome-devtools-mcp/host-chrome-devtools-mcp.js — the host
# bridge that re-exposes the stdio chrome-devtools-mcp server over MCP's
# Streamable HTTP transport. These exercise the HTTP<->stdio translation, the
# per-project token auth and the profile-label rules only: a fake `npx` on PATH
# runs a tiny stdio JSON-RPC stub in place of the real chrome-devtools-mcp, so no
# Chrome or network fetch is involved. The stub records its argv, which is how
# the profile flags are asserted.
#
# Run with: bats test/chrome-devtools-mcp.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
BRIDGE="${SCRIPT_DIR}/chrome-devtools-mcp/host-chrome-devtools-mcp.js"

TOKEN_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TOKEN_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Start a fresh bridge per test (unique port to avoid rebind races), backed by a
# stdio stub standing in for chrome-devtools-mcp and a temp projects dir holding
# two projects' tokens. Requires node + curl; skips if either is missing so the
# wider suite still runs on minimal hosts.
setup() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  command -v curl >/dev/null 2>&1 || skip "curl not installed"

  PORT=$(( 20000 + BATS_TEST_NUMBER ))
  BASE="http://127.0.0.1:${PORT}/mcp"
  PROJECTS="${BATS_TEST_TMPDIR}/projects"
  PROFILES="${BATS_TEST_TMPDIR}/profiles"
  ARGS_LOG="${BATS_TEST_TMPDIR}/child-args"

  mkdir -p "${PROJECTS}/proj-a" "${PROJECTS}/proj-b"
  printf '%s\n' "${TOKEN_A}" > "${PROJECTS}/proj-a/chrome-devtools.token"
  printf '%s\n' "${TOKEN_B}" > "${PROJECTS}/proj-b/chrome-devtools.token"
  : > "${ARGS_LOG}"

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

  # Fake `npx`: record the args the bridge chose, then run the stub instead.
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/npx" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${ARGS_LOG}"
exec node "${BATS_TEST_TMPDIR}/stub.js"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/npx"

  start_bridge
}

teardown() {
  [ -n "${BRIDGE_PID:-}" ] && kill "${BRIDGE_PID}" 2>/dev/null || true
}

# Launch the bridge, optionally with extra `VAR=value` overrides, and wait for
# the listener (curl succeeds on any HTTP response, incl. 401).
start_bridge() {
  env "$@" \
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" \
    CHROME_DEVTOOLS_MCP_PORT="${PORT}" \
    CID_PROJECTS_DIR="${PROJECTS}" \
    CHROME_DEVTOOLS_MCP_PROFILE_ROOT="${PROFILES}" \
    node "${BRIDGE}" >/dev/null 2>&1 &
  BRIDGE_PID=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "${BASE}" && break
    sleep 0.1
  done
}

restart_bridge() {
  kill "${BRIDGE_PID}" 2>/dev/null || true
  PORT=$(( PORT + 1000 ))
  BASE="http://127.0.0.1:${PORT}/mcp"
  start_bridge "$@"
}

# initialize -> capture session id (headers to h, SSE body to b), echo the id.
# init_sid [token] [profile-label]
init_sid() {
  curl -s -D "${BATS_TEST_TMPDIR}/h" -o "${BATS_TEST_TMPDIR}/b" \
    -H "Authorization: Bearer ${1:-$TOKEN_A}" \
    -H "X-Claude-Profile: ${2:-default}" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  awk -F': ' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"");print $2}' "${BATS_TEST_TMPDIR}/h"
}

# Round-trip a request on an existing session; echoes the response body.
call_on() {  # call_on <sid> <token>
  curl -s --max-time 5 \
    -H "Authorization: Bearer ${2}" -H "mcp-session-id: ${1}" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}' "${BASE}"
}

# ---------------------------------------------------------------------------
# Token auth
# ---------------------------------------------------------------------------

@test "a request with no token is rejected with 401" {
  run curl -s -o /dev/null -w '%{http_code}' "${BASE}"
  [ "$output" = "401" ]
}

@test "a request with a wrong token is rejected with 401" {
  run curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "${BASE}"
  [ "$output" = "401" ]
}

@test "a valid token initializes and returns an Mcp-Session-Id" {
  sid="$(init_sid)"
  [ -n "$sid" ]
  grep -q 'protocolVersion' "${BATS_TEST_TMPDIR}/b"
  grep -q '"id":1' "${BATS_TEST_TMPDIR}/b"
}

@test "a token minted into an existing project dir is seen without a restart" {
  # The project dir already exists (setup made it), so writing a token into it
  # does not move the projects dir's mtime — the bridge must still notice.
  mkdir -p "${PROJECTS}/proj-c"
  sleep 1.2   # TOKEN_TTL_MS
  printf '%s\n' "cccccccccccccccccccccccccccccccc" > "${PROJECTS}/proj-c/chrome-devtools.token"
  sid="$(init_sid "cccccccccccccccccccccccccccccccc")"
  [ -n "$sid" ]
  run cat "${ARGS_LOG}"
  [[ "$output" == *"/proj-c/default"* ]]
}

@test "another project's session id is not usable with this project's token" {
  sid="$(init_sid "${TOKEN_A}")"
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_B}" -H "mcp-session-id: ${sid}" "${BASE}"
  [ "$output" = "404" ]
}

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

@test "the child gets a per-project user-data-dir and no --isolated" {
  init_sid "${TOKEN_A}" default > /dev/null
  run cat "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]
  [[ "$output" != *"--isolated"* ]]
  [ -d "${PROFILES}/proj-a/default" ]
}

@test "the profile label selects a directory inside the project" {
  init_sid "${TOKEN_A}" review > /dev/null
  run cat "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/review"* ]]
}

@test "an absent label header falls back to 'default'" {
  curl -s -o /dev/null -D /dev/null \
    -H "Authorization: Bearer ${TOKEN_A}" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  run cat "${ARGS_LOG}"
  [[ "$output" == *"/proj-a/default"* ]]
}

@test "a traversing label is rejected with 400 and creates nothing" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_A}" -H 'X-Claude-Profile: ../../evil' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  [ "$output" = "400" ]
  [ ! -e "${BATS_TEST_TMPDIR}/evil" ]
  [ ! -s "${ARGS_LOG}" ]
}

@test "a label with a slash is rejected with 400" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_A}" -H 'X-Claude-Profile: a/b' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  [ "$output" = "400" ]
}

@test "CHROME_DEVTOOLS_MCP_PROFILE=off forces a throwaway profile" {
  restart_bridge CHROME_DEVTOOLS_MCP_PROFILE=off
  init_sid > /dev/null
  run cat "${ARGS_LOG}"
  [[ "$output" == *"--isolated"* ]]
  [[ "$output" != *"--user-data-dir"* ]]
}

# ---------------------------------------------------------------------------
# Concurrent sessions
# ---------------------------------------------------------------------------

@test "two projects hold sessions at once and neither browser is evicted" {
  sid_a="$(init_sid "${TOKEN_A}")"
  sid_b="$(init_sid "${TOKEN_B}")"
  [ -n "$sid_a" ]
  [ -n "$sid_b" ]
  [ "$sid_a" != "$sid_b" ]

  run call_on "${sid_a}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]
  run call_on "${sid_b}" "${TOKEN_B}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]

  run cat "${ARGS_LOG}"
  [[ "$output" == *"/proj-a/default"* ]]
  [[ "$output" == *"/proj-b/default"* ]]
}

@test "one project, two labels: both persist and both stay alive" {
  sid_1="$(init_sid "${TOKEN_A}" default)"
  sid_2="$(init_sid "${TOKEN_A}" review)"
  run call_on "${sid_1}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]
  run call_on "${sid_2}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]

  run cat "${ARGS_LOG}"
  [[ "$output" == *"/proj-a/default"* ]]
  [[ "$output" == *"/proj-a/review"* ]]
  [[ "$output" != *"--isolated"* ]]
}

@test "same label, no browser and no connected client: the profile is reclaimed" {
  # The server is spawned at initialize but Chrome launches lazily, so a session
  # can hold a label with nothing behind it. A reconnecting client must get its
  # real profile back, not a temp one.
  sid_1="$(init_sid "${TOKEN_A}" default)"
  sid_2="$(init_sid "${TOKEN_A}" default)"

  run sed -n 1p "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]
  run sed -n 2p "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]

  # The stale claim is gone, so it cannot later launch Chrome onto that dir.
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_A}" -H "mcp-session-id: ${sid_1}" "${BASE}"
  [ "$output" = "404" ]
  run call_on "${sid_2}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]
}

@test "same label with a running Chrome: the second is isolated and the first survives" {
  sid_1="$(init_sid "${TOKEN_A}" default)"
  # Stand in for a live browser: Chrome's own lock, naming a pid that is alive.
  ln -s "$(hostname)-$$" "${PROFILES}/proj-a/default/SingletonLock"

  sid_2="$(init_sid "${TOKEN_A}" default)"
  run sed -n 2p "${ARGS_LOG}"
  [[ "$output" == *"--isolated"* ]]

  # The browser that owns the profile is untouched — the original regression.
  run call_on "${sid_1}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]
  run call_on "${sid_2}" "${TOKEN_A}"
  [[ "$output" == *'"echoed":"tools/list"'* ]]
}

@test "a stale lock naming a dead pid does not block the profile" {
  init_sid "${TOKEN_A}" default > /dev/null
  # A pid that cannot be running: Chrome crashed and left its lock behind.
  ln -sfn "$(hostname)-2147483647" "${PROFILES}/proj-a/default/SingletonLock"
  init_sid "${TOKEN_A}" default > /dev/null
  run sed -n 2p "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]
}

@test "re-initializing on an existing session id reuses its profile" {
  sid="$(init_sid "${TOKEN_A}" default)"
  curl -s -o /dev/null -D /dev/null \
    -H "Authorization: Bearer ${TOKEN_A}" -H "mcp-session-id: ${sid}" \
    -H 'X-Claude-Profile: default' \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  run sed -n 2p "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]
}

@test "a label is freed once its session ends" {
  sid="$(init_sid "${TOKEN_A}" default)"
  curl -s -o /dev/null -X DELETE -H "Authorization: Bearer ${TOKEN_A}" \
    -H "mcp-session-id: ${sid}" "${BASE}"
  init_sid "${TOKEN_A}" default > /dev/null
  run sed -n 2p "${ARGS_LOG}"
  [[ "$output" == *"--user-data-dir=${PROFILES}/proj-a/default"* ]]
}

@test "sessions are capped: the oldest browser is closed rather than accumulating" {
  restart_bridge CHROME_DEVTOOLS_MCP_MAX_SESSIONS=2
  sid_1="$(init_sid "${TOKEN_A}" one)"
  init_sid "${TOKEN_A}" two > /dev/null
  init_sid "${TOKEN_A}" three > /dev/null
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_A}" -H "mcp-session-id: ${sid_1}" "${BASE}"
  [ "$output" = "404" ]
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

@test "DELETE tears the session down (200)" {
  sid="$(init_sid)"
  run curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${TOKEN_A}" -H "mcp-session-id: ${sid}" "${BASE}"
  [ "$output" = "200" ]
}

# ---------------------------------------------------------------------------
# Request/response correlation on the POST stream
# ---------------------------------------------------------------------------

@test "a request's response is streamed back, correlated by id" {
  sid="$(init_sid)"
  run curl -s --max-time 5 \
    -H "Authorization: Bearer ${TOKEN_A}" \
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
    -H "Authorization: Bearer ${TOKEN_A}" \
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
  run curl -s --max-time 2 -H "Authorization: Bearer ${TOKEN_A}" \
    -H "mcp-session-id: ${sid}" "${BASE}"
  [[ "$output" == *'stub-ready'* ]]
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "a GET with a valid token but no session returns 404" {
  run curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN_A}" "${BASE}"
  [ "$output" = "404" ]
}

@test "a malformed JSON body returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN_A}" \
    -H 'Content-Type: application/json' -d 'not json' "${BASE}"
  [ "$output" = "400" ]
}

@test "an unknown path returns 404" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/nope"
  [ "$output" = "404" ]
}
