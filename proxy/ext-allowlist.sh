#!/usr/bin/env bash
# Squid external_acl helper: decide whether a project may reach a host.
#
# Squid sends one request per line on stdin. The squid.conf format is
# "%LOGIN %DST", but Squid appends a trailing "-" field, so each line is
# "<project-key> <host> -" — split on whitespace and take the first two fields
# (reading "the rest of the line" as host would capture the "-" and never
# match). We print "OK"/"ERR" per line, in order.
#
# A host is allowed when it is in the baseline list (shared by every project) OR
# in that project's own list. Squid's ttl= on the acl caches each verdict.
set -u

# Paths default to the in-container mount points but can be overridden via the
# environment so the helper can be unit-tested against fixtures in a temp dir
# (see test/ext-allowlist.bats). Squid itself never sets these.
BASELINE="${BASELINE:-/etc/squid/baseline-domains.txt}"
PROJECTS_DIR="${PROJECTS_DIR:-/etc/squid/projects}"

# Is $host allowed by $file? Entries are one hostname per line; '#' starts a
# comment. An entry beginning with '.' (e.g. ".example.com") is a wildcard that
# matches the apex and any subdomain; anything else is an exact hostname match.
host_in_file() {
  local host="$1" file="$2" entry
  [[ -f "$file" ]] || return 1
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"             # strip trailing comment
    entry="${entry//[[:space:]]/}"   # drop all whitespace
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == .* ]]; then
      [[ "$host" == "${entry#.}" || "$host" == *"$entry" ]] && return 0
    else
      [[ "$host" == "$entry" ]] && return 0
    fi
  done < "$file"
  return 1
}

while read -r key host _; do
  host="${host%%:*}"         # strip any :port %DST might carry
  host="${host%.}"           # tolerate a trailing dot (FQDN root)
  # Defence in depth: the key indexes a directory path, so confine it to the
  # charset run.sh produces before using it. A key with anything else can only
  # match the baseline.
  if [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    project_file="${PROJECTS_DIR}/${key}/allowed-domains.txt"
  else
    project_file="/nonexistent"
  fi
  if host_in_file "$host" "$BASELINE" || host_in_file "$host" "$project_file"; then
    echo "OK"
  else
    echo "ERR"
  fi
done
