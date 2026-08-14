#!/usr/bin/env bats
#
# Unit tests for skills/sandbox/sandbox-info.sh — the renderer the `sandbox` skill
# runs inside the container. Pure function of the environment, so every case here
# is just "set these vars, assert what is reported".
#
# Run with: bats test/sandbox-info.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SANDBOX_INFO="${SCRIPT_DIR}/skills/sandbox/sandbox-info.sh"

# Run with a clean slate: the developer's own session exports several of these
# vars (this suite may itself run inside a claude-in-docker container), which
# would otherwise leak into the "unset" cases.
render() {  # <VAR=VALUE>...
  run --separate-stderr env \
    -u CLAUDE_HOST_PROJECT_DIR -u CONTAINER_PUBLISHED_PORTS \
    -u CONTAINER_HOST_OUTBOUND_PORTS -u CONTAINER_HOST_PORT_LABELS \
    -u CONTAINER_EXTRA_MOUNTS -u CONTAINER_VOLUME_PATHS \
    -u REPO_IN_CONTAINER -u EGRESS_PROXY_HOST -u DOCKER_BRIDGE_TOKEN \
    "$@" bash "${SANDBOX_INFO}"
}

# ---------------------------------------------------------------------------
# Published ports — the host side is the whole point of this script
# ---------------------------------------------------------------------------

@test "published port: reports the host endpoint for the container port" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp"
  [ "$status" -eq 0 ]
  [[ "$output" == *'container `3000/tcp` is reachable from the host at `localhost:9345`'* ]]
}

@test "ip-bound published port: keeps the bound address instead of localhost" {
  render CONTAINER_PUBLISHED_PORTS="127.0.0.1:5000:5000/tcp"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`5000/tcp` is reachable from the host at `127.0.0.1:5000`'* ]]
}

@test "udp published port: protocol is carried through" {
  render CONTAINER_PUBLISHED_PORTS="5353:53/udp"
  [ "$status" -eq 0 ]
  [[ "$output" == *'container `53/udp` is reachable from the host at `localhost:5353`'* ]]
}

@test "multiple published ports: one line each" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp,8081:8080/tcp"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`localhost:9345`'* ]]
  [[ "$output" == *'`localhost:8081`'* ]]
}

@test "no published ports: says so and gives the relaunch route" {
  render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing you listen on is reachable from the host"* ]]
  [[ "$output" == *"CLAUDE_PORTS"* ]]
}

@test "published ports present: states that nothing else is reachable" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp"
  [[ "$output" == *"No other container port is reachable from the host"* ]]
}

# ---------------------------------------------------------------------------
# Host-outbound ports and their labels
# ---------------------------------------------------------------------------

@test "host outbound ports: labelled where a label is given, bare otherwise" {
  render CONTAINER_HOST_OUTBOUND_PORTS="4767,8085" \
         CONTAINER_HOST_PORT_LABELS="4767=sound server"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`host.docker.internal:4767` (tcp) — sound server'* ]]
  [[ "$output" == *'`host.docker.internal:8085` (tcp)'* ]]
  [[ "$output" != *'8085` (tcp) —'* ]]
}

@test "host outbound port with /udp: protocol is reported" {
  render CONTAINER_HOST_OUTBOUND_PORTS="9000/udp"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`host.docker.internal:9000` (udp)'* ]]
}

@test "no host outbound ports: reports that no host connection is permitted" {
  render
  [[ "$output" == *"no direct connection to the host is permitted"* ]]
}

# ---------------------------------------------------------------------------
# Files: repo mapping, extra mounts, volume-backed paths
# ---------------------------------------------------------------------------

@test "repo mapping: host path and container path are both shown" {
  render CLAUDE_HOST_PROJECT_DIR="/Users/dev/proj" REPO_IN_CONTAINER="/home/dev/repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`/home/dev/repo` (here) is a bind-mount of `/Users/dev/proj` (host)'* ]]
}

@test "repo mapping: host path missing is reported, not guessed" {
  render
  [[ "$output" == *"the host path was not passed in"* ]]
}

@test "extra mounts: target, host path and mode are reported" {
  render CONTAINER_EXTRA_MOUNTS="/home/dev/v=/Users/dev/vault:rw"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`/home/dev/v` <- host `/Users/dev/vault` (rw)'* ]]
}

@test "no extra mounts: says only the repo is mounted" {
  render
  [[ "$output" == *"Extra mounts: none"* ]]
}

@test "volume-backed paths: each path is listed as absent from the host" {
  render CONTAINER_VOLUME_PATHS="/home/dev/repo/node_modules,/home/dev/repo/web/node_modules"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT present on the host disk"* ]]
  [[ "$output" == *'`/home/dev/repo/node_modules`'* ]]
  [[ "$output" == *'`/home/dev/repo/web/node_modules`'* ]]
}

@test "no volume-backed paths: says writes land on the host" {
  render
  [[ "$output" == *"writes land on the host disk"* ]]
}

# ---------------------------------------------------------------------------
# Egress and the docker bridge
# ---------------------------------------------------------------------------

@test "egress proxy set: blocked requests are framed as policy with the cid fix" {
  render EGRESS_PROXY_HOST="squid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cid domains add"* ]]
  [[ "$output" == *"Never route around it"* ]]
}

@test "no egress proxy: reported as not configured" {
  render
  [[ "$output" == *"No egress proxy is configured"* ]]
}

@test "docker bridge token set: bridge reported as enabled, token value never printed" {
  render DOCKER_BRIDGE_TOKEN="deadbeefsecret"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker bridge is enabled"* ]]
  [[ "$output" != *"deadbeefsecret"* ]]
}

@test "no docker bridge token: bridge reported as off" {
  render
  [[ "$output" == *"docker bridge is off"* ]]
}

# ---------------------------------------------------------------------------
# Shape of the whole report
# ---------------------------------------------------------------------------

@test "every section is present even with no input at all" {
  render
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Files"* ]]
  [[ "$output" == *"## Ports published to the host (inbound)"* ]]
  [[ "$output" == *"## Host services reachable from here (outbound)"* ]]
  [[ "$output" == *"## Everything else on the network"* ]]
  [[ "$output" == *"## Using this"* ]]
}

@test "host-side tools are told to use the host endpoint" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp"
  [[ "$output" == *"Anything running on the HOST must use the host endpoint"* ]]
}

@test "chrome bridge open: the browser-on-the-host warning names it" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp" \
         CONTAINER_HOST_OUTBOUND_PORTS="9333" \
         CONTAINER_HOST_PORT_LABELS="9333=chrome-devtools MCP bridge (browser runs on the host)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chrome-devtools MCP server"* ]]
}

@test "chrome bridge closed: the warning stays generic, naming no absent server" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp" \
         CONTAINER_HOST_OUTBOUND_PORTS="4767" \
         CONTAINER_HOST_PORT_LABELS="4767=sound server"
  [ "$status" -eq 0 ]
  [[ "$output" == *"any other host-side tool"* ]]
  [[ "$output" != *"chrome-devtools MCP server"* ]]
}

@test "writes nothing to stderr" {
  render CONTAINER_PUBLISHED_PORTS="9345:3000/tcp" CONTAINER_HOST_OUTBOUND_PORTS="4767"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}
