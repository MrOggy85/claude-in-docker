#!/usr/bin/env bats
#
# Unit tests for scripts/extra-mounts.sh
#
# Run with: bats test/extra-mounts.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

# `run --separate-stderr` (used to assert on stdout only) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
EXTRA_MOUNTS="${SCRIPT_DIR}/scripts/extra-mounts.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  TEST_DIR="${TEST_TMP}/testdir"
  mkdir -p "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# ---------------------------------------------------------------------------
# Empty / unset input
# ---------------------------------------------------------------------------

@test "unset CLAUDE_MOUNTS: exits 0 with no output" {
  run --separate-stderr bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty CLAUDE_MOUNTS: exits 0 with no output" {
  run --separate-stderr env CLAUDE_MOUNTS="" bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "whitespace-only entry: exits 0 with no output" {
  run --separate-stderr env CLAUDE_MOUNTS="   " bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Absolute paths
# ---------------------------------------------------------------------------

@test "absolute path: emits --volume=host:target:ro" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="${TEST_DIR}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:ro" ]
}

@test ":ro suffix: emits read-only mount" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="${TEST_DIR}:ro" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:ro" ]
}

@test ":rw suffix: emits read-write mount" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="${TEST_DIR}:rw" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:rw" ]
}

@test "whitespace around entry is trimmed" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="  ${TEST_DIR}  " \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:ro" ]
}

# ---------------------------------------------------------------------------
# Relative paths (resolved against PROJECT_DIR)
# ---------------------------------------------------------------------------

@test "relative path: resolved against PROJECT_DIR" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="testdir" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:ro" ]
}

@test "relative path with :rw: resolved and mounted read-write" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="testdir:rw" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:rw" ]
}

# ---------------------------------------------------------------------------
# Tilde expansion
# ---------------------------------------------------------------------------

@test "bare tilde: expands to HOME" {
  local fake_home="${TEST_TMP}/home"
  mkdir -p "${fake_home}"
  run --separate-stderr env \
    HOME="${fake_home}" \
    CLAUDE_MOUNTS="~" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${fake_home}:/home/dev/home:ro" ]
}

@test "tilde-slash path: expands to HOME subdir" {
  local fake_home="${TEST_TMP}/home"
  local subdir="${fake_home}/myproject"
  mkdir -p "${subdir}"
  run --separate-stderr env \
    HOME="${fake_home}" \
    CLAUDE_MOUNTS="~/myproject" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${subdir}:/home/dev/myproject:ro" ]
}

# ---------------------------------------------------------------------------
# Multiple entries
# ---------------------------------------------------------------------------

@test "multiple entries: emit multiple --volume lines" {
  local dir2="${TEST_TMP}/dir2"
  mkdir -p "${dir2}"
  run --separate-stderr env \
    CLAUDE_MOUNTS="${TEST_DIR},${dir2}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"--volume=${TEST_DIR}:/home/dev/testdir:ro"* ]]
  [[ "$output" == *"--volume=${dir2}:/home/dev/dir2:ro"* ]]
}

@test "multiple entries: mixed rw and ro" {
  local dir2="${TEST_TMP}/dir2"
  mkdir -p "${dir2}"
  run --separate-stderr env \
    CLAUDE_MOUNTS="${TEST_DIR}:rw,${dir2}:ro" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"--volume=${TEST_DIR}:/home/dev/testdir:rw"* ]]
  [[ "$output" == *"--volume=${dir2}:/home/dev/dir2:ro"* ]]
}

# ---------------------------------------------------------------------------
# Skipped entries
# ---------------------------------------------------------------------------

@test "non-existent path: skipped, no --volume output" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="/nonexistent/does-not-exist" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--volume="* ]]
}

@test "reserved target REPO_IN_CONTAINER: skipped" {
  # A dir named 'repo' maps to /home/dev/repo which is REPO_IN_CONTAINER
  local repo_dir="${TEST_TMP}/repo"
  mkdir -p "${repo_dir}"
  run --separate-stderr env \
    CLAUDE_MOUNTS="${repo_dir}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    REPO_IN_CONTAINER="/home/dev/repo" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--volume="* ]]
}

@test "reserved target .claude: skipped" {
  # A dir named '.claude' maps to /home/dev/.claude which is the session volume target
  local claude_dir="${TEST_TMP}/.claude"
  mkdir -p "${claude_dir}"
  run --separate-stderr env \
    CLAUDE_MOUNTS="${claude_dir}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    REPO_IN_CONTAINER="/home/dev/repo" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--volume="* ]]
}

@test "duplicate basename: second entry skipped" {
  local dir1="${TEST_TMP}/a/shared"
  local dir2="${TEST_TMP}/b/shared"
  mkdir -p "${dir1}" "${dir2}"
  run --separate-stderr env \
    CLAUDE_MOUNTS="${dir1},${dir2}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  # Only one --volume line; the second (same basename) is skipped
  local count
  count="$(printf '%s\n' "$output" | grep -c '^--volume=' || true)"
  [ "$count" -eq 1 ]
}

@test "valid entry after invalid one: valid entry still emitted" {
  run --separate-stderr env \
    CLAUDE_MOUNTS="/nonexistent,${TEST_DIR}" \
    PROJECT_DIR="${TEST_TMP}" \
    HOME_IN_CONTAINER="/home/dev" \
    bash "${EXTRA_MOUNTS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--volume=${TEST_DIR}:/home/dev/testdir:ro" ]
}
