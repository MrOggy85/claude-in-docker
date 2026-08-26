#!/usr/bin/env bash
#
# Host desktop notifications, sourced (not executed) by proxy/watch.sh. One place
# decides how an alert reaches the user and what each severity looks like, the
# same way scripts/colors.sh owns terminal output.
#
# Two severities:
#   info    something worth knowing — a banner that auto-dismisses
#   alert   something to act on    — a dialog/notification that does NOT
#           auto-dismiss, so it survives a glance at another window
#
# Backends, most explicit first: CLAUDE_NOTIFY_CMD, then macOS `osascript`, then
# `notify-send` (libnotify), then log-only. Whichever wins, EVERY alert is also
# appended to the log file passed to notify_init — that is the audit trail, and
# it is the only thing that works over ssh with no desktop session at all.
#
# SECURITY. The text passed in carries a hostname taken from the proxy access
# log, i.e. a string an attacker inside a container can choose. It is
# interpolated into an AppleScript program, so notify() strips everything outside
# a conservative charset before any backend sees it. Do not move that
# sanitisation to the callers; it belongs at this boundary.

# Set by notify_init.
NOTIFY_BACKEND=''
NOTIFY_LOG=''

# Pick the backend once and name the log. Call before the first notify().
notify_init() {  # <log-path>
  NOTIFY_LOG="$1"
  if   [[ -n "${CLAUDE_NOTIFY_CMD:-}" ]];        then NOTIFY_BACKEND='custom'
  elif command -v osascript >/dev/null 2>&1;     then NOTIFY_BACKEND='osascript'
  elif command -v notify-send >/dev/null 2>&1;   then NOTIFY_BACKEND='notify-send'
  else                                                NOTIFY_BACKEND='log'
  fi
  mkdir -p "$(dirname "${NOTIFY_LOG}")" 2>/dev/null || true
}

# Drop every character that is not plainly safe to interpolate, and cap each
# line. Quotes, backslashes, `$` and backticks all go — those are what would let
# a hostname escape the AppleScript string literal. Newline and space survive so
# a multi-host body still reads as a list.
_NOTIFY_NL=$'\n'
_notify_clean() {  # <text>
  printf '%s' "$1" | tr -cd "A-Za-z0-9 ${_NOTIFY_NL}._:,()/@=+#-" | cut -c1-200
}

# Emit one notification. Never fails the caller: a missing notifier or a rejected
# AppleScript must not take down the watcher that called it.
notify() {  # <info|alert> <title> <body>
  local urgency="$1" title body
  title="$(_notify_clean "$2")"
  body="$(_notify_clean "$3")"

  # Audit trail first, so an alert is recorded even if the backend swallows it.
  if [[ -n "${NOTIFY_LOG}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${urgency}" \
      "${title}" "$(printf '%s' "${body}" | tr '\n' ';')" >> "${NOTIFY_LOG}" 2>/dev/null || true
  fi

  case "${NOTIFY_BACKEND}" in
    custom)
      # Word-split so CLAUDE_NOTIFY_CMD may carry its own flags. Foreground: a
      # user hook is theirs to keep fast.
      local -a cmd=()
      read -r -a cmd <<< "${CLAUDE_NOTIFY_CMD}"
      "${cmd[@]}" "${urgency}" "${title}" "${body}" >/dev/null 2>&1 || true
      ;;
    osascript)
      if [[ "${urgency}" == alert ]]; then
        # A dialog blocks until it is clicked, so it must not run in the
        # watcher's own process. `giving up after` keeps an unattended machine
        # from collecting one osascript per alert forever.
        osascript -e "display dialog \"${body}\" with title \"${title}\" \
          with icon caution buttons {\"OK\"} default button \"OK\" \
          giving up after 900" >/dev/null 2>&1 &
      else
        osascript -e "display notification \"${body}\" with title \"${title}\"" \
          >/dev/null 2>&1 || true
      fi
      ;;
    notify-send)
      local level=normal
      # critical is the one urgency GNOME/KDE never auto-dismisses.
      [[ "${urgency}" == alert ]] && level=critical
      notify-send -a claude-in-docker -u "${level}" "${title}" "${body}" \
        >/dev/null 2>&1 || true
      ;;
    log)
      # No desktop notifier on this host. The log line above is the whole alert;
      # say so once rather than per event.
      if [[ -z "${_NOTIFY_WARNED:-}" ]]; then
        _NOTIFY_WARNED=1
        printf 'notify: no osascript or notify-send — alerts only go to %s\n' \
          "${NOTIFY_LOG}" >&2
      fi
      ;;
  esac
  return 0
}
