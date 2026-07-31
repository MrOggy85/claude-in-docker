#!/usr/bin/env bash
#
# Classify a project's .claude/settings.json / settings.local.json by
# CAPABILITY, so guards/project-settings.sh can prompt about the handful of
# entries that actually grant something instead of dumping a 50-rule file nobody
# reads. Also backs `cid settings`.
#
# Usage: scan-project-settings.sh [-p <project-dir>] [<file>...]
#   -p   project dir used to locate the settings files and the per-project
#        trusted-rules override (default: PWD)
#   files default to <project-dir>/.claude/settings.json and settings.local.json
#
# Output: one tab-separated record per line, sorted (so it hashes stably):
#   KEY     <key>    <why it is dangerous>   <file>   a settings key that runs a
#                                                     command or disables the prompt layer
#   KEYVAL  <path = value>  <parent key>     <file>   what that key is actually set to
#                                                     (the hook's command, the env var, ...)
#   RULE    <rule>   <capability granted>    <file>   a permissions.allow entry
#   OPAQUE  <what>   <why>                   <file>   could not be classified — caller must fail closed
#   OK      <count>  accepted allow rules    <file>   informational; never part of the risk digest
# Exit status is always 0 (barring usage errors); the verdict is the records.
#
# NO host dependencies beyond bash/awk/grep — jq, node and python are not
# guaranteed on a macOS host (the repo's jq use lives inside the image). Two
# independent layers, both biased to fail closed:
#   Layer 1  a literal scan of the raw bytes for every dangerous key token. A hit
#            inside a string value is a false positive; that is the safe direction.
#   Layer 2  an awk JSON walk that labels each string literal with its key path,
#            so only permissions.allow entries are classified. It may only ever
#            NARROW what layer 1 already looked at: an unexpected path, an
#            unbalanced container or a \u-escaped rule yields OPAQUE, never silence.
#
# The dangerous-key list mirrors docs/attack-vectors.md ("Project-Level Claude
# Settings") — update both together.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=paths.sh disable=SC1091
source "${SCRIPT_DIR}/paths.sh"

# --render turns records (on stdin) into the human-readable block both the guard
# and `cid settings` print. Kept here, next to the record format, so the two
# callers cannot drift apart. See _render at the bottom of this file.
if [[ "${1:-}" == "--render" ]]; then
  RENDER_ONLY=1
  shift
else
  RENDER_ONLY=0
fi

