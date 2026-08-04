#!/usr/bin/env bats
#
# Unit tests for scripts/path-volumes.sh
#
# `docker` is stubbed so no daemon is needed: every call is logged to a file, so a
# test can assert which volumes were created and that the ownership pass ran.
#
# Run with: bats test/path-volumes.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

# `run --separate-stderr` (used to assert on the token stream alone) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PATH_VOLUMES="${SCRIPT_DIR}/scripts/path-volumes.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  PROJ="${TEST_TMP}/proj"
  mkdir -p "${PROJ}"
  DOCKER_CALLS="${TEST_TMP}/docker-calls.txt"

  # Docker stub. EOF unquoted so ${DOCKER_CALLS} expands now; \$ survives as $.
  # STUB_VOLUME_EXISTS makes `volume inspect` succeed (the already-created path);
  # STUB_FAIL names a subcommand that should fail, for the fail-closed tests.
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/docker" << EOF
#!/usr/bin/env bash
echo "\$*" >> "${DOCKER_CALLS}"
[[ "\$1 \$2" == "\${STUB_FAIL:-}" || "\$1" == "\${STUB_FAIL:-}" ]] && exit 1
case "\$1" in
  volume)
    case "\$2" in
      inspect) [[ -n "\${STUB_VOLUME_EXISTS:-}" ]] && exit 0 || exit 1 ;;
    esac
    ;;
esac
exit 0
EOF
  chmod +x "${TEST_TMP}/bin/docker"
  export PATH="${TEST_TMP}/bin:${PATH}"

  # Every test runs the script against the throwaway project dir.
  RUN_PV=(env PROJECT_DIR="${PROJ}" REPO_IN_CONTAINER="/home/dev/repo" IMAGE="img:test" bash "${PATH_VOLUMES}")
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# The volume name derivation, mirroring scripts/paths.sh (safe_name + path_hash).
vol_name() {  # <repo-relative path>
  local base sn hash
  base="$(basename "${PROJ}")"
  sn="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
        | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "${PROJ}/$1" | sha256sum | cut -c1-10)"
  else
    hash="$(printf '%s' "${PROJ}/$1" | shasum -a 256 | cut -c1-10)"
  fi
  printf 'claude-vol-%s-%s' "${sn:-repo}" "$hash"
}

# ---------------------------------------------------------------------------
# Nothing to back
# ---------------------------------------------------------------------------

@test "no package.json: no tokens, no docker calls at all" {
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "${DOCKER_CALLS}" ]
}

@test "SKIP_CLAUDE_VOLUME_PATHS: no tokens, a notice on stderr, no docker calls" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    SKIP_CLAUDE_VOLUME_PATHS=1 \
    bash "${PATH_VOLUMES}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"SKIP_CLAUDE_VOLUME_PATHS set"* ]]
  [ ! -f "${DOCKER_CALLS}" ]
}

# ---------------------------------------------------------------------------
# Automatic node_modules coverage
# ---------------------------------------------------------------------------

@test "root package.json: emits the node_modules mount and creates the volume" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--volume=$(vol_name node_modules):/home/dev/repo/node_modules"* ]]
  grep -q "^volume create $(vol_name node_modules)$" "${DOCKER_CALLS}"
}

@test "workspace package.json: each dir gets its own volume" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  mkdir -p "${PROJ}/packages/a"
  printf '{"name":"a"}\n' > "${PROJ}/packages/a/package.json"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *":/home/dev/repo/node_modules"* ]]
  [[ "$output" == *":/home/dev/repo/packages/a/node_modules"* ]]
}

@test "a path is backed only once when auto and CLAUDE_VOLUME_PATHS overlap" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    CLAUDE_VOLUME_PATHS="node_modules, auto" \
    bash "${PATH_VOLUMES}"
  [ "$status" -eq 0 ]
  [ "$(grep -c ':/home/dev/repo/node_modules$' <<< "$output")" -eq 1 ]
}

@test "paths outside the repo are rejected with a skip notice" {
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    CLAUDE_VOLUME_PATHS="/etc, ../escape, ~/home" \
    bash "${PATH_VOLUMES}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c 'skipping volume path' <<< "$stderr")" -eq 3 ]
}

@test "a path that already has contents on the host warns" {
  mkdir -p "${PROJ}/.deno"
  : > "${PROJ}/.deno/leftover"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    CLAUDE_VOLUME_PATHS=".deno" \
    bash "${PATH_VOLUMES}"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already has contents on the host"* ]]
}

# ---------------------------------------------------------------------------
# Ownership pass — runs on every invocation, not just at creation
# ---------------------------------------------------------------------------

@test "ownership pass runs for a volume that already exists" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    STUB_VOLUME_EXISTS=1 \
    bash "${PATH_VOLUMES}"
  [ "$status" -eq 0 ]
  ! grep -q '^volume create' "${DOCKER_CALLS}"
  grep -q -- '--entrypoint sh' "${DOCKER_CALLS}"
  # Every backed path is mounted flat under /v for that one container.
  grep -q -- ':/v/0' "${DOCKER_CALLS}"
}

@test "ownership pass is skipped when nothing is backed" {
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [ ! -f "${DOCKER_CALLS}" ]
}

@test "a failing ownership pass is fatal (no container may start unwritable)" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    STUB_FAIL="run" \
    bash "${PATH_VOLUMES}"
  [ "$status" -ne 0 ]
}

@test "a failing volume create is fatal" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr env \
    PROJECT_DIR="${PROJ}" \
    IMAGE="img:test" \
    STUB_FAIL="volume create" \
    bash "${PATH_VOLUMES}"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# pnpm store
# ---------------------------------------------------------------------------

@test "pnpm-lock.yaml: store dir points inside the root node_modules volume" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  : > "${PROJ}/pnpm-lock.yaml"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--env=npm_config_store_dir=/home/dev/repo/node_modules/.pnpm-store"* ]]
}

@test "pnpm workspace root without a package.json: root node_modules is still backed" {
  : > "${PROJ}/pnpm-workspace.yaml"
  mkdir -p "${PROJ}/packages/a"
  printf '{"name":"a"}\n' > "${PROJ}/packages/a/package.json"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *":/home/dev/repo/node_modules"* ]]
  [[ "$output" == *"--env=npm_config_store_dir=/home/dev/repo/node_modules/.pnpm-store"* ]]
}

@test "npm-only project: the store dir is still set (inert for npm and yarn)" {
  printf '{"name":"t"}\n' > "${PROJ}/package.json"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--env=npm_config_store_dir="* ]]
}

@test "no root node_modules volume: no store dir (it would land on the host)" {
  mkdir -p "${PROJ}/packages/a"
  printf '{"name":"a"}\n' > "${PROJ}/packages/a/package.json"
  run --separate-stderr "${RUN_PV[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"npm_config_store_dir"* ]]
}
