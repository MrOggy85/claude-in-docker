#!/usr/bin/env bats
#
# Unit tests for scripts/resource-limits.sh
#
# `docker info` is stubbed so no daemon is needed: STUB_HOST sets the "<bytes>
# <cpus>" it answers with, and an empty value simulates a reading that failed.
#
# Run with: bats test/resource-limits.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

# `run --separate-stderr` (used to assert on the token stream alone) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
LIMITS="${SCRIPT_DIR}/scripts/resource-limits.sh"

# 24 GiB / 12 cores, so the derived defaults are 6g and 10.
HOST_24G=$((24 * 1024 * 1024 * 1024))

setup() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/docker" << 'EOF'
#!/usr/bin/env bash
[[ "$1" == info ]] || exit 1
# Unset STUB_HOST = docker answered nothing, the "could not derive" path.
[[ -n "${STUB_HOST:-}" ]] && echo "${STUB_HOST}"
exit 0
EOF
  chmod +x "${TEST_TMP}/bin/docker"
  export PATH="${TEST_TMP}/bin:${PATH}"
  export STUB_HOST="${HOST_24G} 12"
  # Colour off: assertions compare exact strings.
  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# Assert the token stream (stdout) contains exactly this line.
assert_token() {
  grep -qxF -- "$1" <<< "$output" || {
    echo "Expected token: $1"
    echo "Actual tokens:"
    echo "$output"
    return 1
  }
}

refute_token() {
  if grep -qxF -- "$1" <<< "$output"; then
    echo "Expected NO token: $1"
    echo "Actual tokens:"
    echo "$output"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Derived defaults
# ---------------------------------------------------------------------------

@test "defaults: a quarter of host RAM, cores-2, 2048 pids, swap off" {
  run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--memory=6g"
  assert_token "--memory-swap=6g"
  assert_token "--cpus=10"
  assert_token "--pids-limit=2048"
}

@test "defaults: the memory floor is 2g on a small host" {
  STUB_HOST="$((4 * 1024 * 1024 * 1024)) 4" run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--memory=2g"
  assert_token "--memory-swap=2g"
}

@test "defaults: no cpu quota on a 2-core host (nothing left to reserve)" {
  STUB_HOST="${HOST_24G} 2" run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  refute_token "--cpus=0"
  [[ "$output" != *"--cpus"* ]]
}

@test "the summary names every limit applied" {
  run bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resource limits: memory 6g, swap off, cpus 10, pids 2048"* ]]
}

# ---------------------------------------------------------------------------
# No host reading
# ---------------------------------------------------------------------------

@test "docker info silent: pids still capped, and the missing memory cap warns" {
  STUB_HOST="" run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--pids-limit=2048" ]
  [[ "$stderr" == *"no memory limit on this container"* ]]
}

@test "docker missing entirely: no crash, pids still capped" {
  PATH="/usr/bin:/bin" run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [ "$output" = "--pids-limit=2048" ]
}

# ---------------------------------------------------------------------------
# Explicit values
# ---------------------------------------------------------------------------

@test "CLAUDE_MEMORY overrides the derived default, and swap follows it" {
  CLAUDE_MEMORY=12g run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--memory=12g"
  assert_token "--memory-swap=12g"
}

@test "CLAUDE_MEMORY_SWAP above the cap allows that much swap" {
  CLAUDE_MEMORY=4g CLAUDE_MEMORY_SWAP=6g run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--memory=4g"
  assert_token "--memory-swap=6g"
}

@test "CLAUDE_CPUS accepts a fraction" {
  CLAUDE_CPUS=1.5 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--cpus=1.5"
}

@test "CLAUDE_PIDS_LIMIT overrides the default" {
  CLAUDE_PIDS_LIMIT=512 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--pids-limit=512"
}

@test "an unsuffixed byte count is accepted" {
  CLAUDE_MEMORY=2147483648 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  assert_token "--memory=2147483648"
}

# ---------------------------------------------------------------------------
# Opting out
# ---------------------------------------------------------------------------

@test "CLAUDE_MEMORY=unlimited drops the memory cap and its swap flag, keeping the rest" {
  CLAUDE_MEMORY=unlimited run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--memory"* ]]
  assert_token "--cpus=10"
  assert_token "--pids-limit=2048"
}

@test "an explicit opt-out is not warned about as a failed derivation" {
  CLAUDE_MEMORY=off run bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no memory limit"* ]]
}

@test "every off spelling works" {
  for word in 0 -1 off no none false unlimited OFF UNLIMITED; do
    CLAUDE_PIDS_LIMIT="${word}" run --separate-stderr bash "${LIMITS}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"--pids-limit"* ]] || {
      echo "'${word}' did not disable the pids limit"; return 1
    }
  done
}

@test "all four off: no tokens at all, and a warning that nothing is capped" {
  CLAUDE_MEMORY=0 CLAUDE_CPUS=0 CLAUDE_PIDS_LIMIT=0 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no resource limits on this container"* ]]
}

# ---------------------------------------------------------------------------
# Fail closed — a bad value must never degrade to "uncapped"
# ---------------------------------------------------------------------------

@test "malformed CLAUDE_MEMORY aborts with no tokens" {
  CLAUDE_MEMORY=6x run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"CLAUDE_MEMORY=6x is not a valid value"* ]]
}

@test "CLAUDE_MEMORY below Docker's 6m minimum aborts" {
  CLAUDE_MEMORY=1m run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"minimum Docker accepts is 6m"* ]]
}

@test "CLAUDE_MEMORY_SWAP below the memory cap aborts (it is the combined total)" {
  CLAUDE_MEMORY=4g CLAUDE_MEMORY_SWAP=2g run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot be below CLAUDE_MEMORY (4g)"* ]]
}

@test "CLAUDE_MEMORY_SWAP without any memory cap aborts" {
  CLAUDE_MEMORY=unlimited CLAUDE_MEMORY_SWAP=6g run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"set CLAUDE_MEMORY too"* ]]
}

@test "non-numeric CLAUDE_CPUS aborts" {
  CLAUDE_CPUS=eight run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"CLAUDE_CPUS=eight is not a valid value"* ]]
}

@test "CLAUDE_CPUS=0.0 aborts rather than emitting a meaningless quota" {
  CLAUDE_CPUS=0.0 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
}

@test "non-integer CLAUDE_PIDS_LIMIT aborts" {
  CLAUDE_PIDS_LIMIT=2.5 run --separate-stderr bash "${LIMITS}"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"CLAUDE_PIDS_LIMIT=2.5 is not a valid value"* ]]
}
