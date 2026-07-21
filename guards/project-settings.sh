#!/usr/bin/env bash
#
# Guard: a project-level .claude/settings.json (or the .claude/settings.local.json
# override) can register hooks that Claude Code runs inside the container —
# arbitrary code execution from an untrusted repo. When one is present, warn and
# let the user view the file(s) and decide whether to proceed; set
# CLAUDE_ALLOW_PROJECT_SETTINGS=1 to skip this flow and opt in unconditionally.
# See docs/attack-vectors.md.
#
# Sourced by run.sh (not run standalone): reads PROJECT_DIR and
# CLAUDE_ALLOW_PROJECT_SETTINGS from the caller and `exit`s the whole run on
# abort. Both prompts read a single keypress from /dev/tty (no Enter needed):
# y/Y proceeds, n/N declines, anything else re-prompts. When /dev/tty is
# unavailable (non-interactive invocation, e.g. CI) the read fails and the
# prompt is treated as declined, aborting the run — secure by default.

# Prompt for a single-key y/n answer; re-prompt on any other key. Returns 0 on
# y/Y, 1 on n/N or when no tty is available (declined).
_ask_yn() {
  local _prompt="$1" _key
  while true; do
    printf '%s' "${_prompt}" >&2
    if ! IFS= read -rsn1 _key 2>/dev/null </dev/tty; then
      echo >&2
      return 1
    fi
    echo >&2  # newline after the silent keypress
    case "${_key}" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *) ;;  # any other key: re-prompt
    esac
  done
}

case "${CLAUDE_ALLOW_PROJECT_SETTINGS:-}" in
  1|true|yes|on|TRUE|YES|ON) ;;  # opted in — skip the guard
  *)
    _found_settings=()
    for _settings in settings.json settings.local.json; do
      if [[ -f "${PROJECT_DIR}/.claude/${_settings}" ]]; then
        _found_settings+=("${PROJECT_DIR}/.claude/${_settings}")
      fi
    done
    if (( ${#_found_settings[@]} > 0 )); then
      echo "WARNING: project-level Claude settings detected:" >&2
      for _f in "${_found_settings[@]}"; do
        echo "  - ${_f}" >&2
      done
      echo "  These can register hooks that run arbitrary commands in the container." >&2
      echo "  See docs/attack-vectors.md." >&2
      if _ask_yn 'View the file(s)? [y/n] '; then
        for _f in "${_found_settings[@]}"; do
          echo "===== ${_f} =====" >&2
          cat "${_f}" >&2
          echo >&2
        done
      else
        echo "Aborted; remove/vet the file(s) or set CLAUDE_ALLOW_PROJECT_SETTINGS=1 to override." >&2
        exit 1
      fi
      if ! _ask_yn 'Proceed and run with these project settings? [y/n] '; then
        echo "Aborted; remove/vet the file(s) or set CLAUDE_ALLOW_PROJECT_SETTINGS=1 to override." >&2
        exit 1
      fi
    fi
    ;;
esac