PROJECT_DIR="${PWD}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_DIR="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "scan-project-settings.sh: unknown flag $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
PROJECT_DIR="$(cd "${PROJECT_DIR}" 2>/dev/null && pwd)" || { echo "no such dir" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Rendering (--render)
# ---------------------------------------------------------------------------
#
# Records are grouped under the settings key they belong to, one block per key
# with a blank line between blocks, so it reads as "this key, and these are the
# values it carries" rather than as a flat list. permissions.allow rules get a
# synthetic block of their own for the same reason.
#
# Set SCAN_SINCE_RECORDS to a previously-approved record set and anything absent
# from it is marked, so a re-prompt does not make you re-read what you accepted.
if (( RENDER_ONLY )); then
  _NEW_MARK='   <-- new since your last approval'
  _since="${SCAN_SINCE_RECORDS:-}"

  # Colour only when the output is a terminal — same test usage.sh:76 uses, so a
  # piped or captured run (the guard's memo, the test suite) stays plain text.
  # The guard redirects this to its own stderr, which is still the terminal.
  #
  # Precedence, most explicit first: NO_COLOR (no-color.org) is the user saying
  # never, so it wins outright. CLICOLOR_FORCE is the user saying always, which
  # beats a merely INFERRED inability to render — TERM=dumb is an ambient default
  # on CI runners, not a considered choice, so it must not override an explicit
  # request. Absent both, fall back to what the terminal says it can do.
  if   [[ -n "${NO_COLOR:-}" ]];       then _use_color=0
  elif [[ -n "${CLICOLOR_FORCE:-}" ]]; then _use_color=1
  elif [[ "${TERM:-}" == "dumb" ]];    then _use_color=0
  elif [[ -t 1 ]];                     then _use_color=1
  else                                      _use_color=0
  fi
  if (( _use_color )); then
    _C_LABEL=$'\033[2m'      # [key] / the → bullets — structure, not content
    _C_KEY=$'\033[1;33m'     # the key name: this is the thing granting something
    _C_WHY=$'\033[2m'        # why it matters — read once, then skip
    _C_ITEM=$'\033[36m'      # the value / rule itself: what you actually vet
    _C_NEW=$'\033[1;31m'     # changed since you approved — look here first
    _C_OFF=$'\033[0m'
  else
    _C_LABEL='' _C_KEY='' _C_WHY='' _C_ITEM='' _C_NEW='' _C_OFF=''
  fi

  _mark() {  # <type> <subject>
    [[ -n "${_since}" ]] || return 0
    case "${_since}" in *"$1"$'\t'"$2"$'\t'*) return 0 ;; esac
    printf '%s%s%s' "${_C_NEW}" "${_NEW_MARK}" "${_C_OFF}"
  }

  _records=()
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] && _records+=("${_line}")
  done
  (( ${#_records[@]} == 0 )) && exit 0

  # <name> <why> then every child line, indented under it.
  _block() {  # <heading> <subheading>
    _blocks_printed=$(( ${_blocks_printed:-0} + 1 ))
    (( _blocks_printed > 1 )) && printf '\n'
    printf '  %s[key]%s  %s%s%s\n' "${_C_LABEL}" "${_C_OFF}" "${_C_KEY}" "$1" "${_C_OFF}"
    printf '         %s%s%s\n' "${_C_WHY}" "$2" "${_C_OFF}"
  }

  # One flagged item under the current block, plus its reason when it has one.
  _item() {  # <subject> <mark> [reason]
    printf '         %s→%s %s%s%s%s\n' \
      "${_C_LABEL}" "${_C_OFF}" "${_C_ITEM}" "$1" "${_C_OFF}" "$2"
    [[ -n "${3:-}" ]] && printf '             %s%s%s\n' "${_C_WHY}" "$3" "${_C_OFF}"
    return 0
  }

  # One pass per group; the record set is small enough that re-scanning it is
  # cheaper than the bookkeeping to avoid it (and works on bash 3.2).
  for _r in "${_records[@]}"; do
    IFS=$'\t' read -r _t _subject _reason _ <<< "${_r}"
    [[ "${_t}" == "KEY" ]] || continue
    _block "${_subject}" "${_reason}"
    for _c in "${_records[@]}"; do
      IFS=$'\t' read -r _ct _csubject _cparent _ <<< "${_c}"
      [[ "${_ct}" == "KEYVAL" && "${_cparent}" == "${_subject}" ]] || continue
      _item "${_csubject}" "$(_mark KEYVAL "${_csubject}")"
    done
  done

  _has() { local t="$1" r; for r in "${_records[@]}"; do [[ "${r}" == "${t}"$'\t'* ]] && return 0; done; return 1; }

  if _has RULE; then
    _block "permissions.allow" "tool calls auto-approved with no prompt"
    for _r in "${_records[@]}"; do
      IFS=$'\t' read -r _t _subject _reason _ <<< "${_r}"
      [[ "${_t}" == "RULE" ]] || continue
      _item "${_subject}" "$(_mark RULE "${_subject}")" "${_reason}"
    done
  fi

  if _has OPAQUE; then
    _block "unclassified" "could not be read, so it is not being vouched for"
    for _r in "${_records[@]}"; do
      IFS=$'\t' read -r _t _subject _reason _ <<< "${_r}"
      [[ "${_t}" == "OPAQUE" ]] || continue
      _item "${_subject}" "$(_mark OPAQUE "${_subject}")" "${_reason}"
    done
  fi
  exit 0
fi

FILES=("$@")
if (( ${#FILES[@]} == 0 )); then
  for _f in settings.json settings.local.json; do
    [[ -f "${PROJECT_DIR}/.claude/${_f}" ]] && FILES+=("${PROJECT_DIR}/.claude/${_f}")
  done
fi
(( ${#FILES[@]} == 0 )) && exit 0

# ---------------------------------------------------------------------------
# Key classification
# ---------------------------------------------------------------------------

# Keys that execute a command with no prompt, or that switch the prompt layer
# off. Any of these in an untrusted file is arbitrary code execution or the
# removal of the last line of defense — always worth a human look.
DANGEROUS_KEYS=(
  "hooks|registers commands Claude Code runs on tool use / session events"
  "statusLine|runs a command on every render, before you do anything"
  "apiKeyHelper|runs a command on an interval to mint auth headers"
  "awsCredentialExport|runs a command when AWS credentials are needed"
  "awsAuthRefresh|runs a command when AWS credentials expire"
  "gcpAuthRefresh|runs a command when GCP credentials expire"
  "otelHeadersHelper|runs a command on startup and on refresh"
  "fileSuggestion|runs a command when you type '@'"
  "defaultMode|can set bypassPermissions/acceptEdits — auto-approves tool calls"
  "enableAllProjectMcpServers|auto-launches every server command in .mcp.json"
  "enabledMcpjsonServers|auto-launches named .mcp.json server commands"
  "disableBypassPermissionsMode|touches the permission-mode policy"
  "additionalDirectories|widens file access beyond the mounted repo"
  "env|injects variables into every subprocess (NODE_OPTIONS, BASH_ENV, ...)"
  "sandbox|adjusts the sandbox/auto-approve policy"
  "enabledPlugins|loads plugin code, which can ship hooks and commands"
  "extraKnownMarketplaces|adds a plugin source"
  "mcpServers|defines server commands to launch"
  "plugins|loads plugin code"
)

# Keys with no execution or permission effect — accepted without a word.
# Anything absent from BOTH lists is reported OPAQUE so a newly-added Claude Code
# key prompts once (and is then remembered) rather than passing unexamined.
# shellcheck disable=SC2016  # '$schema' is a literal key name, not an expansion
INERT_KEYS=(
  '$schema' permissions model theme verbose outputStyle editorMode vimMode
  cleanupPeriodDays includeCoAuthoredBy preferredNotifChannel
  messageIdleNotifThresholdMs spinnerTipsEnabled alwaysThinkingEnabled
  autoCompactEnabled todoFeatureEnabled disableAllHooks autoUpdates
  autoUpdaterStatus forceLoginMethod forceLoginOrgUUID statusLineDisabled
)

# ---------------------------------------------------------------------------
# Bash command classification
# ---------------------------------------------------------------------------
#
# The question is never "is this rule malicious" — an attacker writes
# `Bash(python3 *)`, not `Bash(rm -rf /)`. It is "what capability does this rule
# hand over unattended": arbitrary execution, unbounded network, or a read/write
# reaching outside the mounted repo.

# Runs code of the caller's choosing no matter how the rest of the pattern is
# pinned: a shell, an evaluator, or a wrapper that takes a command as an argument.
ALWAYS_EXEC=" sh bash zsh ksh dash fish ash eval exec source . command env xargs
 nohup setsid script watch timeout sudo doas su chroot
 awk gawk mawk sed find expect
 npx pnpx bunx uvx dlx "

# Language runtimes: safe with only flags (`node --version`), arbitrary execution
# the moment a script or an inline program is in reach.
INTERPRETERS=" python python2 python3 node nodejs deno bun ruby perl php lua
 osascript Rscript java scala groovy tclsh tsx ts-node "

# Task runners: the subcommand decides. `go version` is inert, `go run` is not.
RUNNERS=" make npm pnpm yarn cargo go gradle mvn rake just uv pipx vite jest
 vitest bundle composer pip pip3 poetry gem "

# Runner subcommands that execute project-authored code (lifecycle scripts,
# build steps, tests) — i.e. whatever the untrusted repo put in package.json.
RUNNER_EXEC_SUBS=" run run-script exec test start ci install i add remove publish
 build dev x create init link unlink rebuild pack prepare serve watch generate "

# Flags whose argument IS a program. Only ever tested against INTERPRETERS —
# most of these letters mean something innocuous to other commands (curl -m is
# a timeout, curl -f is fail-fast).
INLINE_CODE_FLAGS=" -c -e -p -m --eval --exec --execute --command -Command "

# Reaches the network directly: an exfil sink, or a fetch-then-run pair.
NET_CMDS=" curl wget nc ncat netcat socat ssh scp sftp rsync telnet ftp openssl "

# Changes something outside the agent's own process: host-visible state, the
# repo's git configuration, or another container.
BOUNDARY_CMDS=" chmod chown chgrp mount umount docker podman kubectl systemctl
 launchctl crontab at defaults dd mkfs shred ln "

# Harmless with a concrete argument, unbounded with a wildcard one: a glob turns
# them into "read any file the container can read", which includes the mounted
# ~/.claude/.credentials.json.
READALL_CMDS=" cat head tail less more strings base64 xxd od hexdump cp mv tar
 zip unzip gzip gunzip jq yq "

# git subcommands that outlive the session or execute later. core.hooksPath set
# through `git config` (or `git -c`) plants a hook in the BIND-MOUNTED repo, so
# the payload runs on the HOST at your next commit.
GIT_BAD_SUBS=" config push remote submodule clone daemon filter-branch "

# Tool names Claude Code ships. An unrecognised tool cannot be reasoned about, so
# it is reported rather than assumed safe.
KNOWN_TOOLS=" Agent Task Bash BashOutput KillShell KillBash Edit MultiEdit Write
 NotebookEdit NotebookRead Read Glob Grep LS WebFetch WebSearch TodoWrite
 ExitPlanMode SlashCommand Skill ListMcpResources ReadMcpResource Artifact "

# Tools whose bare (parenthesis-less) form auto-approves every invocation.
UNBOUNDED_BARE=" Bash Write Edit MultiEdit NotebookEdit WebFetch Agent Task SlashCommand Skill "

# Path fragments that name a secret rather than source code.
SENSITIVE_PATHS=" .claude .ssh .aws .gnupg .npmrc .netrc .env .envrc credentials
 id_rsa id_ed25519 id_ecdsa .pem .p12 .kube .docker/config .git/config .git/hooks "

# Membership in one of the space-separated lists above. The lists are wrapped
# across lines for readability, so newlines are folded to spaces first — without
# that, every word at a line end would silently fail to match.
_in_list() {  # <list> <word>
  [[ -n "$2" ]] || return 1   # the padding below would otherwise match ""
  local l=" ${1//$'\n'/ } "
  case "${l}" in *" $2 "*) return 0 ;; esac
  return 1
}

# First word of a Bash pattern, with any directory part stripped
# (/usr/bin/curl -> curl). Claude Code accepts both "cmd args" and "cmd:*".
_first_word() {  # <body>
  local b="${1#"${1%%[![:space:]]*}"}" w
  w="${b%%[[:space:]]*}"; w="${w%%:*}"; w="${w##*/}"
  printf '%s' "${w}"
}

# Claude Code matches a Bash rule as a PREFIX, so what a wildcard can introduce
# depends on how much of the command line is pinned ahead of it. Everything
# before the first wildcard is fixed text and can be judged literally; the
# helpers below all reason about that prefix rather than about "has a glob".
_has_glob() { case "$1" in *'*'*|*'?'*) return 0 ;; esac; return 1; }

# The fixed part of a pattern: text up to the first wildcard, ':*' suffix dropped.
_fixed_part() {  # <body>
  local b="${1%:\*}"
  case "${b}" in
    *'*'*) b="${b%%\**}" ;;
  esac
  case "${b}" in
    *'?'*) b="${b%%\?*}" ;;
  esac
  printf '%s' "${b}"
}

# First pinned argument that is not a flag — the script, subcommand or URL the
# rule commits to. Empty when the wildcard starts right after the command.
_first_arg() {  # <fixed part>
  local -a t; read -r -a t <<< "$1"
  local i=1
  while (( i < ${#t[@]} )); do
    case "${t[$i]}" in -*) (( i += 1 )) ;; *) printf '%s' "${t[$i]}"; return ;; esac
  done
  printf '%s' ""
}

_has_inline_code_flag() {  # <fixed part>
  local -a t; read -r -a t <<< "$1"
  local i=1
  while (( i < ${#t[@]} )); do
    _in_list "${INLINE_CODE_FLAGS}" "${t[$i]}" && return 0
    (( i += 1 ))
  done
  return 1
}

# Is the destination of a network command pinned by the fixed part? A rule like
# `curl -s http://localhost:3000/*` can only ever reach localhost; `curl *` can
# reach anything. Requires a scheme and a non-empty authority before the wildcard.
_net_destination_pinned() {  # <fixed part>
  local rest="$1"
  case "${rest}" in
    *'://'*) rest="${rest#*://}" ;;
    *) return 1 ;;
  esac
  [[ -n "${rest}" && "${rest}" != /* ]]
}

# The git subcommand, skipping global flags. `-C <dir>` takes an argument; `-c`
# is itself the vector (git -c core.hooksPath=... == arbitrary execution).
_git_subcommand() {  # <body>
  local -a t; read -r -a t <<< "$1"
  local i=1
  while (( i < ${#t[@]} )); do
    case "${t[$i]}" in
      -c|--config-env) printf '%s' "-c"; return ;;
      -C|--git-dir|--work-tree|--namespace|--exec-path) (( i += 2 )) ;;
      -*) (( i += 1 )) ;;
      *) printf '%s' "${t[$i]}"; return ;;
    esac
  done
  printf '%s' ""
}

# Does the pattern reach outside the mounted repo? Claude Code path rules use
# "//abs/path" for absolute, "~/..." for home; a bare leading "/" is repo-root
# relative, so it is not by itself an escape.
_path_escapes() {  # <body>
  case "$1" in //*|~/*|'~'|*'/../'*|../*) return 0 ;; esac
  return 1
}

_path_sensitive() {  # <body>
  local frag
  for frag in ${SENSITIVE_PATHS}; do
    case "$1" in *"${frag}"*) return 0 ;; esac
  done
  return 1
}

# Classify one permissions.allow entry. Prints the capability it grants and
# returns 0 when the rule should be surfaced; returns 1 when it is routine.
_classify_rule() {  # <rule>
  local rule="$1" tool body sub w

  case "${rule}" in
    '*'|'*:*'|'') printf 'matches every tool call'; return 0 ;;
  esac

  if [[ "${rule}" == *'('* ]]; then
    tool="${rule%%(*}"
    body="${rule#*(}"; body="${body%)}"
  else
    tool="${rule}"; body=""
    if _in_list "${UNBOUNDED_BARE}" "${tool}"; then
      printf "bare '%s' — every invocation auto-approved" "${tool}"
      return 0
    fi
  fi

  case "${tool}" in
    mcp__*)
      case "${rule}" in
        *'*'*) printf 'wildcard MCP grant — covers tools the server may add later'; return 0 ;;
      esac
      return 1 ;;
  esac

  if ! _in_list "${KNOWN_TOOLS}" "${tool}"; then
    printf "unrecognised tool '%s' — cannot classify" "${tool}"
    return 0
  fi

  case "${tool}" in
    Bash)
      case "${body}" in
        ''|'*'|':*'|'*:*') printf 'unbounded shell'; return 0 ;;
      esac
      # A prefix rule spanning a shell operator or an expansion is not something
      # to reason about at a y/n prompt.
      # shellcheck disable=SC2016  # matching the literal characters, not expanding
      case "${body}" in
        *';'*|*'&&'*|*'||'*|*'|'*|*'`'*|*'$('*|*'${'*|*'>('*|*'<('*)
          printf 'contains a shell operator — prefix matching is not bounded'; return 0 ;;
      esac
      w="$(_first_word "${body}")"
      case "${w}" in *'*'*|*'?'*|*'['*) printf 'the command itself is a wildcard'; return 0 ;; esac

      local fixed arg1 open
      fixed="$(_fixed_part "${body}")"
      arg1="$(_first_arg "${fixed}")"
      _has_glob "${body}" && open=1 || open=0

      if _in_list "${ALWAYS_EXEC}" "${w}"; then
        printf "'%s' runs code of its caller's choosing — equivalent to Bash(*)" "${w}"; return 0
      fi
      if _in_list "${INTERPRETERS}" "${w}"; then
        if _has_inline_code_flag "${fixed}"; then
          printf "'%s' is given an inline program to execute" "${w}"; return 0
        fi
        # Pinned to flags only (`node --version`) is inert; anything that puts a
        # script — named or wildcard — in its hands is not.
        if [[ -n "${arg1}" ]]; then
          printf "'%s' runs the script '%s'" "${w}" "${arg1}"; return 0
        fi
        if (( open )); then
          printf "'%s' with unbounded arguments runs any script" "${w}"; return 0
        fi
        # No script, no wildcard: a fully pinned invocation (`node --version`)
        # is inert. The bare command on its own is an interactive interpreter.
        if [[ "${body}" != *[[:space:]]* ]]; then
          printf "'%s' on its own is an interactive interpreter" "${w}"; return 0
        fi
        return 1
      fi
      if _in_list "${RUNNERS}" "${w}"; then
        if [[ -z "${arg1}" ]]; then
          if (( open )); then printf "'%s' with an unbounded subcommand" "${w}"; return 0; fi
          return 1
        fi
        if _in_list "${RUNNER_EXEC_SUBS}" "${arg1}"; then
          printf "'%s %s' executes code the repo authored" "${w}" "${arg1}"; return 0
        fi
        return 1
      fi
      if _in_list "${NET_CMDS}" "${w}"; then
        if _net_destination_pinned "${fixed}"; then return 1; fi
        printf "'%s' with an unpinned destination reaches any host" "${w}"; return 0
      fi
      if [[ "${w}" == git ]]; then
        sub="$(_git_subcommand "${fixed}")"
        if [[ "${sub}" == "-c" ]]; then
          printf 'git -c can set core.hooksPath — the hook then runs on the HOST'; return 0
        fi
        if _in_list "${GIT_BAD_SUBS}" "${sub}"; then
          printf "'git %s' outlives the session or executes later" "${sub}"; return 0
        fi
        if [[ -z "${sub}" ]] && (( open )); then
          printf 'the git subcommand is unbounded'; return 0
        fi
        return 1
      fi
      if _in_list "${BOUNDARY_CMDS}" "${w}"; then
        printf "'%s' changes state outside this session" "${w}"; return 0
      fi
      if _in_list "${READALL_CMDS}" "${w}"; then
        if (( open )); then
          printf "'%s' with a wildcard path reads any file in the container" "${w}"; return 0
        fi
        if _path_escapes "${fixed}" || _path_sensitive "${fixed}"; then
          printf "'%s' targets a path outside the repo or a secret" "${w}"; return 0
        fi
      fi
      return 1 ;;

    Read|Glob|Grep|LS|NotebookRead)
      if _path_escapes "${body}"; then printf 'reads outside the mounted repo'; return 0; fi
      if _path_sensitive "${body}"; then printf 'reads a secrets path'; return 0; fi
      return 1 ;;

    Edit|MultiEdit|Write|NotebookEdit)
      if _path_escapes "${body}"; then printf 'writes outside the mounted repo'; return 0; fi
      if _path_sensitive "${body}"; then printf 'writes to a secrets path'; return 0; fi
      case "${body}" in '**'|'*') printf 'writes anywhere in the repo unattended'; return 0 ;; esac
      return 1 ;;

    WebFetch)
      case "${body}" in
        *'*'*) printf 'fetches any domain — an exfil sink'; return 0 ;;
      esac
      return 1 ;;

    SlashCommand|Skill|Agent|Task)
      printf "'%s' runs whatever the project defines under .claude/" "${tool}"; return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# JSON walk (layer 2)
# ---------------------------------------------------------------------------
#
# Emits, per line:  K<TAB><top-level key>            an object key at depth 1
#                   S<TAB><key path><TAB><string>    a string VALUE
#                   L<TAB><key path><TAB><literal>   a bare value (true/false/null/number)
#                   E<TAB><reason>                   structural problem; stop
# Strings keep their escapes verbatim; the caller decides what to do with them.
# Literals are captured too so that flipping `"disableBypassPermissionsMode":
# false` to `true` shows up as a change, not just as "the key is still there".
read -r -d '' JSON_WALK <<'AWK' || true
function keypath(   d, p) {
  p = ""
  for (d = 1; d <= depth; d++)
    if (type[d] == "obj") p = (p == "" ? key[d] : p "." key[d])
  return p
}
function fail(m) { printf "E\t%s\n", m; bad = 1 }
{
  n = length($0); i = 1
  while (i <= n) {
    c = substr($0, i, 1)
    if (c == "\"") {
      j = i + 1; raw = ""; closed = 0
      while (j <= n) {
        ch = substr($0, j, 1)
        if (ch == "\\") { raw = raw ch substr($0, j + 1, 1); j += 2; continue }
        if (ch == "\"") { closed = 1; break }
        raw = raw ch; j++
      }
      if (!closed) { fail("unterminated string"); exit }
      if (depth > 0 && type[depth] == "obj" && expectkey[depth]) {
        key[depth] = raw; expectkey[depth] = 0
        if (depth == 1) printf "K\t%s\n", raw
      } else {
        printf "S\t%s\t%s\n", keypath(), raw
      }
      i = j + 1; continue
    }
    if (c == "{") { depth++; type[depth] = "obj"; key[depth] = ""; expectkey[depth] = 1; i++; continue }
    if (c == "[") { depth++; type[depth] = "arr"; key[depth] = ""; expectkey[depth] = 0; i++; continue }
    if (c == "}") { if (depth < 1 || type[depth] != "obj") { fail("unbalanced '}'"); exit } depth--; i++; continue }
    if (c == "]") { if (depth < 1 || type[depth] != "arr") { fail("unbalanced ']'"); exit } depth--; i++; continue }
    if (c == ",") { if (depth >= 1 && type[depth] == "obj") expectkey[depth] = 1; i++; continue }
    # Outside a string, a bare run of these characters can only be a value
    # (JSON object keys are always quoted): true, false, null or a number.
    if (c ~ /[-0-9A-Za-z_.+]/) {
      j = i; lit = ""
      while (j <= n) {
        ch = substr($0, j, 1)
        if (ch !~ /[-0-9A-Za-z_.+]/) break
        lit = lit ch; j++
      }
      printf "L\t%s\t%s\n", keypath(), lit
      i = j; continue
    }
    i++
  }
}
END { if (!bad && depth != 0) printf "E\tunbalanced containers\n" }
AWK

# ---------------------------------------------------------------------------
# Trusted rules — the tunable half. Same baseline + per-project layout as
# allowed-domains.txt, but a rule contains spaces and globs, so only a line whose
# first non-blank character is '#' is a comment.
# ---------------------------------------------------------------------------
TRUSTED=$'\n'
_load_trusted() {
  local f line
  for f in "$(config_dir)/trusted-settings-rules.txt" \
           "$(projects_dir)/$(project_key "${PROJECT_DIR}")/trusted-settings-rules.txt"; do
    [[ -f "${f}" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "${line}" || "${line}" == '#'* ]] && continue
      TRUSTED+="${line}"$'\n'
    done < "${f}"
  done
}
_load_trusted

_is_trusted() { case "${TRUSTED}" in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

DANGEROUS_NAMES=" ${DANGEROUS_KEYS[*]%%|*} "

# Does any segment of a key path name a dangerous key? Checked segment-wise, not
# on the first one, so permissions.defaultMode is caught even though the path
# starts with the inert "permissions".
_under_dangerous_key() {  # <key path> — prints the key it matched
  local seg rest="$1"
  while [[ -n "${rest}" ]]; do
    seg="${rest%%.*}"
    if _in_list "${DANGEROUS_NAMES}" "${seg}"; then printf '%s' "${seg}"; return 0; fi
    [[ "${rest}" == *.* ]] || break
    rest="${rest#*.}"
  done
  return 1
}

RECORDS=()
emit() { RECORDS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

# The value of something nested under a dangerous key. Named KEYVAL so it sorts
# straight after its KEY record; the REASON column holds the parent key, which
# is what --render groups on. Two shapes carry no information and would only pad
# the prompt: the boilerplate "type": "command", and a hook timeout.
_emit_keyval() {  # <key path> <value> <dangerous key> <file>
  case "$1" in
    *.timeout) return 0 ;;
    *.type) [[ "$2" == "command" ]] && return 0 ;;
  esac
  emit KEYVAL "$1 = $2" "$3" "$4"
}

for FILE in "${FILES[@]}"; do
  [[ -f "${FILE}" ]] || { emit OPAQUE "${FILE}" "not readable" "${FILE}"; continue; }
  SHORT="${FILE#"${PROJECT_DIR}"/}"

  # -- layer 1: literal scan for the dangerous key tokens, parser-independent.
  for spec in "${DANGEROUS_KEYS[@]}"; do
    k="${spec%%|*}"; why="${spec#*|}"
    if grep -qE "\"${k}\"[[:space:]]*:" "${FILE}"; then
      emit KEY "${k}" "${why}" "${SHORT}"
    fi
  done

  # -- layer 2 runs REGARDLESS of what layer 1 found. Two reasons: the allow
  #    list still has to be classified (a hook does not make the rules below it
  #    irrelevant), and the VALUE records below put the configured value — the
  #    hook's actual command, the statusLine command, an env var — into the
  #    digest. Without them, approving "hooks: present" once would let the repo
  #    swap the command for anything else and never be asked again.
  accepted=0
  while IFS=$'\t' read -r tag a b; do
    case "${tag}" in
      E)
        emit OPAQUE "${SHORT}" "unparsable JSON (${a}) — cannot classify" "${SHORT}"
        ;;
      K)
        if ! _in_list "${DANGEROUS_NAMES}" "${a}" && ! _in_list " ${INERT_KEYS[*]} " "${a}"; then
          emit OPAQUE "${a}" "unrecognised settings key — not on the inert list" "${SHORT}"
        fi
        ;;
      L)
        if dkey="$(_under_dangerous_key "${a}")"; then
          _emit_keyval "${a}" "${b}" "${dkey}" "${SHORT}"
        elif [[ "${a}" == permissions.allow ]]; then
          emit OPAQUE "${a}" "non-string entry in permissions.allow — cannot classify" "${SHORT}"
        fi
        ;;
      S)
        case "${a}" in
          permissions.allow) ;;
          permissions.deny|permissions.ask) continue ;;   # only ever add friction
          *)
            if dkey="$(_under_dangerous_key "${a}")"; then
              # The thing that will actually run / be injected. Shown in full and
              # hashed, so editing it re-prompts.
              _emit_keyval "${a}" "${b}" "${dkey}" "${SHORT}"
              continue
            fi
            if _in_list " ${INERT_KEYS[*]} " "${a}"; then continue; fi
            emit OPAQUE "${a}" "string in an unexpected place — cannot classify" "${SHORT}"
            continue ;;
        esac
        # permissions.allow entry. A \u escape can spell "Bash" without the
        # letters ever appearing, so such a rule is reported rather than decoded.
        case "${b}" in
          *'\u'*) emit RULE "${b}" '\u-escaped rule — cannot be read literally' "${SHORT}"; continue ;;
        esac
        rule="${b//\\\"/\"}"; rule="${rule//\\\\/\\}"; rule="${rule//\\\//\/}"
        if _is_trusted "${rule}"; then accepted=$(( accepted + 1 )); continue; fi
        if reason="$(_classify_rule "${rule}")"; then
          emit RULE "${rule}" "${reason}" "${SHORT}"
        else
          accepted=$(( accepted + 1 ))
        fi
        ;;
    esac
  done < <(awk "${JSON_WALK}" "${FILE}")

  emit OK "${accepted}" "allow rules with no flagged capability" "${SHORT}"
done

# Sorted and de-duplicated: the guard hashes this output, so it must not depend
# on file order or on the same rule being listed twice.
(( ${#RECORDS[@]} == 0 )) || printf '%s\n' "${RECORDS[@]}" | LC_ALL=C sort -u
