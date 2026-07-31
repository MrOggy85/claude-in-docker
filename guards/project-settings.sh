#!/usr/bin/env bash
#
# Guard: a project-level .claude/settings.json (or the gitignored
# .claude/settings.local.json override) is loaded by Claude Code inside the
# container, and several of its keys run a command with no prompt — arbitrary
# code execution from an untrusted repo. See docs/attack-vectors.md.
#
# The guard used to trip on the mere PRESENCE of such a file and dump the whole
# thing. Since Claude Code rewrites settings.local.json every session as you
# approve permissions, that meant a 50-rule wall of text and a reflex "y" at
# every start — a prompt that conveys nothing defends nothing. So instead:
#
#   1. scripts/scan-project-settings.sh classifies the file by CAPABILITY and
#      reports only what grants something (see that script for the rules).
#   2. Nothing flagged -> one summary line, no prompt.
#   3. Something flagged -> a sha256 of just those records is the "risk digest".
#      It is compared against the digest you last approved, kept OUTSIDE the
#      project (per-project config dir) so a repo cannot forge its own approval.
#      Unchanged -> no prompt. Changed -> prompt showing only the flagged items,
#      marking the ones that are new since that approval.
#
# Escape hatches: CLAUDE_ALLOW_PROJECT_SETTINGS=1 skips the guard entirely;
# CLAUDE_PROJECT_SETTINGS_STRICT=1 restores the old view-the-whole-file flow and
# never records an approval.
#
# Sourced by run.sh (not run standalone): reads PROJECT_DIR, SCRIPT_DIR,
# CLAUDE_ALLOW_PROJECT_SETTINGS and CLAUDE_PROJECT_SETTINGS_STRICT from the
# caller and `exit`s the whole run on abort. Prompts read a single keypress from
# /dev/tty (no Enter needed): y/Y proceeds, n/N declines, anything else
# re-prompts. When /dev/tty is unavailable (non-interactive invocation, e.g. CI)
# the read fails and the prompt is treated as declined, aborting the run —
# secure by default.

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

# Full sha256 of a string. Not path_hash() from scripts/paths.sh: that truncates
# to 10 hex chars, and this digest is what an untrusted repo would have to
# collide with to get its own settings silently re-approved. sha256_ (same file)
# is what handles sha256sum-vs-shasum.
_ps_sha() {  # <string>
  printf '%s' "$1" | sha256_ - | cut -d' ' -f1
}

_ps_abort() {
  echo "Aborted; remove/vet the file(s), trust individual rules with" >&2
  echo "  cid settings trust '<rule>'" >&2
  echo "or set CLAUDE_ALLOW_PROJECT_SETTINGS=1 to override." >&2
  exit 1
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
      case "${CLAUDE_PROJECT_SETTINGS_STRICT:-}" in
        1|true|yes|on|TRUE|YES|ON) _ps_strict=1 ;;
        *) _ps_strict=0 ;;
      esac

      if (( _ps_strict )); then
        # Audit path: the whole file, every time, no memo.
        echo "WARNING: project-level Claude settings detected (STRICT mode):" >&2
        for _f in "${_found_settings[@]}"; do echo "  - ${_f}" >&2; done
        if _ask_yn 'View the file(s)? [y/n] '; then
          for _f in "${_found_settings[@]}"; do
            echo "===== ${_f} =====" >&2
            cat "${_f}" >&2
            echo >&2
          done
        else
          _ps_abort
        fi
        _ask_yn 'Proceed and run with these project settings? [y/n] ' || _ps_abort
      else
        # Records are TYPE<TAB>SUBJECT<TAB>REASON<TAB>FILE, sorted. OK records
        # are informational and deliberately excluded from the digest, so that
        # Claude Code adding benign allow rules does not re-prompt.
        _ps_scan="$("${SCRIPT_DIR}/scripts/scan-project-settings.sh" -p "${PROJECT_DIR}" "${_found_settings[@]}")"
        _ps_flagged="$(printf '%s\n' "${_ps_scan}" | grep -v $'^OK\t' || true)"
        _ps_summary="$(printf '%s\n' "${_ps_scan}" | awk -F'\t' '$1=="OK" {n+=$2} END {print n+0}')"

        if [[ -z "${_ps_flagged}" ]]; then
          echo ">> project settings: ${#_found_settings[@]} file(s), ${_ps_summary} allow rule(s), nothing flagged (cid settings)"
        else
          _ps_memo="$(projects_dir)/$(project_key "${PROJECT_DIR}")/approved-project-settings"
          # Memo layout: the digest on line 1, the records it covers below it —
          # the records are only there so a later prompt can point at what is new.
          _ps_digest="$(_ps_sha "${_ps_flagged}")"
          _ps_prev="" _ps_prev_records=""
          if [[ -f "${_ps_memo}" ]]; then
            _ps_prev="$(sed -n '1p' "${_ps_memo}")"
            _ps_prev_records="$(sed -n '2,$p' "${_ps_memo}")"
          fi

          if [[ "${_ps_digest}" == "${_ps_prev}" ]]; then
            echo ">> project settings: risk profile unchanged since you approved it — accepted"
          else
            echo "WARNING: project-level Claude settings grant the following:" >&2
            for _f in "${_found_settings[@]}"; do echo "  file: ${_f}" >&2; done
            echo >&2
            # Grouped by settings key; SCAN_SINCE_RECORDS makes the renderer mark
            # what is new relative to the approval being superseded.
            SCAN_SINCE_RECORDS="${_ps_prev_records}" \
              "${SCRIPT_DIR}/scripts/scan-project-settings.sh" --render >&2 <<< "${_ps_flagged}"
            echo >&2
            echo "  ${_ps_summary} further allow rule(s) grant nothing and are not shown." >&2
            # A [key] means a command runs with no prompt at all, so the value
            # shown above is worth reading in its original context before saying yes.
            if printf '%s\n' "${_ps_flagged}" | grep -q $'^KEY\t'; then
              for _f in "${_found_settings[@]}"; do
                echo "  Read it in full:  cat '${_f}'" >&2
              done
            fi
            echo "  Full picture: cid settings   |   silence one rule: cid settings trust '<rule>'" >&2
            echo "  See docs/attack-vectors.md." >&2
            _ask_yn 'Proceed and run with these project settings? [y/n] ' || _ps_abort
            mkdir -p "$(dirname "${_ps_memo}")"
            { printf '%s\n' "${_ps_digest}"; printf '%s\n' "${_ps_flagged}"; } > "${_ps_memo}"
            echo ">> approval recorded: ${_ps_memo} (you will not be asked again until this changes)"
          fi
        fi
      fi
    fi

    unset _found_settings _settings _f _ps_strict _ps_scan _ps_flagged \
          _ps_summary _ps_memo _ps_digest _ps_prev _ps_prev_records
    ;;
esac
