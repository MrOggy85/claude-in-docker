#!/usr/bin/env bats
#
# Integration tests for run.sh
#
# These tests stub `docker` so no daemon is needed. The stub writes every
# `docker run` invocation (one argument per line) to a file, letting us
# assert which flags run.sh assembled without actually running a container.
#
# Run with: bats test/run.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
RUN_SH="${SCRIPT_DIR}/run.sh"

setup() {
  # Isolated working directory so PROJECT_DIR is clean per test
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Scratch space for the docker stub's output files
  STUB_DIR="$(mktemp -d)"
  DOCKER_RUN_ARGS="${STUB_DIR}/docker-run-args.txt"
  DOCKER_ALL_CALLS="${STUB_DIR}/docker-all-calls.txt"

  # Point both the config dir and per-project config dirs at throwaway scratch so
  # test runs never read the developer's real ~/.config/claude-in-docker nor write
  # into it. Both are under STUB_DIR, cleaned up in teardown.
  export CLAUDE_DOCKER_CONFIG_DIR="${STUB_DIR}/config"
  export CLAUDE_PROJECTS_DIR="${STUB_DIR}/projects"
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  # The config-initialized guard aborts unless a baseline config-dir .env exists,
  # so seed one: every test runs from an "already ran make init" state. Tests that
  # exercise .env behaviour overwrite it; the guard test removes it deliberately.
  : > "${CLAUDE_DOCKER_CONFIG_DIR}/.env"
  # mcp-servers.json is likewise required by run.sh (part of the make-init
  # baseline), so seed a minimal one. MCP tests overwrite/remove it deliberately.
  printf '{"mcpServers":{}}\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/mcp-servers.json"

  # Create the docker stub. EOF is unquoted so ${STUB_DIR} vars expand now;
  # \$1, \$@, etc. are escaped and become real $ in the written script.
  mkdir -p "${STUB_DIR}/bin"
  cat > "${STUB_DIR}/bin/docker" << EOF
#!/usr/bin/env bash
# Log every call (space-separated) for debugging
echo "\$*" >> "${DOCKER_ALL_CALLS}"

case "\$1" in
  image)
    # image inspect: return exit 1 so run.sh thinks the image is missing and
    # proceeds to build it. The build call (next case) exits 0.
    exit 1
    ;;
  build)
    exit 0
    ;;
  container)
    # container inspect (egress-proxy liveness check): report the proxy as
    # already running so run.sh does NOT invoke proxy/up.sh — that would issue a
    # second 'docker run' and clobber DOCKER_RUN_ARGS with Squid's flags.
    echo "true"
    exit 0
    ;;
  network)
    exit 0
    ;;
  volume)
    case "\$2" in
      inspect) exit 1 ;;   # volume not found -> run.sh will create + chown it
      create)  exit 0 ;;
    esac
    ;;
  run)
    # The chown setup call (--entrypoint chown) fires when a new volume is
    # created; just let it succeed silently.
    if [[ "\$*" == *"--entrypoint chown"* ]]; then
      exit 0
    fi
    # Main `docker run ... IMAGE claude [args]`: write one arg per line so
    # tests can grep for exact flag/value pairs.
    printf '%s\n' "\$@" > "${DOCKER_RUN_ARGS}"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${STUB_DIR}/bin/docker"

  # Prepend stub to PATH
  export PATH="${STUB_DIR}/bin:${PATH}"

  # Global config now lives in the isolated CLAUDE_DOCKER_CONFIG_DIR, so the .env
  # and mcp-servers.json tests write there directly — no need to touch, back up,
  # or restore the developer's real config. Both files are wiped with STUB_DIR.
  ENV_FILE="${CLAUDE_DOCKER_CONFIG_DIR}/.env"
  MCP_ROOT="${CLAUDE_DOCKER_CONFIG_DIR}/mcp-servers.json"

  # Convenience: run run.sh from the isolated project dir with test-safe env vars
  # SKIP_CLAUDE_VOLUME_PATHS=1  — skip node_modules docker volume creation
  # CLAUDE_AUTO_USAGE=0         — skip post-run usage sync
  # MCP_GH_BEARER is unset/empty — avoid any accidental env leak
  RUN_CMD=(
    env
      SKIP_CLAUDE_VOLUME_PATHS=1
      CLAUDE_AUTO_USAGE=0
      MCP_GH_BEARER=""
    bash "${RUN_SH}"
  )

  # Compute the per-project config dir path that run.sh will use for TEST_PROJECT_DIR.
  # Mirror the SAFE_NAME + path_hash logic from run.sh.
  _SAFE_NAME="$(printf '%s' "$(basename "${TEST_PROJECT_DIR}")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  _SAFE_NAME="$(printf '%s' "${_SAFE_NAME}" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  if command -v sha256sum >/dev/null 2>&1; then
    _PATH_HASH="$(printf '%s' "${TEST_PROJECT_DIR}" | sha256sum | cut -c1-10)"
  else
    _PATH_HASH="$(printf '%s' "${TEST_PROJECT_DIR}" | shasum -a 256 | cut -c1-10)"
  fi
  PROJECT_CONFIG_DIR="${CLAUDE_PROJECTS_DIR}/${_SAFE_NAME:-repo}-${_PATH_HASH}"
}

