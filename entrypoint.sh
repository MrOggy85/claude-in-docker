#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (from CLAUDE_PORTS), CONTAINER_HOST_OUTBOUND_PORTS (from
# SOUND_PORT + CLAUDE_HOST_OUTBOUND_PORTS, merged by run.sh), and EGRESS_PROXY_HOST
# are passed as arguments because sudo resets the environment. CONTAINER_OPEN_PORTS
# is empty when no ports are published. EGRESS_PROXY_HOST is set by run.sh to the
# Squid host ("squid") so init-firewall.sh locks egress to the proxy — see that script.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}" "${CONTAINER_HOST_OUTBOUND_PORTS:-}" "${EGRESS_PROXY_HOST:-}"

# In-container browser (CLAUDE_BROWSER_ON=1, set by run.sh). Chromium inherits
# DISPLAY at launch, so the X server cannot be started lazily by `cid vnc` later
# — it has to exist before the session does. x11vnc and websockify DO start
# lazily, from the host; this is only the display they attach to.
#
# Never fatal: a session is worth more than a browser, and `set -e` is on, so
# each step is guarded. sandbox-info reports the display as unavailable if this
# failed. See docs/browser-vnc.md.
if [ "${CLAUDE_BROWSER_ON:-}" = "1" ]; then
  DISPLAY="${DISPLAY:-:99}"
  export DISPLAY
  # Xvfb will not create its own socket directory unless it is root:
  #   _XSERVTransmkdir: ERROR: euid != 0, directory /tmp/.X11-unix will not be created
  # and the image's /tmp is empty. We run as the host UID, but /tmp is 1777, so
  # creating it here works. 1777 on the socket dir is what X expects; the chmod
  # is best-effort because a pre-existing dir may belong to someone else.
  mkdir -p /tmp/.X11-unix 2>/dev/null || true
  chmod 1777 /tmp/.X11-unix 2>/dev/null || true
  if [ ! -e "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    Xvfb "${DISPLAY}" -screen 0 "${CLAUDE_BROWSER_GEOMETRY:-1280x800x24}" -nolisten tcp &
    # Wait for the socket rather than sleeping blind; ~2s is ample for Xvfb.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ] && break
      sleep 0.2
    done
  fi
  if [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    # Without a window manager Chromium's window cannot be moved or resized, and
    # some dialogs never get focus.
    openbox >/dev/null 2>&1 &
  else
    echo "WARNING: Xvfb did not come up on ${DISPLAY} — the browser will not start" >&2
  fi
  # Upstream's own skills. Run from $HOME, NOT the workdir: the installer writes
  # to ./.claude/skills relative to the current directory, so from the default
  # WORKDIR it drops them inside the user's project — untracked files in a repo
  # we were only asked to mount. $HOME/.claude is the session volume, so they
  # persist there instead and follow the project rather than littering it.
  #
  # Not baked into the image: the volume mount would shadow anything put there.
  # Our own sentinel, not a guess at the directory upstream writes, so a rename
  # there cannot turn this into a no-op or a re-run on every start.
  #
  # BACKGROUNDED, and its exit status ignored, because the installer does its
  # work in about 0.2s and then NEVER EXITS. Run in the foreground it holds the
  # session at "[firewall] ready" for the whole timeout, on every start; and
  # `timeout` then reports 124 for a run that fully succeeded, so believing the
  # status means the sentinel is never written and it repeats forever. Both of
  # those were live bugs, not hypotheticals.
  #
  # The installed directory is therefore the only honest success signal. If
  # upstream renames it this degrades to re-running each start — wasteful, not
  # broken. Nothing here writes to the terminal: by the time it finishes, claude
  # owns the TTY and a stray line would corrupt the display. The log is where to
  # look, and docs/browser-vnc.md says so.
  if [ ! -f "${HOME}/.claude/.playwright-skills-installed" ]; then
    _pw_log="${HOME}/.claude/playwright-skills-install.log"
    (
      cd "${HOME}" || exit 0
      timeout 60 playwright-cli install --skills >"${_pw_log}" 2>&1 </dev/null
      if [ -d "${HOME}/.claude/skills/playwright-cli" ]; then
        touch "${HOME}/.claude/.playwright-skills-installed" 2>/dev/null || true
      fi
    ) &
  fi
fi

exec "$@"
