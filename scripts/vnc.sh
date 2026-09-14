#!/usr/bin/env bash
#
# Watch the in-container browser over noVNC. Runs on the HOST and owns every
# `docker` call `cid vnc` needs — `cid` itself stays docker-free, the way it
# delegates the egress watcher to proxy/watch.sh. See docs/browser-vnc.md.
#
# The X display (:99) is started by entrypoint.sh with the container, because
# Chromium inherits DISPLAY at launch. x11vnc and websockify are NOT: they only
# attach to an existing display, so they start here, on demand, and cost nothing
# in a session nobody watches. The published port is reserved at container start
# either way (run.sh step 3c-e) — Docker cannot publish one on a running
# container.
#
# Verbs:
#   start (default)  start x11vnc + websockify in the container, print and open
#                    the URL. Idempotent.
#   stop             kill both. The display and the browser keep running.
#   status           is anything listening, and where
#   url              print the URL only (no start, no open) — for scripts
#
# Env: CLAUDE_VNC_OPEN, CLAUDE_VNC_OPEN_CMD, CLAUDE_BROWSER_DISPLAY.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./paths.sh disable=SC1091
source "${REPO_DIR}/scripts/paths.sh"
# shellcheck source=./colors.sh disable=SC1091
source "${REPO_DIR}/scripts/colors.sh"
color_init 1

PROJECTS_DIR="$(projects_dir)"

# Inside the container. 5900 is x11vnc's RFB port, bound to loopback so the only
# way in is through websockify on 6080, which is the published one.
VNC_PORT=5900
NOVNC_PORT=6080
DISPLAY_IN_CONTAINER="${CLAUDE_BROWSER_DISPLAY:-:99}"

TARGET_DIR="${PWD}"
CONTAINER=""

# ---------------------------------------------------------------------------
# Container resolution
# ---------------------------------------------------------------------------

# The project this invocation is about, derived from the working directory the
# same way run.sh derives it. Printed by every verb: the container name is random
# and the URL is a bare port, so without this there is nothing on screen that
# says WHICH session you are looking at.
_target_key() {
  local dir
  dir="$(cd "${TARGET_DIR}" 2>/dev/null && pwd)" || return 1
  project_key "${dir}"
}

_target_dir() {
  cd "${TARGET_DIR}" 2>/dev/null && pwd
}

# run.sh gives the container a random name suffix and records it nowhere, so the
# project-key label it also sets is the only handle. --rm makes that label
# self-cleaning: a dead session cannot be matched.
_resolve_container() {
  if [[ -n "${CONTAINER}" ]]; then
    printf '%s' "${CONTAINER}"
    return 0
  fi
  local dir key names n
  dir="$(cd "${TARGET_DIR}" 2>/dev/null && pwd)" || { fail "no such dir: ${TARGET_DIR}"; return 1; }
  key="$(project_key "${dir}")"
  names="$(docker ps --filter "label=cid.project-key=${key}" --format '{{.Names}}' 2>/dev/null || true)"
  n="$(printf '%s' "${names}" | grep -c . || true)"
  if [[ "${n}" == 0 ]]; then
    # run.sh labels EVERY container, browser or not, so zero matches means no
    # session is running here at all — not that the browser was left off.
    fail "no session is running in ${dir}" \
         "(project ${key})" \
         "Start one with: CLAUDE_BROWSER=1 ./run.sh"
    return 1
  fi
  if [[ "${n}" -gt 1 ]]; then
    fail "${n} containers are running for project ${key}:"
    printf '%s\n' "${names}" | while IFS= read -r c; do cont "  ${c}"; done
    cont "Pick one with: cid vnc ${VERB:-start} --container <name>"
    return 1
  fi
  printf '%s' "${names}"
}

# The host side of the published noVNC port. run.sh reserves it but cannot know
# the number when CLAUDE_VNC_PORT=0, so ask Docker rather than recompute it.
_host_endpoint() {  # <container>
  local mapped
  mapped="$(docker port "$1" "${NOVNC_PORT}/tcp" 2>/dev/null | head -n1 || true)"
  [[ -n "${mapped}" ]] || return 1
  # "0.0.0.0:6080" / "[::]:6080" — a wildcard bind is reached over loopback.
  case "${mapped}" in
    0.0.0.0:*|'[::]:'*) printf '127.0.0.1:%s' "${mapped##*:}" ;;
    *)                  printf '%s' "${mapped}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Password
# ---------------------------------------------------------------------------

