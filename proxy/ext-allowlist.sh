#!/usr/bin/env bash
# Squid external_acl helper: may this project reach this host?
#
# Per line on stdin Squid sends "<project-key> <host> -" (the format is
# "%LOGIN %DST"; Squid appends a trailing "-"). Take the first two fields and
# print "OK"/"ERR" per line, in order. Allowed = host in the shared baseline
# list OR in the project's own list.
set -u

# Overridable so the helper can be unit-tested against fixtures (see
# test/ext-allowlist.bats). Squid never sets these; it uses the defaults.
BASELINE="${BASELINE:-/etc/squid/baseline-domains.txt}"
PROJECTS_DIR="${PROJECTS_DIR:-/etc/squid/projects}"

# Is $host allowed by $file? One hostname per line, '#' starts a comment. A
# leading '.' (".example.com") matches the apex and any subdomain; else exact.
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
  host="${host%%:*}"         # strip any :port
  host="${host%.}"           # tolerate a trailing dot (FQDN root)
  # Defence in depth: the key indexes a directory path, so confine it to the
  # charset run.sh produces. Anything else matches only the baseline.
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
