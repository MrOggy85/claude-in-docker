#!/bin/sh
# Squid external_acl helper, in four modes over one grammar:
#
#   (no argument)  may this project make this request?  -> allowed-domains.txt
#   --skip-decryption       should this host be tunnelled WITHOUT decryption, instead of
#                  bumped?                            -> skip-decryption.txt
#   --explain      which entry covers this host, from which list, exact or
#                  wildcard? Squid never calls this one: proxy/watch.sh does, on
#                  the HOST, to say WHY a first-time host was allowed. It decides
#                  nothing — it reports, host-level, over the same match_in_file,
#                  so the grammar keeps exactly one implementation. Its output
#                  can never begin with "OK", so a squid.conf typo naming it
#                  denies rather than opens. See docs/egress-alerts.md.
#   --muted        is this host on the mute list, i.e. one the user has told the
#                  watcher to stop notifying about? Host-side only too, and it
#                  changes no decision either — a muted host is still denied,
#                  just silently. -> muted-hosts.txt. See docs/egress-alerts.md.
#
# Per line on stdin Squid sends "<project-key> <method> <host> <path> -" (the
# format is "%LOGIN %METHOD %DST %PATH"; Squid substitutes "-" for an empty value
# and appends a trailing "-"). Take the first four fields and print "OK"/"ERR"
# per line, in order. OK = the request is granted by the shared baseline list OR
# by the project's own list — same matching, key guard and fail-closed behaviour
# in both modes, only the two filenames differ. Both external_acl_type lines in
# squid.conf point here; see docs/tls-inspection.md for what splicing means.
#
# A login of "<project-key>-browser" is the in-container browser rather than the
# agent, and adds two more files to the same OR: the browser baseline and the
# project's browser-domains.txt. Strictly additive, so the agent's reach is
# always a subset of the browser's. See docs/browser-vnc.md.
#
# POSIX sh, no bashisms: the ubuntu/squid base isn't guaranteed to ship bash, and
# `#!/usr/bin/env bash` crash-loops the helper (exec ENOENT) at 100% CPU when it's
# absent. auth-ok.sh is /bin/sh for the same reason. --explain also runs on the
# HOST (macOS, Linux), so the constraint binds there too. See docs/egress-proxy.md.
set -u
export LC_ALL=C   # locale-stable [a-z0-9] / [:space:] ranges

# Overridable so the helper can be unit-tested against fixtures (see
# test/ext-allowlist.bats). Squid never sets these; it uses the defaults.
BASELINE="${BASELINE:-/etc/squid/baseline-domains.txt}"
BROWSER_BASELINE="${BROWSER_BASELINE:-/etc/squid/baseline-browser-domains.txt}"
SKIP_DECRYPTION_BASELINE="${SKIP_DECRYPTION_BASELINE:-/etc/squid/baseline-skip-decryption.txt}"
PROJECTS_DIR="${PROJECTS_DIR:-/etc/squid/projects}"
# No /etc/squid default: --muted runs only on the host, where proxy/watch.sh sets
# this. Unset means nothing is muted, which fails toward alerting.
MUTED_BASELINE="${MUTED_BASELINE:-/nonexistent}"

# Written by match_in_file on a match, read only by --explain: the entry that
# matched, and its host token alone (leading '.' iff it is a wildcard). Cleared
# at the top of every match_in_file call, so a failed arm of the four-file OR
# can never leave a stale value for the arm that follows it.
MATCH_ENTRY=''
MATCH_EHOST=''

# Mode: which question this process answers. An unknown argument is a squid.conf
# typo — refuse rather than silently answering with the allowlist (which, in
# skip-decryption mode, would mean "never decrypt anything").
MODE='allow'
case "${1:-}" in
  '') ;;
  --skip-decryption) MODE='skipdecrypt' ;;
  --explain) MODE='explain' ;;
  --muted) MODE='muted' ;;
  *)
    echo "ext-allowlist.sh: unknown mode '$1' (expected --skip-decryption, --explain, --muted or no argument)" >&2
    exit 2
    ;;
esac

