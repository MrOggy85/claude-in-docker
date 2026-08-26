#!/usr/bin/env bats
#
# Unit tests for docker-bridge/host-docker-bridge.js — the host bridge that
# exposes read-only `docker ps` / `logs` / `stats` to the container over MCP's
# Streamable HTTP transport. A fake `docker` on PATH emits canned `{{json .}}`
# records, so no daemon is involved; these cover the auth, the container
# allowlist, argument validation, and the transport.
#
# Run with: bats test/docker-bridge.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
BRIDGE="${SCRIPT_DIR}/docker-bridge/host-docker-bridge.js"

TOKEN='t0kenA'
OTHER_TOKEN='t0kenB'

# Start a fresh bridge per test (unique port to avoid rebind races) against a
# throwaway config dir holding two projects: "alpha" (allowlist: myapp-web and
# the myapp-* glob) and "beta" (allowlist: other-svc). Requires node + curl;
# skips if either is missing so the wider suite still runs on minimal hosts.
setup() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  command -v curl >/dev/null 2>&1 || skip "curl not installed"

  PORT=$(( 21000 + BATS_TEST_NUMBER ))
  BASE="http://127.0.0.1:${PORT}/mcp"
  CFG="${BATS_TEST_TMPDIR}/config"
  PROJECTS="${CFG}/projects"

  mkdir -p "${PROJECTS}/alpha" "${PROJECTS}/beta" "${BATS_TEST_TMPDIR}/bin"
  printf '%s' "${TOKEN}" > "${PROJECTS}/alpha/docker-bridge.token"
  printf '%s' "${OTHER_TOKEN}" > "${PROJECTS}/beta/docker-bridge.token"
  printf '# app\nmyapp-web\nmyapp-*\n' > "${PROJECTS}/alpha/docker-containers.txt"
  printf 'other-svc\n' > "${PROJECTS}/beta/docker-containers.txt"

  # Fake docker: canned ps/stats records (one allowlisted, one a Claude session
  # container that must be filtered out) and a logs command that echoes its argv
  # so tests can assert on the argument list the bridge built.
  cat > "${BATS_TEST_TMPDIR}/bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
  ps)
    printf '%s\n' '{"Names":"myapp-web","Image":"nginx","State":"running","Status":"Up 2 hours","RunningFor":"2 hours ago","Ports":"0.0.0.0:8080->80/tcp","Command":"nginx","Labels":"com.docker.compose.project.working_dir=/Users/me/secret","Mounts":"/Users/me/secret"}'
    printf '%s\n' '{"Names":"claude-repo-1a2b","Image":"claude-code:local","State":"running","Status":"Up 1 min","RunningFor":"1 min ago","Ports":"","Command":"claude","Labels":"","Mounts":""}'
    ;;
  logs)  echo "ARGV: $*" ;;
  stats)
    printf '%s\n' '{"Name":"myapp-web","CPUPerc":"0.15%","MemUsage":"12MiB / 8GiB","MemPerc":"0.1%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"5"}'
    printf '%s\n' '{"Name":"claude-repo-1a2b","CPUPerc":"9%","MemUsage":"1GiB / 8GiB","MemPerc":"12%","NetIO":"0B / 0B","BlockIO":"0B / 0B","PIDs":"40"}'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker"

  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" \
  CID_CONFIG_DIR="${CFG}" CID_PROJECTS_DIR="${PROJECTS}" \
  DOCKER_BRIDGE_PORT="${PORT}" DOCKER_BRIDGE_BIND=127.0.0.1 \
    node "${BRIDGE}" >/dev/null 2>&1 &
  BRIDGE_PID=$!

  # Wait for the listener (curl succeeds on any HTTP response, incl. 401).
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "${BASE}" && break
    sleep 0.1
  done
}

teardown() {
  [ -n "${BRIDGE_PID:-}" ] && kill "${BRIDGE_PID}" 2>/dev/null || true
}