teardown() {
  # STUB_DIR holds the isolated config dir, per-project dirs, and the docker stub,
  # so a single recursive remove cleans up everything a test created. Nothing is
  # written under SCRIPT_DIR anymore, so there is nothing there to restore.
  rm -rf "${TEST_PROJECT_DIR}" "${STUB_DIR}"
}

# Helper: assert that DOCKER_RUN_ARGS contains a line that is exactly VALUE.
# Each docker argument is written on its own line by the stub, so -x gives
# precise per-argument matching with no regex interpretation.
assert_run_arg() {
  grep -xqF -- "$1" "${DOCKER_RUN_ARGS}" || {
    echo "Expected docker run args to contain exactly: $1"
    echo "Actual args:"
    cat "${DOCKER_RUN_ARGS}" 2>/dev/null || echo "(args file not found)"
    return 1
  }
}

# Helper: assert a line is absent.
refute_run_arg() {
  if grep -xqF -- "$1" "${DOCKER_RUN_ARGS}" 2>/dev/null; then
    echo "Expected docker run args NOT to contain: $1"
    echo "Actual args:"
    cat "${DOCKER_RUN_ARGS}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# --resume HASH forwarding
# ---------------------------------------------------------------------------

@test "--resume HASH is forwarded verbatim to claude" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}" --resume abc123
  [ "$status" -eq 0 ]
  assert_run_arg "--resume"
  assert_run_arg "abc123"
}

@test "--resume with a longer hash is forwarded correctly" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}" --resume deadbeefcafe1234
  [ "$status" -eq 0 ]
  assert_run_arg "--resume"
  assert_run_arg "deadbeefcafe1234"
}

# ---------------------------------------------------------------------------
# CLI arguments forwarding
# ---------------------------------------------------------------------------

@test "no extra args: docker run ends with 'claude' and no extra flags" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  # 'claude' must appear as an argument (the command to run inside the container)
  assert_run_arg "claude"
  # No stray --resume in this run
  refute_run_arg "--resume"
}

@test "multiple CLI flags are all forwarded to claude" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}" --dangerously-skip-permissions --no-update
  [ "$status" -eq 0 ]
  assert_run_arg "--dangerously-skip-permissions"
  assert_run_arg "--no-update"
}

@test "positional argument (print) is forwarded to claude" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}" --print "hello world"
  [ "$status" -eq 0 ]
  assert_run_arg "--print"
  assert_run_arg "hello world"
}

# ---------------------------------------------------------------------------
# CLAUDE_PORTS integration
# ---------------------------------------------------------------------------

@test "CLAUDE_PORTS=3000: docker run includes --publish 3000:3000/tcp" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_PORTS="3000" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "--publish"
  assert_run_arg "3000:3000/tcp"
}

@test "CLAUDE_PORTS=3000: CONTAINER_OPEN_PORTS env is set to 3000/tcp" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_PORTS="3000" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "CONTAINER_OPEN_PORTS=3000/tcp"
}

@test "CLAUDE_PORTS with two ports: both --publish flags appear" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_PORTS="3000,4000" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "3000:3000/tcp"
  assert_run_arg "4000:4000/tcp"
}

@test "CLAUDE_PORTS with HOSTPORT:CPORT: correct --publish spec forwarded" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_PORTS="8080:3000" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "8080:3000/tcp"
}

@test "no CLAUDE_PORTS: no --publish flag in docker run" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_PORTS="" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  refute_run_arg "--publish"
}

# ---------------------------------------------------------------------------
# CLAUDE_MOUNTS (RO_MOUNTS) integration
# ---------------------------------------------------------------------------

