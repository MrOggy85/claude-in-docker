#!/bin/bash
# Locks container egress to the central Squid proxy (runs as root at container
# start, before privilege drop). The in-container half of the egress boundary:
# all outbound policy lives in Squid, keyed by the project's proxy-auth username;
# this firewall's only job is to ensure nothing can bypass it.
#
# Uses one dual-stack nftables `inet` table, so IPv4 and IPv6 are locked by a
# single ruleset (no separate iptables/ip6tables passes). nft works with
# NET_ADMIN alone — no dependency on the legacy ip_tables module.
#
# The container egresses ONLY to the Squid host (plus DNS to Docker's embedded
# resolver, to resolve the Squid alias). Everything else is rejected — a process
# ignoring HTTP(S)_PROXY simply fails to connect rather than leaking. This also
# closes the port-53 DNS exfiltration channel (external DNS shut; Squid resolves
# upstream names). See docs/egress-proxy.md.
set -euo pipefail

log() { echo "[firewall] $*" >&2; }

# Comma-separated "<port>/<proto>" list of inbound ports to accept, from
# CLAUDE_PORTS via run.sh / entrypoint.sh. Optional; empty when unset.
OPEN_PORTS="${1:-}"

# Host-side sound-server port to allow OUTBOUND to (see the host rule below),
# from SOUND_PORT via run.sh / entrypoint.sh. Defaults to 4767.
SOUND_PORT="${2:-4767}"

# Egress-proxy host (the Squid network alias), from EGRESS_PROXY_HOST via run.sh
# / entrypoint.sh. Defaults to "squid" as defence-in-depth: if it ever arrives
# empty the firewall still locks egress to the proxy rather than failing open.
PROXY_HOST="${3:-squid}"

# Port the central Squid proxy listens on. Kept in sync with proxy/squid.conf.
PROXY_PORT=3128

# Resolve the proxy alias per-family (ahostsv4/ahostsv6) and pin whichever exist
# into the ruleset — the inet table matches each with its own `ip`/`ip6` rule.
# A plain `getent hosts` returns one family in unpredictable order. `|| true` is
# needed under pipefail: getent exits non-zero when a family has no record (e.g.
# no IPv6), which would otherwise abort the script; we want an empty string.
PROXY_IP="$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
PROXY_IP6="$(getent ahostsv6 "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
if [[ -z "$PROXY_IP" && -z "$PROXY_IP6" ]]; then
  # Fail closed: with no proxy reachable and a drop policy, the container simply
  # has no egress — better than silently widening access.
  log "FATAL: egress proxy '$PROXY_HOST' did not resolve — no outbound access"
  exit 1
fi

# Per-family proxy accept rules — only for the families that actually resolved.
PROXY_RULES=""
[[ -n "$PROXY_IP"  ]] && PROXY_RULES+="        ip daddr ${PROXY_IP} tcp dport ${PROXY_PORT} accept"$'\n'
[[ -n "$PROXY_IP6" ]] && PROXY_RULES+="        ip6 daddr ${PROXY_IP6} tcp dport ${PROXY_PORT} accept"$'\n'

# Allow OUTBOUND to the Docker host on the sound-server port only, so hooks can
# reach the host-side sound daemon. Docker publishes the host into /etc/hosts
# (not DNS); resolve it to IPv4. Scoped to one tcp port so no other host service
# is reachable.
HOST_RULE=""
if [[ "$SOUND_PORT" =~ ^[0-9]+$ ]] && (( 10#$SOUND_PORT >= 1 && 10#$SOUND_PORT <= 65535 )); then
  HOST_IP="$(getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$HOST_IP" ]]; then
    HOST_RULE="        ip daddr ${HOST_IP} tcp dport ${SOUND_PORT} accept"
    log "allow host: ${HOST_IP}:${SOUND_PORT}/tcp (sound server)"
  else
    log "warn: host.docker.internal did not resolve — sound server unreachable from container"
  fi
else
  log "warn: invalid SOUND_PORT '$SOUND_PORT' — not opening host sound port"
fi

# Published inbound ports (docker run --publish) arrive as NEW connections the
# drop policy would reject; open each explicitly. Values from run.sh as
# "<port>/<proto>"; validate defensively since this runs as root.
INPUT_RULES=""
if [[ -n "$OPEN_PORTS" ]]; then
  IFS=',' read -r -a _ports <<< "$OPEN_PORTS"
  for pp in ${_ports[@]+"${_ports[@]}"}; do
    port="${pp%%/*}"; proto="${pp##*/}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
      log "warn: ignoring invalid port spec '$pp'"; continue
    fi
    case "$proto" in tcp|udp) ;; *) log "warn: ignoring invalid proto in '$pp'"; continue ;; esac
    INPUT_RULES+="        ${proto} dport ${port} accept"$'\n'
    log "open inbound: ${port}/${proto}"
  done
fi

# Apply atomically (`nft -f -` is transactional). We replace ONLY our own `inet
# firewall` table — NOT `flush ruleset`, which would wipe Docker's netns rules,
# notably the DNAT for the embedded DNS resolver (127.0.0.11:53) and
# published-port DNAT; that breaks resolution of the `squid` alias. The bare
# `table inet firewall` line creates it if absent so `delete` never errors.
#
# One dual-stack inet table, every chain default-drop:
#   - loopback and established/related flows
#   - DNS only to Docker's embedded resolver (127.0.0.11) — external DNS shut
#   - the proxy port to the resolved Squid address(es)
#   - any published inbound ports; the host sound port
#   - fast-reject the rest (TCP RST / ICMP unreachable) so blocked connections
#     fail immediately and name the host instead of hanging until timeout
nft -f - <<NFT_EOF
table inet firewall
delete table inet firewall

table inet firewall {
    chain input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
${INPUT_RULES}    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ct state established,related accept
        ip daddr 127.0.0.11 udp dport 53 accept
        ip daddr 127.0.0.11 tcp dport 53 accept
${PROXY_RULES}${HOST_RULE}
        meta l4proto tcp reject with tcp reset
        reject
    }
}
NFT_EOF

log "proxy egress: ${PROXY_HOST} (${PROXY_IP:-–}${PROXY_IP6:+, [${PROXY_IP6}]}):${PROXY_PORT} — all other egress denied"
log "ready"
