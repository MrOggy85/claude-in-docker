#!/bin/bash
# Configures outbound firewall at container start (runs as root, before privilege drop).
# Allowed domains are baked into the image at /etc/allowed-domains.txt — rebuild to change them.
set -euo pipefail

DOMAINS_FILE="/etc/allowed-domains.txt"
IPSET_NAME="allowed-ips"

log() { echo "[firewall] $*" >&2; }

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

while IFS= read -r domain || [[ -n "$domain" ]]; do
  [[ "$domain" =~ ^[[:space:]]*# || -z "${domain//[[:space:]]/}" ]] && continue
  ips=$(dig +short +timeout=5 "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [[ -z "$ips" ]]; then
    log "warn: could not resolve $domain"
    continue
  fi
  log "$domain → $(echo "$ips" | tr '\n' ' ')"
  while IFS= read -r ip; do
    ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
  done <<< "$ips"
done < "$DOMAINS_FILE"

iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

# Fail fast instead of silently dropping. A bare `-P OUTPUT DROP` makes blocked
# connections hang until the client's own timeout; an explicit REJECT sends a TCP
# RST (-> immediate ECONNREFUSED) or an ICMP unreachable, so the process errors
# out right away and names the host it failed to reach.
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT       -j REJECT --reject-with icmp-port-unreachable

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

log "ready"
