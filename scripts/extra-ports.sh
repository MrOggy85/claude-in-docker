#!/usr/bin/env bash
#
# Emit `docker run` --publish specs for the container ports named in
# CLAUDE_PORTS (comma-separated), so the host can reach a server running inside
# the container. Each accepted entry prints ONE tab-separated line on stdout:
#
#   <publish-spec>\t<container-port>/<proto>
#
# The first field feeds `docker run --publish`; the second tells the in-container
# firewall (init-firewall.sh) which inbound ports to open — publishing alone is
# not enough, because the firewall's INPUT policy is DROP. Human-readable
# progress/skip messages go to stderr.
#
# Entry syntax (per comma-separated item), with an optional /tcp (default) or
# /udp suffix:
#   PORT                 -> publish PORT:PORT        (host 0.0.0.0)
#   HOSTPORT:CPORT       -> publish HOSTPORT:CPORT
#   IP:HOSTPORT:CPORT    -> publish IP:HOSTPORT:CPORT (bind host to IP, e.g.
#                           127.0.0.1 to keep it host-local)
#
# Inputs (environment):
#   CLAUDE_PORTS   comma-separated list (optional; no output, exit 0 if unset)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Messages go to stderr (stdout is the token stream), so colour is decided from
# fd 2 — see the colour file for the emitters and the palette.
# shellcheck source=colors.sh disable=SC1091
source "${SCRIPT_DIR}/colors.sh"
color_init 2

[[ -z "${CLAUDE_PORTS:-}" ]] && exit 0

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

IFS=',' read -r -a ENTRIES <<< "${CLAUDE_PORTS}"
for entry in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
  # trim surrounding whitespace
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [[ -z "$entry" ]] && continue

  # optional /tcp | /udp suffix (default tcp)
  proto="tcp"
  case "$entry" in
    */tcp) entry="${entry%/tcp}" ;;
    */udp) proto="udp"; entry="${entry%/udp}" ;;
    */*)   kv "skipping port (unknown protocol, use /tcp or /udp)" "$entry"; continue ;;
  esac

  # split on ":" -> 1, 2, or 3 fields
  IFS=':' read -r -a parts <<< "$entry"
  ip=""
  case "${#parts[@]}" in
    1) hport="${parts[0]}"; cport="${parts[0]}" ;;
    2) hport="${parts[0]}"; cport="${parts[1]}" ;;
    3) ip="${parts[0]}";    hport="${parts[1]}"; cport="${parts[2]}" ;;
    *) kv "skipping port (too many ':' fields)" "$entry"; continue ;;
  esac

  if ! is_port "$hport" || ! is_port "$cport"; then
    kv "skipping port (not a valid 1-65535 port)" "$entry"; continue
  fi

  if [[ -n "$ip" ]]; then spec="${ip}:${hport}:${cport}/${proto}"
  else                    spec="${hport}:${cport}/${proto}"; fi

  kv "publish (${proto})" "host ${ip:+${ip}:}${hport} -> container ${cport}"
  printf '%s\t%s\n' "$spec" "${cport}/${proto}"
done
