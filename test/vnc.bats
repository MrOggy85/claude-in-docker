#!/usr/bin/env bats
#
# Unit tests for scripts/vnc.sh — the host side of `cid vnc`.
#
# `docker` is stubbed so no daemon is needed. The stub logs every invocation to
# ${DOCKER_LOG}, one argv per line, and its answers are driven by env vars:
#   STUB_CONTAINERS  newline-separated names `docker ps --filter` returns
#   STUB_PORT        what `docker port` prints ("" = not published)
#   STUB_NO_DISPLAY  set to make the X-socket test fail
#   STUB_NO_ALIVE    set to make the pgrep fail even after a start (the
#                    "websockify never came up" path)
#
# websockify liveness is STATEFUL, via ${STUB_STATE}/ws.running: launching it
# creates the flag and pkill removes it, so `start` sees not-running first and
# running on a second call. A flag-less "always alive" stub would make the
# idempotence and the launch tests mutually unsatisfiable.
#
# Run with: bats test/vnc.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
VNC="${SCRIPT_DIR}/scripts/vnc.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/proj"
  export DOCKER_LOG="${TEST_TMP}/docker.log"
  : > "${DOCKER_LOG}"

  export STUB_STATE="${TEST_TMP}"
  cat > "${TEST_TMP}/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
case "$1" in
  ps)   [[ -n "${STUB_CONTAINERS:-}" ]] && printf '%s\n' "${STUB_CONTAINERS}"; exit 0 ;;
  port) [[ -n "${STUB_PORT:-}" ]] && printf '%s\n' "${STUB_PORT}"; exit 0 ;;
  exec)
    # Which exec this is, is decided by the argv the script passes. pgrep/pkill
    # are matched before the launch patterns: their own argv names websockify too.
    case "$*" in
      *"X11-unix"*) [[ -n "${STUB_NO_DISPLAY:-}" ]] && exit 1; exit 0 ;;
      *"printenv CLAUDE_BROWSER_ON"*)
        # Unset unless the stub is told the session enabled the browser.
        [[ -n "${STUB_BROWSER_ENABLED:-}" ]] && { echo 1; exit 0; }
        exit 1 ;;
      *"pgrep -f chrom"*)
        # The "is anything drawn on the display" probe, distinct from the
        # websockify liveness one below. Matched first: both are pgrep calls.
        [[ -n "${STUB_BROWSER_OPEN:-}" ]] && exit 0
        exit 1 ;;
      *pgrep*)
        [[ -n "${STUB_NO_ALIVE:-}" ]] && exit 1
        [[ -f "${STUB_STATE}/ws.running" ]] && exit 0
        exit 1 ;;
      *pkill*)       rm -f "${STUB_STATE}/ws.running"; exit 0 ;;
      *storepasswd*) exit 0 ;;
      *websockify*)  touch "${STUB_STATE}/ws.running"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
esac
exit 1
EOF
  chmod +x "${TEST_TMP}/bin/docker"
  export PATH="${TEST_TMP}/bin:${PATH}"

  export CLAUDE_DOCKER_CONFIG_DIR="${TEST_TMP}/config"
  export CLAUDE_PROJECTS_DIR="${TEST_TMP}/config/projects"
  mkdir -p "${CLAUDE_PROJECTS_DIR}"
  # Never spawn a real browser from the test suite.
  export CLAUDE_VNC_OPEN=0
  export NO_COLOR=1

  export STUB_CONTAINERS="claude-proj-deadbeef"
  export STUB_PORT="0.0.0.0:6080"
  PROJ="${TEST_TMP}/proj"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# Assert the docker stub was called with an argv containing this substring.
assert_docker() {
  grep -qF -- "$1" "${DOCKER_LOG}" || {
    echo "Expected a docker call containing: $1"
    echo "Actual calls:"
    cat "${DOCKER_LOG}"
    return 1
  }
}