# noVNC hands over full keyboard and mouse control of a browser that is holding
# whatever the session logged into, so loopback-only publishing is not enough on
# its own. Per project and persistent, like the bridge tokens run.sh mints.
_password() {  # <container>
  local dir key pfile
  dir="$(cd "${TARGET_DIR}" 2>/dev/null && pwd)"
  key="$(project_key "${dir}")"
  pfile="${PROJECTS_DIR}/${key}/vnc.pass"
  if [[ ! -s "${pfile}" ]]; then
    mkdir -p "$(dirname "${pfile}")"
    # 8 hex chars: x11vnc truncates a VNC password at 8 bytes anyway, so a longer
    # one would be security theatre. The real boundary is the loopback bind.
    od -An -tx1 -N4 /dev/urandom | tr -d ' \n' > "${pfile}"
    chmod 600 "${pfile}"
  fi
  cat "${pfile}"
}

# ---------------------------------------------------------------------------
# Liveness
# ---------------------------------------------------------------------------

# Ask the container what is running rather than tracking a pid here: the
# container can exit at any time and a pidfile on the host would outlive it.
# -f, not -x: Debian's websockify is a python script, so its comm is "python3".
# The pattern is the full flag so this cannot match our own `docker exec` shell.
WEBSOCKIFY_PAT="websockify --web"
_alive() {  # <container>
  docker exec "$1" pgrep -f "${WEBSOCKIFY_PAT}" >/dev/null 2>&1
}

_display_up() {  # <container>
  docker exec "$1" test -e "/tmp/.X11-unix/X${DISPLAY_IN_CONTAINER#:}" >/dev/null 2>&1
}

# Was this session started with CLAUDE_BROWSER=1 at all? Every container carries
# the project-key label, browser or not, so a match here says nothing about
# whether there is a display — and "Xvfb failed" is the wrong thing to tell
# someone whose session simply never had a browser.
_browser_enabled() {  # <container>
  [[ "$(docker exec "$1" printenv CLAUDE_BROWSER_ON 2>/dev/null || true)" == 1 ]]
}

