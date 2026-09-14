#!/usr/bin/env bash
#
# Guard: the in-container browser (see docs/browser-vnc.md) reserves a published
# port for noVNC at step 3c-e. A malformed port or bind address would otherwise
# surface as a raw `docker run` error after the image has already been built, and
# a port already claimed by CLAUDE_PORTS would bind twice.
#
# Fails closed on a bad value — an unusable published port is worth catching
# before the rebuild, not after. Warns on a collision, which Docker reports
# clearly enough on its own.
#
# No-op unless CLAUDE_BROWSER is on.
#
# Sourced by run.sh (not run standalone): reads CLAUDE_BROWSER, CLAUDE_VNC_PORT,
# CLAUDE_VNC_BIND and CLAUDE_PORTS from the caller.

case "${CLAUDE_BROWSER:-}" in
  1|true|yes|on|TRUE|YES|ON)
    # 0 is the DEFAULT and means "let Docker pick a free port" — a fixed one
    # collides across concurrent sessions (see docs/browser-vnc.md).
    _bg_port="${CLAUDE_VNC_PORT:-0}"
    if ! [[ "${_bg_port}" =~ ^[0-9]{1,5}$ ]] || [[ "${_bg_port}" -gt 65535 ]]; then
      fail "CLAUDE_VNC_PORT is not a port number: ${_bg_port}" \
           "Expected 1024-65535, or 0 (the default) to let Docker assign one."
      exit 1
    fi
    if [[ "${_bg_port}" != 0 && "${_bg_port}" -lt 1024 ]]; then
      fail "CLAUDE_VNC_PORT must be >= 1024: ${_bg_port}" \
           "The container cannot bind privileged ports."
      exit 1
    fi
    # Hostnames are not accepted by --publish; only an IP literal is.
    _bg_bind="${CLAUDE_VNC_BIND:-127.0.0.1}"
    if ! [[ "${_bg_bind}" =~ ^[0-9.]+$ || "${_bg_bind}" =~ ^[0-9a-fA-F:]+$ ]]; then
      fail "CLAUDE_VNC_BIND is not an IP address: ${_bg_bind}" \
           "Use 127.0.0.1 (the default) or 0.0.0.0 to expose it on the LAN."
      exit 1
    fi
    if [[ "${_bg_bind}" != 127.0.0.1 && "${_bg_bind}" != ::1 ]]; then
      warn "noVNC will be published on ${_bg_bind}, not just loopback." \
           "Anyone who can reach that address and guess the password gets full" \
           "keyboard and mouse control of the session's browser."
    fi
    # Only a PINNED port can collide, and it is a bind error at `docker run`,
    # after the build has already happened. 0 is assigned by Docker, so it cannot.
    if [[ "${_bg_port}" != 0 ]]; then
      case ",${CLAUDE_PORTS:-}," in
        *",${_bg_port},"*|*",${_bg_port}:"*|*":${_bg_port}:"*)
          warn "CLAUDE_PORTS already mentions host port ${_bg_port}, which noVNC also uses." \
               "Unset CLAUDE_VNC_PORT to let Docker assign a free one." ;;
      esac
      warn "CLAUDE_VNC_PORT is pinned to ${_bg_port}." \
           "Only one browser session can hold it: a second one dies with" \
           "\"port is already allocated\". Unset it unless you need a stable URL."
    fi
    unset _bg_port _bg_bind
    ;;
  *) ;;  # browser off: nothing to check
esac