# Does <entry-host> cover the requested host? Exact, or a leading '.'
# (".example.com") matching the apex and any subdomain on a label boundary.
host_matches() {  # <entry-host>
  case "$1" in
    .*) case "$REQ_HOST" in "${1#.}"|*"$1") return 0 ;; esac ;;
    *)  [ "$REQ_HOST" = "$1" ] && return 0 ;;
  esac
  return 1
}

# Reduce Squid's %PATH to what this request will actually hit at the origin, into
# REQ_PATH — or clear REQ_PATH_OK, which makes it match no path rule at all.
# Query string and fragment go: a path rule scopes the resource, not its
# parameters. The percent-escapes that are significant to path structure are then
# decoded ONCE, exactly as an origin decodes them, so "/v1/%2e%2e/admin" cannot
# slip past a "/v1" rule by spelling its traversal in hex. Whatever still holds a
# ".." segment or a backslash is unsafe and matches nothing. (Squid may hand us
# the value already escaped, in which case the decode is a no-op and such a path
# simply fails the prefix compare instead — fail closed either way.)
prep_path() {  # <raw %PATH>
  REQ_PATH="${1%%\?*}"
  REQ_PATH="${REQ_PATH%%#*}"
  REQ_PATH=$(printf '%s' "$REQ_PATH" | sed -e 's|%2[eE]|.|g' -e 's|%2[fF]|/|g' -e 's|%5[cC]|\\|g')
  REQ_PATH_OK=1
  case "$REQ_PATH" in /*) ;; *) REQ_PATH_OK=0 ;; esac
  case "$REQ_PATH" in *\\*) REQ_PATH_OK=0 ;; esac
  case "${REQ_PATH}/" in *'/../'*) REQ_PATH_OK=0 ;; esac
}

# Does <file> hold an entry matching the current request (REQ_* globals) in <mode>?
#
# Entry grammar, once the comment is stripped and whitespace collapsed:
#
#   [<METHOD>[,<METHOD>...] ]<host>[<path>]
#
# An absent method list or path means "any". <path> starts with '/' and matches
# on a SEGMENT boundary — "/repos" covers "/repos" and "/repos/x", never
# "/repository" — which is the hostname rule's label boundary, one layer down. A
# trailing '*' ("/repos*") makes it a raw prefix instead.
#
# A line may carry "# expires=<unix-epoch>" (written by `cid domains add --for`);
# once that time has passed the line no longer matches — cheap, checked at read
# time, no daemon needed. A malformed expires= value fails closed (skipped).
#
# <mode> is one of:
#   grant         entry must cover host + method + path (the real decision)
#   connect       entry must cover the host; method and path are not yet known
#   unrestricted  entry must cover the host AND carry no method or path rule
#   restricted    entry must cover the host AND carry a method or path rule
#
# _-prefixed vars (no `local`) avoid clobbering the caller's state, portably.
match_in_file() {  # <file> <mode>
  MATCH_ENTRY=''   # before the -f bail below: a no-match must report nothing
  MATCH_EHOST=''
  _file="$1"
  _mode="$2"
  [ -f "$_file" ] || return 1
  _now=$(date +%s)
  while IFS= read -r _line || [ -n "$_line" ]; do
    _entry="${_line%%#*}"                                   # strip trailing comment
    _entry=$(printf '%s' "$_entry" | tr -s '[:space:]' ' ') # squeeze runs to one space
    _entry="${_entry# }"
    _entry="${_entry% }"
    [ -z "$_entry" ] && continue
    case "$_line" in
      *'#'*expires=*)
        _exp="${_line#*expires=}"
        _exp=$(printf '%s' "$_exp" | tr -d '[:space:]')
        case "$_exp" in
          ''|*[!0-9]*) continue ;;        # malformed — fail closed, skip
        esac
        [ "$_exp" -le "$_now" ] && continue   # expired — skip
        ;;
    esac

    # Optional leading method list, then host and optional path.
    case "$_entry" in
      *' '*) _methods="${_entry%% *}"; _target="${_entry#* }" ;;
      *)     _methods=''; _target="$_entry" ;;
    esac
    case "$_target" in *' '*) continue ;; esac   # a third field is a typo, not a rule
    case "$_target" in
      */*) _ehost="${_target%%/*}"; _epath="/${_target#*/}" ;;
      *)   _ehost="$_target"; _epath='' ;;
    esac
    [ -n "$_ehost" ] || continue
    host_matches "$_ehost" || continue
    # Every `return 0` below is downstream of here, and neither value changes
    # again this iteration — so on a match these name the winning line. A line
    # that host-matches then fails the method/path rules overwrites them and
    # falls through, which is unreachable as a READ: only a caller that got
    # `return 0` looks, and there the last write is by definition the winner.
    MATCH_ENTRY="$_entry"
    MATCH_EHOST="$_ehost"

    case "$_mode" in
      connect)      return 0 ;;   # tunnel setup; the inner request is checked on its own
      unrestricted) if [ -z "$_methods" ] && [ -z "$_epath" ]; then return 0; fi; continue ;;
      restricted)   if [ -n "$_methods" ] || [ -n "$_epath" ]; then return 0; fi; continue ;;
    esac

    if [ -n "$_methods" ]; then
      _methods=$(printf '%s' "$_methods" | tr '[:lower:]' '[:upper:]')
      case ",${_methods}," in *",${REQ_METHOD},"*) ;; *) continue ;; esac
    fi
    if [ -n "$_epath" ]; then
      [ "$REQ_PATH_OK" = 1 ] || continue
      case "$_epath" in
        *'*')   # raw prefix — the caller opted out of the segment boundary
          _pfx="${_epath%\*}"
          case "$REQ_PATH" in "$_pfx"*) ;; *) continue ;; esac
          ;;
        *)      # segment boundary: the entry itself, or anything below it
          _pfx="${_epath%/}"
          if [ "$REQ_PATH" != "$_pfx" ]; then
            case "$REQ_PATH" in "$_pfx"/*) ;; *) continue ;; esac
          fi
          ;;
      esac
    fi
    return 0
  done < "$_file"
  return 1
}

while read -r key method host path _; do
  REQ_HOST="${host%%:*}"     # strip any :port
  REQ_HOST="${REQ_HOST%.}"   # tolerate a trailing dot (FQDN root)
  REQ_METHOD=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  if [ "$REQ_METHOD" = CONNECT ]; then
    REQ_PATH=''              # authority-form request: there is no path yet
    REQ_PATH_OK=0
  else
    prep_path "$path"
  fi

  # The in-container browser logs in as "<project-key>-browser" so its noisy web
  # hosts can be allowed without widening what the agent's own curl/npm reach.
  # Stripped BEFORE the key guard so both identities resolve to the one project
  # dir. run.sh's project_key() always ends in 10 hex chars, and "browser" is not
  # hex, so no real project can claim this suffix. See docs/browser-vnc.md.
  is_browser=0
  case "$key" in
    *-browser) is_browser=1; key="${key%-browser}" ;;
  esac

  # Defence in depth: the key indexes a directory path, so confine it to the
  # charset run.sh produces (^[a-z0-9][a-z0-9-]*$). First char must be alnum;
  # the tr check rejects any char outside [a-z0-9-]. Anything else matches only
  # the baseline.
  case "$key" in
    [a-z0-9]*)
      if [ -z "$(printf '%s' "$key" | tr -d 'a-z0-9-')" ]; then
        project_dir="${PROJECTS_DIR}/${key}"
      else
        project_dir="/nonexistent"
      fi
      ;;
    *)
      project_dir="/nonexistent"
      ;;
  esac
  allow_project="${project_dir}/allowed-domains.txt"
  # Consulted only for the browser identity, and ADDITIVE: the browser gets the
  # agent's lists plus these, never fewer. So the agent is always a subset, and
  # a host added to render a page can never be reached by anything else.
  browser_baseline='/nonexistent'
  browser_project='/nonexistent'
  if [ "$is_browser" = 1 ]; then
    browser_baseline="$BROWSER_BASELINE"
    browser_project="${project_dir}/browser-domains.txt"
  fi

  if [ "$MODE" = skipdecrypt ]; then
    skip_project="${project_dir}/skip-decryption.txt"
    if match_in_file "$SKIP_DECRYPTION_BASELINE" connect \
       || match_in_file "$skip_project" connect; then
      # Splicing hides the inner request, and the inner request is where a method
      # or path rule is enforced. So refuse to splice a host reachable ONLY
      # through such a rule — otherwise the rule would silently degrade to
      # host-level. A host with a plain entry as well keeps today's answer, and so
      # does one that is not allowlisted at all (its CONNECT is denied anyway).
      if match_in_file "$BASELINE" unrestricted || match_in_file "$allow_project" unrestricted \
         || match_in_file "$browser_baseline" unrestricted \
         || match_in_file "$browser_project" unrestricted; then
        echo "OK"
      elif match_in_file "$BASELINE" restricted || match_in_file "$allow_project" restricted \
           || match_in_file "$browser_baseline" restricted \
           || match_in_file "$browser_project" restricted; then
        echo "ERR"
      else
        echo "OK"
      fi
    else
      echo "ERR"
    fi
    continue
  fi

  # Not a decision: which entry makes this host reachable at all, for the alert
  # proxy/watch.sh raises on a first-time host. Always `connect` (host-level),
  # because seen-hosts.txt and the alert are both keyed by host — and because
  # under `grant` a method-scoped entry ("GET,HEAD fonts.gstatic.com") would
  # fail the method compare against the CONNECT and report a plainly-allowed
  # host as unexplained. Same four files in the SAME order as the real decision
  # below, so the entry named is the one Squid actually used. MATCH_* survive
  # the winning arm untouched: `||` short-circuits, so no later call clears them.
  if [ "$MODE" = explain ]; then
    if   match_in_file "$BASELINE"         connect; then _src=baseline
    elif match_in_file "$allow_project"    connect; then _src=project
    elif match_in_file "$browser_baseline" connect; then _src=browser-baseline
    elif match_in_file "$browser_project"  connect; then _src=browser-project
    else _src=none
    fi
    if [ "$_src" = none ]; then
      printf 'none\tnone\t-\t-\n'
    else
      # The one-character test host_matches branches on, so it cannot drift.
      case "$MATCH_EHOST" in
        .*) _kind=wildcard ;;
        *)  _kind=exact ;;
      esac
      # Both halves, so the caller never re-splits "methods, then host, then
      # path" — that would be a second implementation of this grammar. Field 3
      # is what an alert shows, field 4 what seen-hosts.txt records. Tab-safe by
      # construction: the comment is stripped and whitespace squeezed to single
      # spaces above, so neither can hold a tab or a newline.
      printf '%s\t%s\t%s\t%s\n' "$_src" "$_kind" "$MATCH_EHOST" "$MATCH_ENTRY"
    fi
    continue
  fi

  # Also not a decision: has the user told the watcher to stop notifying about
  # this host? Nothing here is enforced — a muted host is allowed or denied
  # exactly as before, and only proxy/watch.sh asks. Hostname-only, like
  # skip-decryption.txt, so `connect` is the only mode that fits; the two files
  # the browser adds are deliberately absent, so one mute covers both identities
  # (the "-browser" suffix was stripped above). The verdict is a POSITIVE token:
  # a missing file, an old helper or garbage all read as NOT muted, which fails
  # toward alerting. See docs/egress-alerts.md.
  if [ "$MODE" = muted ]; then
    muted_project="${project_dir}/muted-hosts.txt"
    if   match_in_file "$MUTED_BASELINE" connect; then _src=baseline
    elif match_in_file "$muted_project"  connect; then _src=project
    else _src=none
    fi
    if [ "$_src" = none ]; then
      printf 'none\tnone\t-\t-\n'
    else
      case "$MATCH_EHOST" in
        .*) _kind=wildcard ;;
        *)  _kind=exact ;;
      esac
      printf 'muted\t%s\t%s\t%s\n' "$_src" "$_kind" "$MATCH_ENTRY"
    fi
    continue
  fi

  if [ "$REQ_METHOD" = CONNECT ]; then mode=connect; else mode=grant; fi
  if match_in_file "$BASELINE" "$mode" || match_in_file "$allow_project" "$mode" \
     || match_in_file "$browser_baseline" "$mode" \
     || match_in_file "$browser_project" "$mode"; then
    echo "OK"
  else
    echo "ERR"
  fi
done
