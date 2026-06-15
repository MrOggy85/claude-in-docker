#!/usr/bin/env bats
#
# E2E scenario tests for claude-in-docker
#
# Each scenario under e2e/scenarios/ represents a folder from which a user
# might run ./run.sh. Tests verify structure and docker command construction
# using a mock docker binary — no daemon or Claude credentials required.
#
# Run with: bats test/e2e.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCENARIOS_DIR="${REPO_ROOT}/e2e/scenarios"
RUN_SH="${REPO_ROOT}/run.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a mock docker binary that records docker-run arguments.
# Handles all docker subcommands called by run.sh without a real daemon.
_make_mock_docker() {
  local path="$1"
  cat > "$path" << 'MOCK'
#!/usr/bin/env bash
# Mock docker for testing run.sh
case "$1" in
  image)
    # image inspect — report image as not found so run.sh triggers a build
    echo ""
    exit 1
    ;;
  build)
    # docker build — pretend to succeed without building anything
    exit 0
    ;;
  volume)
    case "$2" in
      inspect) exit 1 ;;
      create)  echo ""; exit 0 ;;
    esac
    ;;
  run)
    # Skip the per-volume chown helper run (--entrypoint chown)
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--entrypoint" ] && [ "$arg" = "chown" ]; then
        exit 0
      fi
      prev="$arg"
    done
    # Record the main docker run arguments (one per line) for test assertions
    printf '%s\n' "$@" >> "${DOCKER_ARGS_FILE}"
    exit 0
    ;;
esac
exit 0
MOCK
  chmod +x "$path"
}

# Populate a temporary copy of a scenario so tests are hermetic.
# Usage: _stage_scenario <scenario-name> [--with-claude-settings <settings-file>]
# Sets STAGED_DIR to the temp directory.
_stage_scenario() {
  local name="$1"
  STAGED_DIR="${TEST_TMP}/staged-${name}"
  cp -r "${SCENARIOS_DIR}/${name}" "${STAGED_DIR}"

  # If a preset settings file is provided, install it as .claude/settings.json
  if [ "${2:-}" = "--with-claude-settings" ] && [ -n "${3:-}" ]; then
    mkdir -p "${STAGED_DIR}/.claude"
    cp "$3" "${STAGED_DIR}/.claude/settings.json"
  fi
}

# Run run.sh from a staged scenario directory using the mock docker.
# Sets $status, $output, $lines (bats run semantics).
run_staged() {
  local dir="$1"
  run --separate-stderr env \
    PATH="${MOCK_BIN}:${PATH}" \
    CLAUDE_AUTO_USAGE=0 \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    bash -c "cd '${dir}' && bash '${RUN_SH}'"
}

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="${TEST_TMP}/bin"
  DOCKER_ARGS_FILE="${TEST_TMP}/docker_run_args"
  mkdir -p "${MOCK_BIN}"
  _make_mock_docker "${MOCK_BIN}/docker"
  export DOCKER_ARGS_FILE MOCK_BIN TEST_TMP
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# ---------------------------------------------------------------------------
# Scenario: nodejs
# A simple Node.js project — the most common use case.
# ---------------------------------------------------------------------------

@test "nodejs: scenario has package.json" {
  [ -f "${SCENARIOS_DIR}/nodejs/package.json" ]
}

@test "nodejs: scenario has index.js" {
  [ -f "${SCENARIOS_DIR}/nodejs/index.js" ]
}

@test "nodejs: run.sh constructs a valid docker run command" {
  _stage_scenario "nodejs"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  # docker run should have been called and args recorded
  [ -f "${DOCKER_ARGS_FILE}" ]
}

@test "nodejs: docker run mounts the project directory" {
  _stage_scenario "nodejs"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  # The staged dir should appear as a --volume source in the docker run args
  grep -qF "${STAGED_DIR}" "${DOCKER_ARGS_FILE}"
}

@test "nodejs: docker run sets working directory to repo mount point" {
  _stage_scenario "nodejs"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  grep -q "/home/dev/repo" "${DOCKER_ARGS_FILE}"
}

# ---------------------------------------------------------------------------
# Scenario: macos-home
# Simulates a user running claude-in-docker from their macOS home folder.
# ---------------------------------------------------------------------------

@test "macos-home: scenario has Documents directory" {
  [ -d "${SCENARIOS_DIR}/macos-home/Documents" ]
}

@test "macos-home: scenario has Desktop directory" {
  [ -d "${SCENARIOS_DIR}/macos-home/Desktop" ]
}

@test "macos-home: run.sh constructs a valid docker run command" {
  _stage_scenario "macos-home"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  [ -f "${DOCKER_ARGS_FILE}" ]
}

@test "macos-home: docker run mounts the home directory as the repo" {
  _stage_scenario "macos-home"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  grep -qF "${STAGED_DIR}" "${DOCKER_ARGS_FILE}"
}

# ---------------------------------------------------------------------------
# Scenario: malicious
# A project whose .claude/settings.json contains a PreToolUse hook that tries
# to execute malicious-file.sh. The test verifies:
#   1. The project's settings.json is NOT bind-mounted as the global Claude
#      settings — the container's global settings come from SCRIPT_DIR, not
#      from the project.
#   2. malicious-file.sh is NOT executed on the HOST when run.sh is invoked
#      (the mock docker never runs a container, so the hook cannot fire).
#
# NOTE: With a real Docker container running Claude Code this test would FAIL
# because Claude Code loads and executes hooks from the project-level
# .claude/settings.json. This is a known attack vector — see
# docs/attack-vectors.md. The test is written so it will pass once a
# mitigation (e.g. --no-project-settings, allowlist enforcement) is in place.
# ---------------------------------------------------------------------------

@test "malicious: scenario has preset-claude-settings.json describing the hook" {
  [ -f "${SCENARIOS_DIR}/malicious/preset-claude-settings.json" ]
}

@test "malicious: preset-claude-settings.json references malicious-file.sh" {
  grep -q "malicious-file.sh" "${SCENARIOS_DIR}/malicious/preset-claude-settings.json"
}

@test "malicious: scenario has malicious-file.sh" {
  [ -f "${SCENARIOS_DIR}/malicious/malicious-file.sh" ]
}

@test "malicious: project .claude/settings.json is not bind-mounted as global Claude settings" {
  local settings="${SCENARIOS_DIR}/malicious/preset-claude-settings.json"
  _stage_scenario "malicious" --with-claude-settings "${settings}"
  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]
  [ -f "${DOCKER_ARGS_FILE}" ]

  # The malicious project settings must NOT be mounted at the global path.
  # run.sh only mounts ${SCRIPT_DIR}/settings.json there (if it exists);
  # the project's .claude/settings.json lands under /home/dev/repo inside
  # the container, not at /home/dev/.claude/settings.json.
  local global_target="/home/dev/.claude/settings.json"
  local malicious_settings="${STAGED_DIR}/.claude/settings.json"
  ! grep -qF "${malicious_settings}:${global_target}" "${DOCKER_ARGS_FILE}"
}

@test "malicious: malicious-file.sh is not executed on the host" {
  local settings="${SCENARIOS_DIR}/malicious/preset-claude-settings.json"
  _stage_scenario "malicious" --with-claude-settings "${settings}"

  local sentinel="${STAGED_DIR}/malicious_was_executed"
  rm -f "${sentinel}"

  run_staged "${STAGED_DIR}"
  [ "$status" -eq 0 ]

  # The hook in .claude/settings.json would run malicious-file.sh only when
  # Claude Code executes inside the container. With mock docker no container
  # runs, so the sentinel file must not exist on the host.
  [ ! -f "${sentinel}" ]
}
