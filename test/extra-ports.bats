#!/usr/bin/env bats
#
# Unit tests for scripts/extra-ports.sh
#
# Run with: bats test/extra-ports.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
EXTRA_PORTS="${SCRIPT_DIR}/scripts/extra-ports.sh"

# ---------------------------------------------------------------------------
# Empty / unset input
# ---------------------------------------------------------------------------

@test "unset CLAUDE_PORTS: exits 0 with no output" {
  run bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty CLAUDE_PORTS: exits 0 with no output" {
  run env CLAUDE_PORTS="" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Simple port (PORT -> PORT:PORT/tcp)
# ---------------------------------------------------------------------------

@test "single port: emits publish-spec and container-port on one tab-separated line" {
  run env CLAUDE_PORTS="3000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "3000:3000/tcp	3000/tcp" ]
}

@test "port 1: minimum valid port" {
  run env CLAUDE_PORTS="1" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "1:1/tcp	1/tcp" ]
}

@test "port 65535: maximum valid port" {
  run env CLAUDE_PORTS="65535" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "65535:65535/tcp	65535/tcp" ]
}

# ---------------------------------------------------------------------------
# HOSTPORT:CPORT mapping
# ---------------------------------------------------------------------------

@test "HOSTPORT:CPORT: maps host port to different container port" {
  run env CLAUDE_PORTS="8080:3000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "8080:3000/tcp	3000/tcp" ]
}

@test "same HOSTPORT:CPORT: equivalent to single port form" {
  run env CLAUDE_PORTS="4000:4000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "4000:4000/tcp	4000/tcp" ]
}

# ---------------------------------------------------------------------------
# IP:HOSTPORT:CPORT (bind host to specific interface)
# ---------------------------------------------------------------------------

@test "IP:HOSTPORT:CPORT: emits IP-bound publish spec" {
  run env CLAUDE_PORTS="127.0.0.1:8080:3000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1:8080:3000/tcp	3000/tcp" ]
}

@test "IP:HOSTPORT:CPORT localhost binding: correct publish spec" {
  run env CLAUDE_PORTS="127.0.0.1:9000:9000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1:9000:9000/tcp	9000/tcp" ]
}

# ---------------------------------------------------------------------------
# Protocol suffix /tcp and /udp
# ---------------------------------------------------------------------------

@test "/tcp suffix: explicit tcp protocol" {
  run env CLAUDE_PORTS="5000/tcp" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "5000:5000/tcp	5000/tcp" ]
}

@test "/udp suffix: emits udp publish spec and container port" {
  run env CLAUDE_PORTS="5000/udp" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "5000:5000/udp	5000/udp" ]
}

@test "HOSTPORT:CPORT/udp: udp with port mapping" {
  run env CLAUDE_PORTS="5353:53/udp" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "5353:53/udp	53/udp" ]
}

@test "default protocol is tcp when no suffix given" {
  run env CLAUDE_PORTS="6000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/tcp"* ]]
}

# ---------------------------------------------------------------------------
# Multiple entries
# ---------------------------------------------------------------------------

@test "multiple ports: emit multiple lines" {
  run env CLAUDE_PORTS="3000,4000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "3000:3000/tcp	3000/tcp" ]]
  [[ "${lines[1]}" == "4000:4000/tcp	4000/tcp" ]]
}

@test "multiple ports with mixed protocols" {
  run env CLAUDE_PORTS="3000/tcp,5353/udp" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "3000:3000/tcp	3000/tcp" ]]
  [[ "${lines[1]}" == "5353:5353/udp	5353/udp" ]]
}

@test "valid entry after invalid one: valid entry still emitted" {
  run env CLAUDE_PORTS="0,3000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "3000:3000/tcp	3000/tcp" ]]
}

# ---------------------------------------------------------------------------
# Invalid / rejected entries
# ---------------------------------------------------------------------------

@test "port 0: rejected as invalid" {
  run env CLAUDE_PORTS="0" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "port 65536: rejected as out of range" {
  run env CLAUDE_PORTS="65536" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-numeric port: rejected" {
  run env CLAUDE_PORTS="abc" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unknown protocol suffix: rejected" {
  run env CLAUDE_PORTS="3000/sctp" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "too many colon fields: rejected" {
  run env CLAUDE_PORTS="1.2.3.4:8080:3000:extra" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid host port in mapping: rejected" {
  run env CLAUDE_PORTS="0:3000" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid container port in mapping: rejected" {
  run env CLAUDE_PORTS="8080:0" bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "whitespace around entry is trimmed" {
  run env CLAUDE_PORTS="  3000  " bash "${EXTRA_PORTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "3000:3000/tcp	3000/tcp" ]
}