refute_docker() {
  if grep -qF -- "$1" "${DOCKER_LOG}"; then
    echo "Expected NO docker call containing: $1"
    echo "Actual calls:"
    cat "${DOCKER_LOG}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Container resolution
# ---------------------------------------------------------------------------

@test "resolves the container through the project-key label, not the name" {
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  assert_docker "label=cid.project-key=proj-"
}

@test "no running container names the directory and the project" {
  export STUB_CONTAINERS=""
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no session is running"* ]]
  [[ "$output" == *"${PROJ}"* ]]
  [[ "$output" == *"CLAUDE_BROWSER=1"* ]]
}

@test "several containers for one project ask for --container" {
  export STUB_CONTAINERS=$'claude-proj-aaaa\nclaude-proj-bbbb'
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 containers are running"* ]]
  [[ "$output" == *"--container"* ]]
  [[ "$output" == *"claude-proj-aaaa"* ]]
}

@test "--container skips resolution entirely" {
  export STUB_CONTAINERS=""
  run bash "${VNC}" url -C "${PROJ}" --container my-box
  [ "$status" -eq 0 ]
  refute_docker "label=cid.project-key"
  assert_docker "port my-box 6080/tcp"
}

# ---------------------------------------------------------------------------
# URL
# ---------------------------------------------------------------------------

@test "url: a wildcard bind is reported as loopback" {
  export STUB_PORT="0.0.0.0:49155"
  run bash "${VNC}" url -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == "http://127.0.0.1:49155/vnc.html?"* ]]
}

@test "url: an explicit bind address is kept" {
  export STUB_PORT="192.168.1.5:6080"
  run bash "${VNC}" url -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == "http://192.168.1.5:6080/vnc.html?"* ]]
}

@test "url: carries the password" {
  run bash "${VNC}" url -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"password="* ]]
}

@test "url: an unpublished port says the session lacked CLAUDE_BROWSER" {
  export STUB_PORT=""
  run bash "${VNC}" url -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not publish port 6080"* ]]
}

# ---------------------------------------------------------------------------
# Password
# ---------------------------------------------------------------------------

@test "password: generated once, mode 600, and reused" {
  run bash "${VNC}" url -C "${PROJ}"
  [ "$status" -eq 0 ]
  local first="$output"
  local pfile
  pfile="$(find "${CLAUDE_PROJECTS_DIR}" -name vnc.pass)"
  [ -n "${pfile}" ]
  # 600 on Linux, 600 on macOS stat too — compare the symbolic form.
  [[ "$(ls -l "${pfile}")" == -rw-------* ]]
  run bash "${VNC}" url -C "${PROJ}"
  [ "$output" = "${first}" ]
}

@test "password: never passed in the container argv" {
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  # -storepasswd takes it via a positional to `sh -c`, and x11vnc then reads the
  # hashed file. The plaintext must not appear on the x11vnc command line.
  local pass
  pass="$(cat "$(find "${CLAUDE_PROJECTS_DIR}" -name vnc.pass)")"
  grep -F "x11vnc -display" "${DOCKER_LOG}" | grep -qvF "${pass}"
}

# ---------------------------------------------------------------------------
# start / stop / status
# ---------------------------------------------------------------------------

@test "start: refuses when there is no X display" {
  export STUB_NO_DISPLAY=1 STUB_BROWSER_ENABLED=1
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no X display"* ]]
  [[ "$output" == *"Xvfb did not start"* ]]
  refute_docker "websockify"
}

# Every container carries the project-key label, so `cid vnc` finds sessions that
# never had a browser. Blaming Xvfb there sends the user hunting for a failure
# that never happened; the fix is a relaunch flag, not a diagnosis.
@test "start: a session without CLAUDE_BROWSER says so, not 'Xvfb failed'" {
  export STUB_NO_DISPLAY=1
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without CLAUDE_BROWSER=1"* ]]
  [[ "$output" != *"Xvfb did not start"* ]]
}

@test "status: a session without CLAUDE_BROWSER says so too" {
  export STUB_NO_DISPLAY=1
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"without CLAUDE_BROWSER=1"* ]]
}

@test "no session at all is not blamed on the browser flag" {
  export STUB_CONTAINERS=""
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no session is running"* ]]
}

@test "start: launches x11vnc on loopback and websockify on 6080" {
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  assert_docker "x11vnc -display :99"
  assert_docker "-localhost"
  assert_docker "websockify --web=/usr/share/novnc 6080 127.0.0.1:5900"
  [[ "$output" == *"noVNC is up"* ]]
}

@test "start: is idempotent when websockify already runs" {
  touch "${STUB_STATE}/ws.running"
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  refute_docker "storepasswd"
}

