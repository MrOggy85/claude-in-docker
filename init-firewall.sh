#!/bin/bash
# Configures outbound firewall at container start (runs as root, before privilege drop).
# Allowed domains are baked into the image at /etc/allowed-domains.txt — rebuild to change them.
set -euo pipefail

DOMAINS_FILE="/etc/allowed-domains.txt"
IPSET_NAME="allowed-ips"

# The allowed hosts are CDN-fronted and rotate their IPs *within* a session
# (api.githubcopilot.com notably moves around GitHub's 140.82.112.0/20 block).
# A one-shot resolution at startup therefore goes stale: a later connection hits
# a freshly-rotated IP that was never added, and the REJECT rule below drops it.
# A background loop re-resolves the allowlist every REFRESH_SECS and tops up the
# ipset. Set to 0 to disable the refresher (startup resolution only).
REFRESH_SECS=30

log() { echo "[firewall] $*" >&2; }

# Resolve every hostname in $DOMAINS_FILE and add any new IPv4 addresses to the
# ipset. Pass "1" for verbose startup logging (one line per host); pass "0" for
# the background refresher, which logs only the IPs it newly adds. This only ever
# adds the actual DNS answers for the listed names — never a broader range — so
# it cannot widen the policy beyond what the allowlist already names.
refresh_allowlist() {
  local verbose="$1" domain ips ip
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ "$domain" =~ ^[[:space:]]*# || -z "${domain//[[:space:]]/}" ]] && continue
    ips=$(dig +short +timeout=5 "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [[ -z "$ips" ]]; then
      [[ "$verbose" == "1" ]] && log "warn: could not resolve $domain"
      continue
    fi
    while IFS= read -r ip; do
      # `ipset add` exits 0 only when the element was not already present, so this
      # logs a host's IP exactly once — when it first appears (e.g. after a rotation).
      if ipset add "$IPSET_NAME" "$ip" 2>/dev/null && [[ "$verbose" != "1" ]]; then
        log "refresh: +$ip ($domain)"
      fi
    done <<< "$ips"
    [[ "$verbose" == "1" ]] && log "$domain → $(echo "$ips" | tr '\n' ' ')"
  done < "$DOMAINS_FILE"
  return 0
}

# Detached re-invocation (setsid "$0" --refresh-loop <secs>): skip all iptables
# setup and just keep the ipset current for the container's lifetime. Already
# running as root (inherited from the initial sudo invocation), so it needs no
# sudo and touches no iptables rules — only `ipset add`.
if [[ "${1:-}" == "--refresh-loop" ]]; then
  REFRESH_SECS="${2:-$REFRESH_SECS}"
  while sleep "$REFRESH_SECS"; do
    refresh_allowlist 0
  done
  exit 0
fi

# Comma-separated "<port>/<proto>" list of inbound ports to accept, from
# CLAUDE_PORTS via run.sh / entrypoint.sh. Optional; empty when unset.
OPEN_PORTS="${1:-}"

if [[ ! -f "$DOMAINS_FILE" ]]; then
  log "no domains file at $DOMAINS_FILE — skipping"
  exit 0
fi

ipset destroy "$IPSET_NAME" 2>/dev/null || true
ipset create "$IPSET_NAME" hash:net

iptables -F
iptables -A INPUT  -i lo                                -j ACCEPT
iptables -A OUTPUT -o lo                                -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53                    -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53                    -j ACCEPT

# Initial synchronous resolution so connectivity is up before claude starts.
refresh_allowlist 1

iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

# Inbound ports published to the host (docker run --publish) arrive on this
# container's INPUT chain as NEW connections, which the DROP policy below would
# otherwise reject. Open each requested port explicitly. Values come from
# run.sh as "<port>/<proto>"; validate defensively since this runs as root.
if [[ -n "$OPEN_PORTS" ]]; then
  IFS=',' read -r -a _ports <<< "$OPEN_PORTS"
  for pp in ${_ports[@]+"${_ports[@]}"}; do
    port="${pp%%/*}"; proto="${pp##*/}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
      log "warn: ignoring invalid port spec '$pp'"; continue
    fi
    case "$proto" in tcp|udp) ;; *) log "warn: ignoring invalid proto in '$pp'"; continue ;; esac
    iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
    log "open inbound: ${port}/${proto}"
  done
fi

# Fail fast instead of silently dropping. A bare `-P OUTPUT DROP` makes blocked
# connections hang until the client's own timeout; an explicit REJECT sends a TCP
# RST (-> immediate ECONNREFUSED) or an ICMP unreachable, so the process errors
# out right away and names the host it failed to reach.
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT       -j REJECT --reject-with icmp-port-unreachable

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Start the background refresher now that the ipset ACCEPT rule is live. setsid
# detaches it into its own session so it survives after this script returns and
# the entrypoint exec's claude; it dies with the container. Its output goes to a
# logfile (not the terminal, which would corrupt claude's TUI; not /dev/null, so
# rotations stay inspectable) and stdin is detached so it never holds anything open.
REFRESH_LOG="/tmp/firewall-refresh.log"
if (( REFRESH_SECS > 0 )); then
  setsid "$0" --refresh-loop "$REFRESH_SECS" </dev/null >>"$REFRESH_LOG" 2>&1 &
  disown 2>/dev/null || true
  log "refresher started (every ${REFRESH_SECS}s) → $REFRESH_LOG"
fi

log "ready"
