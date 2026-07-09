#!/bin/sh
# Squid external_acl helper: may this project reach this host?
#
# Per line on stdin Squid sends "<project-key> <host> -" (the format is
# "%LOGIN %DST"; Squid appends a trailing "-"). Take the first two fields and
# print "OK"/"ERR" per line, in order. Allowed = host in the shared baseline
# list OR in the project's own list.
#
# POSIX sh, no bashisms: the ubuntu/squid base isn't guaranteed to ship bash, and
# `#!/usr/bin/env bash` crash-loops the helper (exec ENOENT) at 100% CPU when it's
# absent. auth-ok.sh is /bin/sh for the same reason. See docs/egress-proxy.md.
set -u
export LC_ALL=C   # locale-stable [a-z0-9] / [:space:] ranges

# Overridable so the helper can be unit-tested against fixtures (see
# test/ext-allowlist.bats). Squid never sets these; it uses the defaults.
BASELINE="${BASELINE:-/etc/squid/baseline-domains.txt}"
PROJECTS_DIR="${PROJECTS_DIR:-/etc/squid/projects}"

# Is $1 (host) allowed by $2 (file)? One hostname per line, '#' starts a comment.
# A leading '.' (".example.com") matches the apex and any subdomain; else exact.
# _-prefixed vars (no `local`) avoid clobbering the caller's $host, portably.
host_in_file() {
  _host="$1"
  _file="$2"
  [ -f "$_file" ] || return 1
  while IFS= read -r _entry || [ -n "$_entry" ]; do
    _entry="${_entry%%#*}"                                # strip trailing comment
    _entry=$(printf '%s' "$_entry" | tr -d '[:space:]')   # drop all whitespace
    [ -z "$_entry" ] && continue
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
        project_file="${PROJECTS_DIR}/${key}/allowed-domains.txt"
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
