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
# abort. Both prompts read from /dev/tty; when it is unavailable (non-interactive
# invocation, e.g. CI) the read fails, the prompt is treated as declined, and the
# run aborts with a non-zero status — secure by default.

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
      printf 'View the file(s)? [y/N] ' >&2
      read -r _reply 2>/dev/null </dev/tty || _reply=""
      case "${_reply}" in
        y|Y|yes|YES|Yes)
          for _f in "${_found_settings[@]}"; do
            echo "===== ${_f} =====" >&2
            cat "${_f}" >&2
            echo >&2
          done
          ;;
        *)
          echo "Aborted; remove/vet the file(s) or set CLAUDE_ALLOW_PROJECT_SETTINGS=1 to override." >&2
          exit 1
          ;;
      esac
      printf 'Proceed and run with these project settings? [y/N] ' >&2
      read -r _reply 2>/dev/null </dev/tty || _reply=""
      case "${_reply}" in
        y|Y|yes|YES|Yes) ;;  # proceed as if CLAUDE_ALLOW_PROJECT_SETTINGS=1
        *)
          echo "Aborted; remove/vet the file(s) or set CLAUDE_ALLOW_PROJECT_SETTINGS=1 to override." >&2
          exit 1
          ;;
      esac
    fi
    ;;
esac