@test "CLAUDE_MOUNTS with real dir: --volume flag appears in docker run" {
  local mount_src="${TEST_PROJECT_DIR}/extra"
  mkdir -p "${mount_src}"
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_MOUNTS="${mount_src}" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "--volume=${mount_src}:/home/dev/extra:ro"
}

@test "CLAUDE_MOUNTS with :rw: read-write volume flag appears" {
  local mount_src="${TEST_PROJECT_DIR}/writable"
  mkdir -p "${mount_src}"
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_MOUNTS="${mount_src}:rw" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  assert_run_arg "--volume=${mount_src}:/home/dev/writable:rw"
}

@test "CLAUDE_MOUNTS with non-existent path: no extra --volume for that path" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_MOUNTS="/nonexistent/path-that-does-not-exist" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  refute_run_arg "--volume=/nonexistent/path-that-does-not-exist"
}

@test "no CLAUDE_MOUNTS: standard mounts still present, no extra volumes" {
  cd "${TEST_PROJECT_DIR}"
  run env \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  # The primary repo mount is always present
  assert_run_arg "${TEST_PROJECT_DIR}:/home/dev/repo"
}

# ---------------------------------------------------------------------------
# .env / --env-file integration
# ---------------------------------------------------------------------------

@test ".env present: docker run includes --env-file pointing at it" {
  printf 'FOO=bar\n' > "${ENV_FILE}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--env-file"
  assert_run_arg "${ENV_FILE}"
}

@test ".env present: --env-file precedes --env HOME so it cannot clobber HOME" {
  printf 'HOME=/tmp/evil\n' > "${ENV_FILE}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  # The explicit HOME env must still be set...
  assert_run_arg "HOME=/home/dev"
  # ...and --env-file must appear on an earlier line than that explicit --env.
  local envfile_line home_line
  envfile_line="$(grep -nxF -- '--env-file' "${DOCKER_RUN_ARGS}" | head -1 | cut -d: -f1)"
  home_line="$(grep -nxF -- 'HOME=/home/dev' "${DOCKER_RUN_ARGS}" | head -1 | cut -d: -f1)"
  [ -n "${envfile_line}" ]
  [ -n "${home_line}" ]
  [ "${envfile_line}" -lt "${home_line}" ]
}

@test "no baseline .env: config-initialized guard aborts with a make-init hint" {
  rm -f "${ENV_FILE}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"make init"* ]]
}

# ---------------------------------------------------------------------------
# CLAUDE_VOLUME_PATHS guard: tilde-prefixed paths are rejected
# ---------------------------------------------------------------------------

@test "CLAUDE_VOLUME_PATHS with ~ path: skipped, no '~' volume target created" {
  cd "${TEST_PROJECT_DIR}"
  # Note: SKIP_CLAUDE_VOLUME_PATHS is intentionally NOT set, so the guard runs.
  run env \
    CLAUDE_AUTO_USAGE=0 \
    MCP_GH_BEARER="" \
    CLAUDE_VOLUME_PATHS="~/claude-macbook-help/claude-in-docker" \
    bash "${RUN_SH}"
  [ "$status" -eq 0 ]
  # The guard emits a skip notice...
  [[ "$output" == *"skipping volume path"* ]]
  # ...and no docker run arg contains a literal '~' (which would have become a
  # stray directory on the host via the bidirectional project bind mount).
  ! grep -qF '~' "${DOCKER_RUN_ARGS}"
}

# ---------------------------------------------------------------------------
# Standard flags always present
# ---------------------------------------------------------------------------

@test "docker run always uses --rm" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--rm"
}

@test "docker run always sets HOME env in container" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "HOME=/home/dev"
}

@test "docker run always sets --cap-add=NET_ADMIN" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--cap-add=NET_ADMIN"
}

# ---------------------------------------------------------------------------
# Egress proxy is always on (no longer opt-in)
# ---------------------------------------------------------------------------

@test "docker run always joins the egress network" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--network"
  assert_run_arg "claude-egress"
}

@test "docker run always sets EGRESS_PROXY_HOST=squid" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "EGRESS_PROXY_HOST=squid"
}

@test "docker run always points HTTPS_PROXY at squid with the project key as username" {
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "HTTPS_PROXY=http://${_SAFE_NAME:-repo}-${_PATH_HASH}:x@squid:3128"
}

# ---------------------------------------------------------------------------
# Per-project config directory
# ---------------------------------------------------------------------------

@test "per-project config dir is created on first run" {
  rm -rf "${PROJECT_CONFIG_DIR}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  [ -d "${PROJECT_CONFIG_DIR}" ]
}