# initialize as project alpha -> echo the session id.
init_sid() {
  curl -s -D "${BATS_TEST_TMPDIR}/h" -o /dev/null \
    -H "Authorization: Bearer ${1:-${TOKEN}}" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "${BASE}"
  awk -F': ' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"");print $2}' "${BATS_TEST_TMPDIR}/h"
}

# POST a JSON-RPC body with the alpha token (or $2) and print the SSE response.
rpc() {
  curl -s --max-time 10 \
    -H "Authorization: Bearer ${2:-${TOKEN}}" \
    -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' \
    -d "$1" "${BASE}"
}

# tools/call shorthand: <tool> <json-arguments>
call_tool() {
  rpc "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" "${3:-${TOKEN}}"
}

# ---------------------------------------------------------------------------
# Authentication
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
}

@test "a token minted into an existing project dir is seen without a restart" {
  # The project dir already exists, so writing a token into it does not move the
  # projects dir's mtime — the bridge must still notice.
  mkdir -p "${PROJECTS}/gamma"
  printf 'other-svc\n' > "${PROJECTS}/gamma/docker-containers.txt"
  sleep 1.2   # TOKEN_TTL_MS
  printf '%s' 't0kenC' > "${PROJECTS}/gamma/docker-bridge.token"
  sid="$(init_sid 't0kenC')"
  [ -n "$sid" ]
}

@test "another project's session id is not usable with this project's token" {
  other_sid="$(init_sid "${OTHER_TOKEN}")"
  [ -n "$other_sid" ]
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" -H "mcp-session-id: ${other_sid}" "${BASE}"
  [ "$output" = "404" ]
}

# ---------------------------------------------------------------------------
# Tool surface
# ---------------------------------------------------------------------------

@test "tools/list offers exactly the three read-only tools" {
  run rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  [[ "$output" == *'"docker_ps"'* ]]
  [[ "$output" == *'"docker_logs"'* ]]
  [[ "$output" == *'"docker_stats"'* ]]
  # Nothing that mutates state or dumps container env.
  [[ "$output" != *'docker_run'* ]]
  [[ "$output" != *'docker_build'* ]]
  [[ "$output" != *'docker_exec'* ]]
  [[ "$output" != *'docker_inspect'* ]]
}

@test "an unknown tool name is an error result, not a docker call" {
  run call_tool docker_rm '{}'
  [[ "$output" == *'unknown tool'* ]]
}

# ---------------------------------------------------------------------------
# The container allowlist
# ---------------------------------------------------------------------------

@test "docker_ps returns allowlisted containers and omits the rest" {
  run call_tool docker_ps '{}'
  [[ "$output" == *'myapp-web'* ]]
  [[ "$output" != *'claude-repo-1a2b'* ]]
}

@test "docker_ps strips Labels and Mounts (they carry host paths)" {
  run call_tool docker_ps '{}'
  [[ "$output" != *'Labels'* ]]
  [[ "$output" != *'Mounts'* ]]
  [[ "$output" != *'/Users/me/secret'* ]]
}

@test "docker_stats is filtered by the same allowlist" {
  run call_tool docker_stats '{}'
  [[ "$output" == *'myapp-web'* ]]
  [[ "$output" != *'claude-repo-1a2b'* ]]
}

@test "docker_logs on a non-allowlisted container is refused" {
  run call_tool docker_logs '{"container":"claude-repo-1a2b"}'
  [[ "$output" == *'not in this project'*'allowlist'* ]]
  [[ "$output" == *'isError'* ]]
}

@test "docker_logs accepts a name matched by a prefix glob" {
  run call_tool docker_logs '{"container":"myapp-worker"}'
  [[ "$output" == *'ARGV: logs --tail 200 myapp-worker'* ]]
}

@test "another project's allowlist does not apply to this project" {
  # beta allows other-svc; alpha must not.
  run call_tool docker_logs '{"container":"other-svc"}'
  [[ "$output" == *'not in this project'* ]]
  run call_tool docker_logs '{"container":"other-svc"}' "${OTHER_TOKEN}"
  [[ "$output" == *'ARGV: logs --tail 200 other-svc'* ]]
}

