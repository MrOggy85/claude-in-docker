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
#
# Detach the run from any controlling terminal: the project-settings guard
# prompts by reading /dev/tty, and with no tty the read fails so the guard
# auto-declines (as in CI) instead of blocking. Without it, the malicious-
# settings scenario hangs when `bats test/` is run from an interactive shell.
#   - Linux/CI: `setsid -w` (util-linux); -w forwards the child's exit status.
#   - macOS (no setsid): Perl's core POSIX::setsid after a fork (ships with macOS).
run_staged() {
  local dir="$1"
  local tty_wrap=()
  if command -v setsid >/dev/null 2>&1; then
    tty_wrap=(setsid -w)
  elif command -v perl >/dev/null 2>&1; then
    tty_wrap=(perl -MPOSIX -e 'my $p=fork; if($p==0){POSIX::setsid(); exec @ARGV; exit 127} waitpid($p,0); exit($? >> 8)' --)
  fi
  run --separate-stderr "${tty_wrap[@]}" env \
    PATH="${MOCK_BIN}:${PATH}" \
    CLAUDE_AUTO_USAGE=0 \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR}" \
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
  # Keep per-project config dirs out of the repo's projects/ (cleaned with TEST_TMP).
  CLAUDE_PROJECTS_DIR="${TEST_TMP}/projects"
  export DOCKER_ARGS_FILE MOCK_BIN TEST_TMP CLAUDE_PROJECTS_DIR
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
# A project whose .claude/settings.json registers a PreToolUse hook that runs
# malicious-file.sh. Claude Code loads project-level settings from the mounted
# repo and executes their hooks inside the container, so a project that ships
# its own .claude/settings.json is an arbitrary-code-execution vector.
#
# run.sh must refuse to launch the container at all when the project carries a
# .claude/settings.json — that is the only point at which run.sh can intervene,
# since once the container starts Claude Code would load and fire the hook.
# Because the test uses mock docker (no real container, so the hook could never
# fire here regardless), the meaningful assertion is that run.sh aborts with a
# non-zero status and never issues the `docker run` that would start the
# container — not a check on the sentinel file, which mock docker leaves untouched.
# ---------------------------------------------------------------------------

@test "malicious: run.sh refuses to launch a project containing .claude/settings.json" {
  local settings="${SCENARIOS_DIR}/malicious/preset-claude-settings.json"
  _stage_scenario "malicious" --with-claude-settings "${settings}"
  run_staged "${STAGED_DIR}"

  # The guard must abort run.sh before any container is launched.
  [ "$status" -ne 0 ]
  # Mock docker only writes DOCKER_ARGS_FILE when the main `docker run` fires.
  # If the guard worked, the container was never started, so the file is
  # absent/empty and malicious-file.sh can never have run.
  [ ! -s "${DOCKER_ARGS_FILE}" ]
}

@test "malicious: CLAUDE_ALLOW_PROJECT_SETTINGS=1 overrides the guard" {
  local settings="${SCENARIOS_DIR}/malicious/preset-claude-settings.json"
  _stage_scenario "malicious" --with-claude-settings "${settings}"

  run --separate-stderr env \
    PATH="${MOCK_BIN}:${PATH}" \
    CLAUDE_AUTO_USAGE=0 \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_ALLOW_PROJECT_SETTINGS=1 \
    bash -c "cd '${STAGED_DIR}' && bash '${RUN_SH}'"

  # With the opt-in set, run.sh proceeds and launches the container as usual.
  [ "$status" -eq 0 ]
  [ -s "${DOCKER_ARGS_FILE}" ]
}