@test "per-project .env is used when present (overrides root .env)" {
  mkdir -p "${PROJECT_CONFIG_DIR}"
  printf 'PROJECT_VAR=from-project\n' > "${PROJECT_CONFIG_DIR}/.env"
  # Root .env stays present (the guard requires it); the per-project one must win.
  printf 'ROOT_VAR=from-root\n' > "${ENV_FILE}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--env-file"
  assert_run_arg "${PROJECT_CONFIG_DIR}/.env"
}

@test "root .env is used when no per-project .env exists" {
  mkdir -p "${PROJECT_CONFIG_DIR}"
  rm -f "${PROJECT_CONFIG_DIR}/.env"
  printf 'ROOT_VAR=from-root\n' > "${ENV_FILE}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--env-file"
  assert_run_arg "${ENV_FILE}"
}

@test "allowed-domains.txt is never bind-mounted into the container (Squid owns the allowlist)" {
  # Egress filtering moved entirely to the Squid proxy; the container no longer
  # reads /etc/allowed-domains.txt, so run.sh must not mount any copy over it.
  mkdir -p "${PROJECT_CONFIG_DIR}"
  printf 'example.com\n' > "${PROJECT_CONFIG_DIR}/allowed-domains.txt"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  ! grep -qF "/etc/allowed-domains.txt" "${DOCKER_RUN_ARGS}"
}

@test "first run seeds an install stub and an empty allowed-domains.txt" {
  rm -rf "${PROJECT_CONFIG_DIR}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_CONFIG_DIR}/install_additional_packages.sh" ]
  # Not seeded from the baseline — Squid already applies it; created empty.
  [ -f "${PROJECT_CONFIG_DIR}/allowed-domains.txt" ]
  [ ! -s "${PROJECT_CONFIG_DIR}/allowed-domains.txt" ]
  # The seeded stub is all comments -> inert -> base image, no derived build.
  assert_run_arg "claude-code:local"
}

@test "per-project install script bakes a derived image and run uses it" {
  mkdir -p "${PROJECT_CONFIG_DIR}"
  printf '#!/bin/bash\napt-get install -y cowsay\n' > "${PROJECT_CONFIG_DIR}/install_additional_packages.sh"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  local _img="claude-code:${_SAFE_NAME:-repo}-${_PATH_HASH}"
  # A derived image was built on the fly (FROM the base) ...
  grep -qF "build --tag ${_img}" "${DOCKER_ALL_CALLS}"
  # ... and the container runs that derived image, not the base.
  assert_run_arg "${_img}"
  # No runtime install mount remains.
  ! grep -qF "project-install.sh" "${DOCKER_RUN_ARGS}"
}

@test "stub-only install script: base image is used and no derived image is built" {
  mkdir -p "${PROJECT_CONFIG_DIR}"
  # Only comments / blank lines -> treated as empty.
  printf '#!/bin/bash\n# nothing to install\n\n' > "${PROJECT_CONFIG_DIR}/install_additional_packages.sh"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "claude-code:local"
  local _img="claude-code:${_SAFE_NAME:-repo}-${_PATH_HASH}"
  ! grep -qF "build --tag ${_img}" "${DOCKER_ALL_CALLS}"
}

# ---------------------------------------------------------------------------
# mcp-servers.json (--mcp-config) integration
# ---------------------------------------------------------------------------

@test "no mcp-servers.json anywhere: run aborts with an error" {
  rm -f "${MCP_ROOT}"
  rm -rf "${PROJECT_CONFIG_DIR}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no mcp-servers.json found"* ]]
}

@test "per-project mcp-servers.json: --mcp-config flag and read-only mount appear" {
  mkdir -p "${PROJECT_CONFIG_DIR}"
  printf '{"mcpServers":{}}\n' > "${PROJECT_CONFIG_DIR}/mcp-servers.json"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--mcp-config"
  assert_run_arg "/home/dev/.mcp-servers.json"
  assert_run_arg "${PROJECT_CONFIG_DIR}/mcp-servers.json:/home/dev/.mcp-servers.json:ro"
}

@test "root mcp-servers.json: --mcp-config points at the mounted file" {
  printf '{"mcpServers":{}}\n' > "${MCP_ROOT}"
  cd "${TEST_PROJECT_DIR}"
  run "${RUN_CMD[@]}"
  [ "$status" -eq 0 ]
  assert_run_arg "--mcp-config"
  assert_run_arg "${MCP_ROOT}:/home/dev/.mcp-servers.json:ro"
}