@test "an empty allowlist allows nothing" {
  : > "${PROJECTS}/alpha/docker-containers.txt"
  run call_tool docker_ps '{}'
  [[ "$output" == *'no Docker container allowlist'* ]]
}

@test "an allowlist edit applies without restarting the bridge" {
  run call_tool docker_logs '{"container":"late-comer"}'
  [[ "$output" == *'not in this project'* ]]
  printf 'late-comer\n' >> "${PROJECTS}/alpha/docker-containers.txt"
  run call_tool docker_logs '{"container":"late-comer"}'
  [[ "$output" == *'ARGV: logs --tail 200 late-comer'* ]]
}

@test "the shared baseline allowlist is unioned with the project's" {
  printf 'infra-db\n' > "${CFG}/docker-containers.txt"
  run call_tool docker_logs '{"container":"infra-db"}'
  [[ "$output" == *'ARGV: logs --tail 200 infra-db'* ]]
}

# ---------------------------------------------------------------------------
# Argument validation — nothing caller-supplied reaches argv unchecked
# ---------------------------------------------------------------------------

@test "a shell-shaped container name is rejected before any docker call" {
  run call_tool docker_logs '{"container":"myapp-web; rm -rf /"}'
  [[ "$output" == *'invalid container name'* ]]
  [[ "$output" != *'ARGV:'* ]]
}

@test "a container name starting with a dash is rejected" {
  run call_tool docker_logs '{"container":"--help"}'
  [[ "$output" == *'invalid container name'* ]]
}

@test "tail is clamped to the maximum" {
  run call_tool docker_logs '{"container":"myapp-web","tail":999999}'
  [[ "$output" == *'--tail 5000'* ]]
}

@test "tail below 1 is clamped up" {
  run call_tool docker_logs '{"container":"myapp-web","tail":-5}'
  [[ "$output" == *'--tail 1'* ]]
}

@test "a malformed since value is rejected" {
  run call_tool docker_logs '{"container":"myapp-web","since":"10m; whoami"}'
  [[ "$output" == *'invalid \"since\"'* ]]
  [[ "$output" != *'ARGV:'* ]]
}

@test "a valid since duration is passed through" {
  run call_tool docker_logs '{"container":"myapp-web","since":"30m"}'
  [[ "$output" == *'--since 30m'* ]]
}

@test "docker_ps all=true adds --all" {
  run call_tool docker_ps '{"all":true}'
  [[ "$output" == *'myapp-web'* ]]
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

@test "a notification-only POST returns 202 Accepted" {
  sid="$(init_sid)"
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -H "mcp-session-id: ${sid}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "${BASE}"
  [ "$output" = "202" ]
}

@test "DELETE tears the session down (200)" {
  sid="$(init_sid)"
  run curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" -H "mcp-session-id: ${sid}" "${BASE}"
  [ "$output" = "200" ]
}

@test "sessions are capped: the oldest is evicted rather than accumulating" {
  # Clients need not DELETE on exit, so the map must be bounded (MAX_SESSIONS=32).
  first="$(init_sid)"
  [ -n "$first" ]
  for _ in $(seq 1 32); do init_sid >/dev/null; done
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" -H "mcp-session-id: ${first}" "${BASE}"
  [ "$output" = "404" ]
}

@test "a GET with no active session returns 404" {
  run curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "${BASE}"
  [ "$output" = "404" ]
}

@test "a malformed JSON body returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d 'not json' "${BASE}"
  [ "$output" = "400" ]
}

@test "an unknown path returns 404 even with a valid token" {
  run curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/nope"
  [ "$output" = "404" ]
}

@test "an unknown method returns a JSON-RPC method-not-found error" {
  run rpc '{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}'
  [[ "$output" == *'-32601'* ]]
}