@test "start: reports failure when websockify never comes up" {
  export STUB_NO_ALIVE=1
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not stay up"* ]]
}

@test "stop: kills both, and says the browser survives" {
  touch "${STUB_STATE}/ws.running"
  run bash "${VNC}" stop -C "${PROJ}"
  [ "$status" -eq 0 ]
  assert_docker "pkill -f websockify --web"
  assert_docker "pkill -x x11vnc"
  [[ "$output" == *"keep running"* ]]
}

@test "stop: nothing running is not an error" {
  run bash "${VNC}" stop -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no noVNC running"* ]]
  refute_docker "pkill"
}

@test "status: reports display and noVNC separately" {
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"X display running"* ]]
  [[ "$output" == *"noVNC NOT running"* ]]
  [[ "$output" == *"cid vnc start"* ]]
}

# ---------------------------------------------------------------------------
# Telling the user WHICH session they are looking at, and why it may be blank.
# The container name is random and the URL is a bare port, so neither answers it.
# ---------------------------------------------------------------------------

@test "start: names the project key and the directory it came from" {
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project"*"proj-"* ]]
  [[ "$output" == *"${PROJ}"* ]]
  [[ "$output" == *"container"*"claude-proj-deadbeef"* ]]
}

@test "status: names the project key and directory too" {
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project"*"proj-"* ]]
  [[ "$output" == *"${PROJ}"* ]]
}

@test "start: warns that the screen is blank when no browser is open" {
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"screen will be blank"* ]]
  [[ "$output" == *"playwright-cli open"* ]]
}

@test "start: no blank-screen warning once a browser is open" {
  export STUB_BROWSER_OPEN=1
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"screen will be blank"* ]]
}

@test "status: distinguishes a working display from one with nothing on it" {
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no browser open yet"* ]]
  export STUB_BROWSER_OPEN=1
  run bash "${VNC}" status -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a browser is open on that display"* ]]
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

@test "start is the default verb" {
  run bash "${VNC}" -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"noVNC"* ]]
}

@test "an unknown verb exits 2" {
  run bash "${VNC}" frobnicate -C "${PROJ}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"start | stop | status | url"* ]]
}

@test "two verbs exit 2" {
  run bash "${VNC}" start stop -C "${PROJ}"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# _containers — the internal verb completions/_cid calls for --container
# ---------------------------------------------------------------------------

@test "_containers: lists this project's running containers, one per line" {
  export STUB_CONTAINERS=$'claude-proj-aaaa\nclaude-proj-bbbb'
  run bash "${VNC}" _containers -C "${PROJ}"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<< "$output")" = "claude-proj-aaaa" ]
  [ "$(sed -n 2p <<< "$output")" = "claude-proj-bbbb" ]
  assert_docker "label=cid.project-key=proj-"
}

@test "_containers: several matches are listed, not treated as an error" {
  # Unlike the other verbs, which refuse to guess — here more than one is the
  # whole point, since it is what the user is choosing between.
  export STUB_CONTAINERS=$'claude-proj-aaaa\nclaude-proj-bbbb'
  run bash "${VNC}" _containers -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"containers are running"* ]]
}

@test "_containers: nothing running is empty output and exit 0" {
  export STUB_CONTAINERS=""
  run bash "${VNC}" _containers -C "${PROJ}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_containers: no docker is empty output and exit 0, never an error" {
  # A completion must not error at the user, so this fails open and silent.
  rm -f "${TEST_TMP}/bin/docker"
  run bash "${VNC}" _containers -C "${PROJ}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--help exits 0 without touching docker" {
  run bash "${VNC}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/vnc.sh"* ]]
  [ ! -s "${DOCKER_LOG}" ]
}

@test "CLAUDE_VNC_OPEN_CMD is used instead of open/xdg-open" {
  export CLAUDE_VNC_OPEN=1
  export CLAUDE_VNC_OPEN_CMD="${TEST_TMP}/bin/opener"
  cat > "${TEST_TMP}/bin/opener" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" > "${TEST_TMP}/opened"
EOF
  chmod +x "${TEST_TMP}/bin/opener"
  run bash "${VNC}" start -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$(cat "${TEST_TMP}/opened")" == "http://127.0.0.1:6080/vnc.html?"* ]]
}
