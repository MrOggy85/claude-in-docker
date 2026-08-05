#!/usr/bin/env bash
#
# Shared terminal palette and the semantic emitters every run-time message goes
# through, sourced (not executed) by run.sh, the guards it sources, the scripts
# it subprocesses, proxy/up.sh, sync-volume.sh and usage.sh. One place decides
# whether to colour and one place owns what each severity looks like, so the
# prefixes stay consistent and NO_COLOR is honoured everywhere.
#
# The grammar:
#   >> <label>: <value>  (<hint>)   progress: name a thing, optionally say how
#                                   to inspect it
#   WARNING: <headline>             non-fatal, the run continues
#     <continuation>
#   ERROR: <headline>               fatal; the CALLER exits, not this file
#     <continuation>
#
# Palette semantics: dim for structure (the ">>" marker, parenthetical hints),
# plain for the label, cyan for the value being named (volume, path, image,
# port, host), green for a confirmation, yellow for WARNING, bold red for ERROR.
#
# STREAMS. The emitters do not share one fd:
#   say/kv/ok   the "info" fd declared by color_init (1 by default; the scripts
#               whose STDOUT carries `docker run` tokens pass 2)
#   warn/fail   always fd 2
# Colour is therefore decided twice, once per stream: a script may have its info
# fd redirected while stderr is still a terminal, or the reverse.
#
# No side effects beyond defining the palette empty, so it is safe to source from
# a script that manages its own shell options; colour stays off until color_init
# runs. Uses bash builtins only — one caller (the mcp-bearer guard) must keep
# working under a deliberately minimal PATH.
#
# init-firewall.sh does NOT source this file and carries a small copy of the
# palette instead: it runs as root inside the image (which COPYs only its own
# files), and sudo strips the very environment the precedence below reads. Keep
# the two in sync.

# --- info-stream palette (the fd passed to color_init) ---
C_DIM='' C_VALUE='' C_OK='' C_OFF=''
# C_KEY / C_ALERT are read only by scripts/scan-project-settings.sh --render.
C_KEY='' C_ALERT=''
# --- error-stream palette (always fd 2), read only by warn()/fail() ---
C_WARN='' C_FAIL='' C_EOFF=''
# Where say/kv/ok write. 1 or 2.
_C_INFO_FD=1

# Can the given fd render colour?
#
# Precedence, most explicit first: NO_COLOR (no-color.org) is the user saying
# never, so it wins outright. CLICOLOR_FORCE is the user saying always, which
# beats a merely INFERRED inability to render — TERM=dumb is an ambient default
# on CI runners, not a considered choice, so it must not override an explicit
# request. Absent both, fall back to what the stream says it is.
_color_ok() {  # <fd>
  if   [[ -n "${NO_COLOR:-}" ]];       then return 1
  elif [[ -n "${CLICOLOR_FORCE:-}" ]]; then return 0
  elif [[ "${TERM:-}" == "dumb" ]];    then return 1
  elif [[ -t "$1" ]];                  then return 0
  fi
  return 1
}

# Decide the palette and remember which fd the informational emitters write to.
# Call once near the top of a script, after `set -euo pipefail`.
color_init() {  # [info-fd] (default 1)
  _C_INFO_FD="${1:-1}"
  C_DIM='' C_VALUE='' C_OK='' C_OFF='' C_KEY='' C_ALERT=''
  C_WARN='' C_FAIL='' C_EOFF=''
  if _color_ok "${_C_INFO_FD}"; then
    C_DIM=$'\033[2m' C_VALUE=$'\033[36m' C_OK=$'\033[32m' C_OFF=$'\033[0m'
    # shellcheck disable=SC2034  # both are read by scan-project-settings.sh --render
    C_KEY=$'\033[1;33m' C_ALERT=$'\033[1;31m'
  fi
  if _color_ok 2; then
    C_WARN=$'\033[33m' C_FAIL=$'\033[1;31m' C_EOFF=$'\033[0m'
  fi
}

# One line on the info stream. A branch rather than a dynamic `>&$fd`: only 1 and
# 2 are ever used, and this stays portable to macOS bash 3.2.
_info() {  # <line>
  if [[ "${_C_INFO_FD}" == 2 ]]; then printf '%s\n' "$1" >&2
  else                                printf '%s\n' "$1"; fi
}

# ">> <text>" — progress with nothing worth singling out.
say() {  # <text>
  _info "${C_DIM}>>${C_OFF} $1"
}

# ">> <label>: <value>  (<hint>)" — the workhorse. Name a thing (volume, path,
# image, port, host) and optionally say how to look at it. The parentheses round
# the hint live here so every hint looks the same.
kv() {  # <label> <value> [hint]
  local line="${C_DIM}>>${C_OFF} $1: ${C_VALUE}$2${C_OFF}"
  [[ -n "${3:-}" ]] && line+="  ${C_DIM}($3)${C_OFF}"
  _info "${line}"
}

# ">> <text>  (<hint>)" in green — a check that passed, not just progress.
ok() {  # <text> [hint]
  local line="${C_DIM}>>${C_OFF} ${C_OK}$1${C_OFF}"
  [[ -n "${2:-}" ]] && line+="  ${C_DIM}($2)${C_OFF}"
  _info "${line}"
}

# "WARNING: <headline>" plus one indented line per extra argument. Always stderr:
# the run continues, so this must never land in a captured stdout.
warn() {  # <headline> [continuation...]
  printf '%s %s\n' "${C_WARN}WARNING:${C_EOFF}" "$1" >&2
  shift
  if (( $# > 0 )); then cont "$@"; fi
  return 0
}

# "ERROR: <headline>" plus continuations, on stderr. Does NOT exit: the caller
# does, so the control flow stays visible at the call site (the guards are
# sourced precisely so their own `exit` ends the whole run, and an exit here
# would be a no-op from inside a $(...) subshell).
fail() {  # <headline> [continuation...]
  printf '%s %s\n' "${C_FAIL}ERROR:${C_EOFF}" "$1" >&2
  shift
  if (( $# > 0 )); then cont "$@"; fi
  return 0
}

# Continuation lines under a warn/fail: two spaces of indent each, text printed
# verbatim, so a deeper level is just leading spaces in the argument. With no
# arguments, one blank line (block separator).
cont() {  # [text...]
  if (( $# == 0 )); then printf '\n' >&2; return 0; fi
  local l
  for l in "$@"; do printf '  %s\n' "$l" >&2; done
}