# Is anything actually drawn on that display? Xvfb plus openbox is a blank root
# window, which looks identical to a broken setup — so answer the question
# outright instead of leaving the user staring at grey. "chrom" covers both
# `chrome` (the Playwright build) and `chromium` (a distro one); pgrep already
# excludes its own process, so no [c]hrome-style trick is needed.
_browser_running() {  # <container>
  docker exec "$1" pgrep -f chrom >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Opening the URL
# ---------------------------------------------------------------------------

# Backend precedence mirrors scripts/notify.sh: an explicit override, then the
# platform opener, then nothing (the URL is always printed regardless).
_open_url() {  # <url>
  case "${CLAUDE_VNC_OPEN:-1}" in 0|false|no|off|FALSE|NO|OFF) return 0 ;; esac
  if   [[ -n "${CLAUDE_VNC_OPEN_CMD:-}" ]];  then ${CLAUDE_VNC_OPEN_CMD} "$1" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1;      then open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1;  then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

_url() {
  local c ep pass
  c="$(_resolve_container)" || return 1
  if ! ep="$(_host_endpoint "${c}")"; then
    fail "container ${c} does not publish port ${NOVNC_PORT}" \
         "It was started without CLAUDE_BROWSER=1. Restart the session with it set."
    return 1
  fi
  pass="$(_password "${c}")"
  printf 'http://%s/vnc.html?autoconnect=1&resize=scale&password=%s\n' "${ep}" "${pass}"
}

_start() {
  local c url pass
  c="$(_resolve_container)" || return 1
  CONTAINER="${c}"   # so the _url below does not re-query docker
  if ! _display_up "${c}"; then
    if _browser_enabled "${c}"; then
      fail "no X display on ${DISPLAY_IN_CONTAINER} in ${c}" \
           "The browser is enabled but Xvfb did not start." \
           "Check the session's first lines for a warning."
    else
      fail "${c} was started without CLAUDE_BROWSER=1" \
           "It is this project's running session, but it has no browser and no" \
           "display to show. Restart it with:  CLAUDE_BROWSER=1 ./run.sh"
    fi
    return 1
  fi
  if _alive "${c}"; then
    kv "noVNC already running" "${c}"
  else
    pass="$(_password "${c}")"
    # -storepasswd writes x11vnc's own hashed file; the plaintext never reaches
    # the container's argv, which `docker top` and in-container `ps` both expose.
    docker exec "${c}" sh -c \
      'mkdir -p "$HOME/.vnc" && x11vnc -storepasswd "$1" "$HOME/.vnc/passwd" >/dev/null 2>&1' \
      _ "${pass}" \
      || { fail "could not set the VNC password in ${c}"; return 1; }
    # -localhost so the RFB port never leaves the container; websockify is the
    # only door, and only 6080 is published. -forever survives a viewer closing.
    docker exec -d "${c}" sh -c \
      "x11vnc -display ${DISPLAY_IN_CONTAINER} -rfbauth \"\$HOME/.vnc/passwd\" \
         -rfbport ${VNC_PORT} -localhost -forever -shared -noxdamage -quiet \
         >/tmp/x11vnc.log 2>&1" \
      || { fail "could not start x11vnc in ${c}"; return 1; }
    docker exec -d "${c}" sh -c \
      "websockify --web=/usr/share/novnc ${NOVNC_PORT} 127.0.0.1:${VNC_PORT} \
         >/tmp/websockify.log 2>&1" \
      || { fail "could not start websockify in ${c}"; return 1; }
    # Both are backgrounded inside the container; confirm rather than assume.
    local tries=10
    while (( tries-- > 0 )); do
      _alive "${c}" && break
      sleep 0.3
    done
    if ! _alive "${c}"; then
      fail "noVNC did not stay up in ${c}" \
           "Check: docker exec ${c} cat /tmp/websockify.log /tmp/x11vnc.log"
      return 1
    fi
  fi
  url="$(_url)" || return 1
  ok "noVNC is up" "display ${DISPLAY_IN_CONTAINER}"
  kv "project" "$(_target_key)" "from $(_target_dir)"
  kv "container" "${c}"
  kv "url" "${url}"
  if ! _browser_running "${c}"; then
    say "the screen will be blank: no browser is open on that display yet"
    cont "Ask the session to open a page, or run in the container:"
    cont "  playwright-cli open <url>"
  fi
  _open_url "${url}"
}

_stop() {
  local c
  c="$(_resolve_container)" || return 1
  if ! _alive "${c}"; then
    say "no noVNC running in ${c}"
    return 0
  fi
  docker exec "${c}" pkill -f "${WEBSOCKIFY_PAT}" >/dev/null 2>&1 || true
  docker exec "${c}" pkill -x x11vnc >/dev/null 2>&1 || true
  ok "stopped noVNC" "${c} — the display and the browser keep running"
}

_status() {
  local c
  c="$(_resolve_container)" || return 1
  CONTAINER="${c}"
  kv "project" "$(_target_key)" "from $(_target_dir)"
  kv "container" "${c}"
  if _display_up "${c}"; then
    ok "X display running" "${DISPLAY_IN_CONTAINER}"
  elif _browser_enabled "${c}"; then
    warn "no X display on ${DISPLAY_IN_CONTAINER}" "The browser is enabled but Xvfb did not start."
  else
    warn "this session was started without CLAUDE_BROWSER=1" "It has no browser and no display."
    return 0
  fi
  # Between "the plumbing works" and "there is something to see" — the usual
  # reason for a blank VNC window.
  if _browser_running "${c}"; then ok "a browser is open on that display"
  else                             say "no browser open yet — the display is blank"
  fi
  if _alive "${c}"; then
    ok "noVNC running"
    kv "url" "$(_url)"
  else
    warn "noVNC NOT running" "Start it: cid vnc start"
  fi
}

# Internal: the running container names for this project, one per line, for the
# zsh completion to offer after --container. Exposed as a verb rather than having
# the completion call `docker` itself, so every docker invocation still lives in
# this file. Prints nothing and exits 0 when there are none or docker is absent:
# a completion must never error at the user.
_containers() {
  local dir key
  dir="$(cd "${TARGET_DIR}" 2>/dev/null && pwd)" || return 0
  key="$(project_key "${dir}")"
  command -v docker >/dev/null 2>&1 || return 0
  docker ps --filter "label=cid.project-key=${key}" --format '{{.Names}}' 2>/dev/null || true
}

_usage() {
  cat <<EOF
scripts/vnc.sh — watch the in-container browser over noVNC.

  start      start x11vnc + websockify, print and open the URL (default)
  stop       stop them; the display and the browser keep running
  status     is the display up, is noVNC up, what is the URL
  url        print the URL only

  -C <dir>   pick the project by directory (default: cwd)
  --container <name>   pick the container, when several run for one project

Runs on the host. The session must have been started with CLAUDE_BROWSER=1.
See docs/browser-vnc.md.
EOF
}

VERB=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--dir|--project) TARGET_DIR="${2:?-C needs a directory}"; shift 2 ;;
    --container)        CONTAINER="${2:?--container needs a name}"; shift 2 ;;
    -h|--help)          _usage; exit 0 ;;
    start|stop|status|url|_containers)
      if [[ -z "${VERB}" ]]; then VERB="$1"; shift
      else fail "unexpected argument: $1"; exit 2
      fi ;;
    *) fail "unknown argument: $1" "expected: start | stop | status | url"; exit 2 ;;
  esac
done

case "${VERB:-start}" in
  start)  _start ;;
  stop)   _stop ;;
  status) _status ;;
  url)    _url ;;
  # Internal, for completions/_cid. Underscore-prefixed like proxy/watch.sh's
  # _daemon: not a verb the user is meant to type, so _usage does not list it.
  _containers) _containers ;;
esac
