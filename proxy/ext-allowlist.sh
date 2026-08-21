#!/bin/sh
# Squid external_acl helper, in two modes over one grammar:
#
#   (no argument)  may this project reach this host?  -> allowed-domains.txt
#   --skip-decryption       should this host be tunnelled WITHOUT decryption, instead of
#                  bumped?                            -> skip-decryption.txt
#
# Per line on stdin Squid sends "<project-key> <host> -" (the format is
# "%LOGIN %DST"; Squid appends a trailing "-"). Take the first two fields and
# print "OK"/"ERR" per line, in order. OK = host in the shared baseline list OR
# in the project's own list — same matching, key guard and fail-closed behaviour
# in both modes, only the two filenames differ. Both external_acl_type lines in
# squid.conf point here; see docs/tls-inspection.md for what splicing means.
#
# POSIX sh, no bashisms: the ubuntu/squid base isn't guaranteed to ship bash, and
# `#!/usr/bin/env bash` crash-loops the helper (exec ENOENT) at 100% CPU when it's
# absent. auth-ok.sh is /bin/sh for the same reason. See docs/egress-proxy.md.
set -u
export LC_ALL=C   # locale-stable [a-z0-9] / [:space:] ranges

# Overridable so the helper can be unit-tested against fixtures (see
# test/ext-allowlist.bats). Squid never sets these; it uses the defaults.
BASELINE="${BASELINE:-/etc/squid/baseline-domains.txt}"
SKIP_DECRYPTION_BASELINE="${SKIP_DECRYPTION_BASELINE:-/etc/squid/baseline-skip-decryption.txt}"
PROJECTS_DIR="${PROJECTS_DIR:-/etc/squid/projects}"

# Mode: which baseline file and which per-project filename to consult. An unknown
# argument is a squid.conf typo — refuse rather than silently answering with the
# allowlist (which, in skip-decryption mode, would mean "never decrypt anything").
PROJECT_FILENAME='allowed-domains.txt'
case "${1:-}" in
  '') ;;
  --skip-decryption)
    BASELINE="${SKIP_DECRYPTION_BASELINE}"
    PROJECT_FILENAME='skip-decryption.txt'
    ;;
  *)
    echo "ext-allowlist.sh: unknown mode '$1' (expected --skip-decryption or no argument)" >&2
    exit 2
    ;;
esac

# Is $1 (host) allowed by $2 (file)? One hostname per line, '#' starts a comment.
# A leading '.' (".example.com") matches the apex and any subdomain; else exact.
# A line may carry "# expires=<unix-epoch>" (written by `cid domains add --for`);
# once that time has passed the line no longer matches — cheap, checked at read
# time, no daemon needed. A malformed expires= value fails closed (skipped).
# _-prefixed vars (no `local`) avoid clobbering the caller's $host, portably.
host_in_file() {
  _host="$1"
  _file="$2"
  [ -f "$_file" ] || return 1
  _now=$(date +%s)
  while IFS= read -r _line || [ -n "$_line" ]; do
    _entry="${_line%%#*}"                                 # strip trailing comment
    _entry=$(printf '%s' "$_entry" | tr -d '[:space:]')   # drop all whitespace
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
    case "$_entry" in
      .*)   # wildcard: matches the apex and any subdomain, on a label boundary
        case "$_host" in
          "${_entry#.}"|*"$_entry") return 0 ;;
        esac
        ;;
      *)    # exact match
        [ "$_host" = "$_entry" ] && return 0
        ;;
    esac
  done < "$_file"
  return 1
}

while read -r key host _; do
  host="${host%%:*}"         # strip any :port
  host="${host%.}"           # tolerate a trailing dot (FQDN root)
  # Defence in depth: the key indexes a directory path, so confine it to the
  # charset run.sh produces (^[a-z0-9][a-z0-9-]*$). First char must be alnum;
  # the tr check rejects any char outside [a-z0-9-]. Anything else matches only
  # the baseline.
  case "$key" in
    [a-z0-9]*)
      if [ -z "$(printf '%s' "$key" | tr -d 'a-z0-9-')" ]; then
        project_file="${PROJECTS_DIR}/${key}/${PROJECT_FILENAME}"
      else
        project_file="/nonexistent"
      fi
      ;;
    *)
      project_file="/nonexistent"
      ;;
  esac
  if host_in_file "$host" "$BASELINE" || host_in_file "$host" "$project_file"; then
    echo "OK"
  else
    echo "ERR"
  fi
done
