#!/usr/bin/env bats
#
# Unit tests for the `cid` config CLI — specifically the `domains add|rm`
# allowlist editors (the only commands that mutate state). Reading commands
# (list/show/project) are exercised lightly for smoke coverage.
#
# The config dir and projects dir are redirected into this test's private temp
# dir via CLAUDE_DOCKER_CONFIG_DIR / CLAUDE_PROJECTS_DIR, so runs never touch the
# real config. BATS_TEST_TMPDIR is unique per test.
#
# Run with: bats test/cid.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
CID="${SCRIPT_DIR}/cid"

setup() {
  export CLAUDE_DOCKER_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  export CLAUDE_PROJECTS_DIR="${BATS_TEST_TMPDIR}/cfg/projects"
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf '# baseline\napi.anthropic.com\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"

  # A stable project dir to target with -C. Its per-project list starts absent.
  PROJ="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "${PROJ}"
}

# Path to the (single) per-project allowlist file, whatever key it hashed to.
proj_file() { echo "${CLAUDE_PROJECTS_DIR}"/*/allowed-domains.txt; }

# ---------------------------------------------------------------------------
# domains add — per-project (default target)
# ---------------------------------------------------------------------------

@test "add: creates the per-project list and writes the host" {
  run "${CID}" domains add example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "example.com" ]
}

@test "add: multiple hosts on separate lines, wildcard allowed" {
  run "${CID}" domains add example.com .githubusercontent.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "${lines[0]}" = "example.com" ]
  [ "${lines[1]}" = ".githubusercontent.com" ]
}

@test "add: is idempotent and case-insensitive (no duplicate line)" {
  "${CID}" domains add example.com -C "${PROJ}"
  run "${CID}" domains add EXAMPLE.COM -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in"* ]]
  run grep -c '^example.com$' "$(proj_file)"
  [ "$output" -eq 1 ]
}

@test "add: lowercases the stored host" {
  "${CID}" domains add Example.Com -C "${PROJ}"
  run cat "$(proj_file)"
  [ "$output" = "example.com" ]
}

@test "add: rejects an invalid hostname and writes nothing" {
  run "${CID}" domains add 'bad host/x' -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a valid hostname"* ]]
  run bash -c "cat ${CLAUDE_PROJECTS_DIR}/*/allowed-domains.txt 2>/dev/null || true"
  [ -z "$output" ]
}

@test "add: no host argument is a usage error" {
  run "${CID}" domains add -C "${PROJ}"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# domains add -g — the shared baseline
# ---------------------------------------------------------------------------

@test "add -g: appends to the baseline list" {
  run "${CID}" domains add -g registry.npmjs.org
  [ "$status" -eq 0 ]
  run grep -c '^registry.npmjs.org$' "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [ "$output" -eq 1 ]
}

@test "add -g: fails when the baseline file is absent (points at make init)" {
  rm -f "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  run "${CID}" domains add -g foo.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"make init"* ]]
}

# ---------------------------------------------------------------------------
# domains rm
# ---------------------------------------------------------------------------

@test "rm: removes the entry, keeps other lines and comments" {
  printf '# hdr\nkeep.com\ndrop.com  # trailing\nalso-keep.com\n' \
    > "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  run "${CID}" domains rm -g drop.com
  [ "$status" -eq 0 ]
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [[ "$output" == *"# hdr"* ]]
  [[ "$output" == *"keep.com"* ]]
  [[ "$output" == *"also-keep.com"* ]]
  [[ "$output" != *"drop.com"* ]]
}

@test "rm: a host not present is reported and is a no-op" {
  cp "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt" "${BATS_TEST_TMPDIR}/before"
  run "${CID}" domains rm -g nope.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in baseline"* ]]
  run diff "${BATS_TEST_TMPDIR}/before" "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [ "$status" -eq 0 ]
}

@test "rm: absent per-project list is a graceful no-op" {
  run "${CID}" domains rm example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

# ---------------------------------------------------------------------------
# domains show + smoke tests for the read-only commands
# ---------------------------------------------------------------------------

@test "domains: shows baseline and per-project additions" {
  "${CID}" domains add example.com -C "${PROJ}"
  run "${CID}" domains "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"api.anthropic.com"* ]]     # baseline
  [[ "$output" == *"example.com"* ]]           # per-project
}

@test "list: runs and names the config dir" {
  run "${CID}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"${CLAUDE_DOCKER_CONFIG_DIR}"* ]]
}

@test "help: prints usage" {
  run "${CID}" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"domains add"* ]]
}

@test "unknown command exits non-zero" {
  run "${CID}" bogus
  [ "$status" -eq 2 ]
}
