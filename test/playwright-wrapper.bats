#!/usr/bin/env bats
#
# Unit tests for scripts/playwright-cli.sh — the PATH wrapper that injects the
# generated proxy config into playwright-cli calls.
#
# The thing under test is WHICH calls get `--config`. Only `open` and `attach`
# accept it; every other subcommand hard-errors with "Unknown option: --config",
# and those two are also the only ones that launch a browser. Getting that
# wrong breaks either every non-launch command or the proxy, so it is asserted
# both ways here.
#
# The real binary is stubbed by pointing NVM_DIR at a temp tree: the wrapper
# resolves "$NVM_DIR/default/bin/playwright-cli", so no Playwright is needed.
#
# Run with: bats test/playwright-wrapper.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
WRAPPER="${SCRIPT_DIR}/scripts/playwright-cli.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "${TEST_TMP}/nvm/default/bin"
  export NVM_DIR="${TEST_TMP}/nvm"
  # Echoes its own argv, one per line, so the test sees exactly what was passed.
  cat > "${TEST_TMP}/nvm/default/bin/playwright-cli" << 'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
  chmod +x "${TEST_TMP}/nvm/default/bin/playwright-cli"

  export CLAUDE_PLAYWRIGHT_CONFIG="${TEST_TMP}/cfg.json"
  printf '{}\n' > "${CLAUDE_PLAYWRIGHT_CONFIG}"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# --config, and the path after it, appear as adjacent lines in the forwarded argv.
assert_config_injected() {
  grep -qxF -- '--config' <<< "$output" || {
    echo "Expected --config to be injected. Forwarded argv:"; echo "$output"; return 1
  }
  grep -qxF -- "${CLAUDE_PLAYWRIGHT_CONFIG}" <<< "$output" || {
    echo "Expected the config path to be injected. Forwarded argv:"; echo "$output"; return 1
  }
}

refute_config_injected() {
  if grep -qxF -- '--config' <<< "$output"; then
    echo "Expected NO --config. Forwarded argv:"; echo "$output"; return 1
  fi
}

# ---------------------------------------------------------------------------
# The two launching subcommands get the config
# ---------------------------------------------------------------------------

@test "open: the config is injected" {
  run sh "${WRAPPER}" open https://example.com
  [ "$status" -eq 0 ]
  assert_config_injected
}

@test "attach: the config is injected" {
  run sh "${WRAPPER}" attach --cdp=chrome
  [ "$status" -eq 0 ]
  assert_config_injected
}

@test "open: the config is APPENDED, so it outranks one the caller passed" {
  run sh "${WRAPPER}" open https://example.com --config /their/own.json
  [ "$status" -eq 0 ]
  # Ours is last, and last wins.
  [ "$(tail -n1 <<< "$output")" = "${CLAUDE_PLAYWRIGHT_CONFIG}" ]
}

@test "open: the caller's own arguments are preserved and come first" {
  run sh "${WRAPPER}" open https://example.com --viewport-size 800x600
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<< "$output")" = "open" ]
  [ "$(sed -n 2p <<< "$output")" = "https://example.com" ]
  [ "$(sed -n 3p <<< "$output")" = "--viewport-size" ]
  [ "$(sed -n 4p <<< "$output")" = "800x600" ]
}

# ---------------------------------------------------------------------------
# Everything else must NOT get it — these subcommands reject the flag outright
# ---------------------------------------------------------------------------

@test "eval: no config (it hard-errors on the flag)" {
  run sh "${WRAPPER}" eval "() => 1"
  [ "$status" -eq 0 ]
  refute_config_injected
}

@test "goto, snapshot, screenshot, close: no config" {
  local c
  for c in goto snapshot screenshot close; do
    run sh "${WRAPPER}" "$c" x
    [ "$status" -eq 0 ]
    refute_config_injected
  done
}

@test "no arguments at all: no config, and no crash" {
  run sh "${WRAPPER}"
  [ "$status" -eq 0 ]
  refute_config_injected
}

@test "--help: no config" {
  run sh "${WRAPPER}" --help
  [ "$status" -eq 0 ]
  refute_config_injected
}

# ---------------------------------------------------------------------------
# Finding the subcommand past leading flags
# ---------------------------------------------------------------------------

@test "-s=<session> before open: still recognised as a launch" {
  run sh "${WRAPPER}" -s=mysession open https://example.com
  [ "$status" -eq 0 ]
  assert_config_injected
  [ "$(sed -n 1p <<< "$output")" = "-s=mysession" ]
}

@test "-s=<session> before eval: still recognised as a non-launch" {
  run sh "${WRAPPER}" -s=mysession eval "() => 1"
  [ "$status" -eq 0 ]
  refute_config_injected
}

# ---------------------------------------------------------------------------
# Absent pieces
# ---------------------------------------------------------------------------

@test "missing config file: open is forwarded unchanged rather than failing" {
  rm -f "${CLAUDE_PLAYWRIGHT_CONFIG}"
  run sh "${WRAPPER}" open https://example.com
  [ "$status" -eq 0 ]
  refute_config_injected
}

@test "missing real binary: exits 127 pointing at CLAUDE_BROWSER" {
  rm -f "${NVM_DIR}/default/bin/playwright-cli"
  # `run -127` rather than a bare `run`: 127 is the intended exit here, and bats
  # otherwise warns that it looks like a missing command.
  run -127 sh "${WRAPPER}" open https://example.com
  [[ "$output" == *"CLAUDE_BROWSER=1"* ]]
}

@test "the config path is never word-split, even with spaces" {
  local spaced="${TEST_TMP}/dir with spaces/cfg.json"
  mkdir -p "$(dirname "${spaced}")"
  printf '{}\n' > "${spaced}"
  export CLAUDE_PLAYWRIGHT_CONFIG="${spaced}"
  run sh "${WRAPPER}" open https://example.com
  [ "$status" -eq 0 ]
  [ "$(tail -n1 <<< "$output")" = "${spaced}" ]
}
