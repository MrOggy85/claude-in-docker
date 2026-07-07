#!/usr/bin/env bats
#
# Unit tests for the pre-flight guards in guards/, exercised through run.sh
# (the guards are sourced fragments, not standalone scripts). `docker` is stubbed
# so no daemon is needed; the bearer guard is disabled with MCP_GH_BEARER="" so
# these tests isolate the home-dir and project-settings guards.
#
# The MCP_GH_BEARER guard has its own suite in mcp-bearer-check.bats.
#
# Run with: bats test/guards.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
RUN_SH="${SCRIPT_DIR}/run.sh"

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"

  # Keep the config dir and per-project config dirs out of the developer's real
  # ~/.config and the repo (both under STUB_DIR, cleaned with it). Seed a baseline
  # .env so the config-initialized guard passes and the guards under test run.
  export CLAUDE_DOCKER_CONFIG_DIR="${STUB_DIR}/config"
  export CLAUDE_PROJECTS_DIR="${STUB_DIR}/projects"
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  : > "${CLAUDE_DOCKER_CONFIG_DIR}/.env"

  # Minimal docker stub: succeed at everything so a clean run reaches (a no-op)
  # `docker run` and exits 0. Guards that abort exit before any docker call.
  mkdir -p "${STUB_DIR}/bin"
  cat > "${STUB_DIR}/bin/docker" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  image)  exit 1 ;;   # not found -> run.sh builds (no-op below)
  build)  exit 0 ;;
  container) echo "true"; exit 0 ;;  # egress proxy reported running -> skip up.sh
  network)   exit 0 ;;
  volume)
    case "$2" in
      inspect) exit 1 ;;
      create)  exit 0 ;;
    esac ;;
  run)    exit 0 ;;
esac
exit 0
EOF
  chmod +x "${STUB_DIR}/bin/docker"
  export PATH="${STUB_DIR}/bin:${PATH}"

  # Common test-safe env: skip node_modules volumes, post-run usage sync, and the
  # bearer guard. </dev/null on the run calls keeps the project-settings prompt
  # non-interactive (treated as declined).
  COMMON_ENV=(
    SKIP_CLAUDE_VOLUME_PATHS=1
    CLAUDE_AUTO_USAGE=0
    MCP_GH_BEARER=""
  )
}

teardown() {
  rm -rf "${TEST_PROJECT_DIR}" "${STUB_DIR}"
}

# Run run.sh detached from any controlling terminal. The project-settings guard
# prompts by reading /dev/tty; with no tty (as in CI) the read fails and the
# guard auto-declines. Without this, running `bats test/` from an interactive
# shell blocks on that prompt. A fresh, tty-less session makes the /dev/tty open
# fail so the guard declines deterministically.
#   - Linux/CI: `setsid -w` (util-linux); -w forwards the child's exit status.
#   - macOS (no setsid): Perl's core POSIX::setsid after a fork (Perl ships with
#     macOS); the parent waits and re-exports the child's status.
run_no_tty() {
  if command -v setsid >/dev/null 2>&1; then
    run setsid -w "$@"
  elif command -v perl >/dev/null 2>&1; then
    run perl -MPOSIX -e 'my $p=fork; if($p==0){POSIX::setsid(); exec @ARGV; exit 127} waitpid($p,0); exit($? >> 8)' -- "$@"
  else
    run "$@"
  fi
}

# ---------------------------------------------------------------------------
# guards/no-home-dir.sh
# ---------------------------------------------------------------------------

@test "home-dir guard: running from \$HOME aborts with exit 1" {
  cd "${TEST_PROJECT_DIR}"
  # Make PROJECT_DIR ($(pwd)) equal to HOME so the guard trips.
  run env HOME="${TEST_PROJECT_DIR}" "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"home directory"* ]]
}

@test "home-dir guard: a subdirectory of \$HOME is allowed" {
  local sub="${TEST_PROJECT_DIR}/project"
  mkdir -p "${sub}"
  cd "${sub}"
  # HOME is the parent; the working dir is a subdir, so the guard must NOT trip.
  run env HOME="${TEST_PROJECT_DIR}" "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"home directory is not allowed"* ]]
}

# ---------------------------------------------------------------------------
# guards/project-settings.sh
#
# The interactive view/proceed paths require a real terminal and are not
# exercised here. These tests cover detection, the non-interactive abort
# (no /dev/tty -> declined -> exit 1), and the opt-in bypass.
# ---------------------------------------------------------------------------

@test "project-settings guard: .claude/settings.json aborts with exit 1" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  echo '{}' > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings.json"* ]]
}

@test "project-settings guard: .claude/settings.local.json also aborts with exit 1" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  echo '{}' > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings.local.json"* ]]
}

@test "project-settings guard: CLAUDE_ALLOW_PROJECT_SETTINGS=1 bypasses the guard" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  echo '{}' > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_ALLOW_PROJECT_SETTINGS=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
}

@test "project-settings guard: no project settings -> run proceeds" {
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
}
