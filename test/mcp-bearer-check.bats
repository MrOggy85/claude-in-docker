#!/usr/bin/env bats
#
# Tests for the MCP_GH_BEARER token write-access guard in run.sh.
#
# Both `docker` and `curl` are stubbed — no daemon or network needed.
# curl stub behavior is driven by environment variables set in each test:
#
#   CURL_STUB_STATUS      HTTP status code string returned for /user
#                         (e.g. "200", "401"); empty → print nothing
#                         (simulates an unreachable API)
#   CURL_STUB_SCOPES      X-OAuth-Scopes header value; empty → omit the
#                         header entirely (simulates a fine-grained PAT)
#   CURL_STUB_REPOS_PUSH  "true" → include "push": true in /user/repos body
#
# Run with: bats test/mcp-bearer-check.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
RUN_SH="${SCRIPT_DIR}/run.sh"

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"
  # Capture PATH before we prepend the stub directory so the no-curl test
  # can build a sanitised PATH that excludes any real curl binary.
  ORIGINAL_PATH="${PATH}"

  mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/no-curl-bin"

  # --- docker stub (minimal: enough for run.sh to reach and pass the guard) ---
  cat > "${STUB_DIR}/bin/docker" << 'DOCKEREOF'
#!/usr/bin/env bash
case "$1" in
  image)  exit 1 ;;   # force a (no-op) build on every run
  build)  exit 0 ;;
  volume)
    case "$2" in
      inspect) exit 1 ;;   # volume not found → run.sh will create it
      create)  exit 0 ;;
    esac ;;
  run)    exit 0 ;;
esac
exit 0
DOCKEREOF
  chmod +x "${STUB_DIR}/bin/docker"

  # Copy the docker stub into the no-curl directory (used by the curl-absent test).
  cp "${STUB_DIR}/bin/docker" "${STUB_DIR}/no-curl-bin/docker"

  # --- curl stub ---
  # Single-quoted heredoc: shell variables inside expand at stub runtime,
  # not when this script writes the stub to disk.
  cat > "${STUB_DIR}/bin/curl" << 'CURLEOF'
#!/usr/bin/env bash
_url=""
for _arg in "$@"; do
  case "$_arg" in
    https://api.github.com/user/repos*) _url="repos" ;;
    https://api.github.com/user)        _url="user"  ;;
  esac
done

if [[ "$_url" == "repos" ]]; then
  if [[ "${CURL_STUB_REPOS_PUSH:-false}" == "true" ]]; then
    printf '[{"permissions": {"push": true}}]'
  else
    printf '[{"permissions": {"push": false}}]'
  fi
elif [[ "$_url" == "user" ]]; then
  _status="${CURL_STUB_STATUS:-}"
  if [[ -n "$_status" ]]; then
    printf "HTTP/2 %s\r\n" "$_status"
    _scopes="${CURL_STUB_SCOPES:-}"
    [[ -n "$_scopes" ]] && printf "x-oauth-scopes: %s\r\n" "$_scopes"
    printf "\r\n"
  fi
  # Empty CURL_STUB_STATUS → print nothing (simulates unreachable API).
fi
exit 0
CURLEOF
  chmod +x "${STUB_DIR}/bin/curl"

  export PATH="${STUB_DIR}/bin:${PATH}"
}

teardown() {
  rm -rf "${TEST_PROJECT_DIR}" "${STUB_DIR}"
}

# ---------------------------------------------------------------------------
# MCP_GH_BEARER unset / empty — guard is skipped entirely
# ---------------------------------------------------------------------------

@test "MCP_GH_BEARER unset: guard skipped, run.sh succeeds" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
}

@test "MCP_GH_BEARER empty string: guard skipped, run.sh succeeds" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# curl not in PATH — warn and continue (fail-open)
# ---------------------------------------------------------------------------

@test "curl not in PATH: prints warning and continues" {
  cd "${TEST_PROJECT_DIR}"
  # Symlink exactly the external commands run.sh needs into no-curl-bin,
  # intentionally omitting curl, then set PATH to that directory alone so
  # that `command -v curl` fails inside run.sh.  Invoke bash by its resolved
  # absolute path so env can find it even though /usr/bin (where curl also
  # lives) is absent from PATH.
  local _cmd _bin
  for _cmd in bash dirname basename tr sed cut id sha256sum shasum mkdir; do
    _bin="$(command -v "$_cmd" 2>/dev/null)" || true
    [[ -n "$_bin" && ! -e "${STUB_DIR}/no-curl-bin/${_cmd}" ]] && \
      ln -sf "$_bin" "${STUB_DIR}/no-curl-bin/${_cmd}"
  done
  run env \
    PATH="${STUB_DIR}/no-curl-bin" \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_testtoken" \
    "${STUB_DIR}/no-curl-bin/bash" "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"curl not found"* ]]
}

# ---------------------------------------------------------------------------
# 401 Unauthorized — reject immediately
# ---------------------------------------------------------------------------

@test "token returns 401: exits with error" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_invalidtoken" \
    CURL_STUB_STATUS="401" \
    bash "${RUN_SH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"invalid"* || "$output" == *"401"* ]]
}

# ---------------------------------------------------------------------------
# Classic OAuth token — write scopes are rejected
# ---------------------------------------------------------------------------

@test "classic token with 'repo' scope: exits with error naming the scope" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_classictoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="repo,read:user" \
    bash "${RUN_SH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"repo"* ]]
}

@test "classic token with 'workflow' scope: exits with error naming the scope" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_classictoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="workflow" \
    bash "${RUN_SH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"workflow"* ]]
}

@test "classic token with 'public_repo' scope: exits with error naming the scope" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_classictoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="public_repo" \
    bash "${RUN_SH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"public_repo"* ]]
}

# ---------------------------------------------------------------------------
# Classic OAuth token — read-only scopes are allowed
# ---------------------------------------------------------------------------

@test "classic token with read-only scopes: verified and succeeds" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_classictoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="read:user,read:org" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified read-only"* ]]
}

# ---------------------------------------------------------------------------
# Fine-grained PAT (no X-OAuth-Scopes header) — check push permission
# ---------------------------------------------------------------------------

@test "fine-grained PAT with push access: exits with error" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="github_pat_finetoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="" \
    CURL_STUB_REPOS_PUSH="true" \
    bash "${RUN_SH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"push"* ]]
}

@test "fine-grained PAT with no push access: verified and succeeds" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="github_pat_finetoken" \
    CURL_STUB_STATUS="200" \
    CURL_STUB_SCOPES="" \
    CURL_STUB_REPOS_PUSH="false" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified read-only"* ]]
}

# ---------------------------------------------------------------------------
# API unreachable (empty response) — warn and continue (fail-open)
# ---------------------------------------------------------------------------

@test "API unreachable (no response): warns and continues" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_testtoken" \
    CURL_STUB_STATUS="" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# Unexpected HTTP status codes — warn and continue (fail-open)
# ---------------------------------------------------------------------------

@test "API returns 403: warns with status and continues" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_testtoken" \
    CURL_STUB_STATUS="403" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"403"* ]]
}

@test "API returns 500: warns with status and continues" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="ghp_testtoken" \
    CURL_STUB_STATUS="500" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"500"* ]]
}
