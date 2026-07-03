#!/bin/bash
# Locks container egress to the central Squid proxy (runs as root at container
# start, before privilege drop). This is the in-container half of the egress
# boundary: all outbound policy lives in Squid, keyed by the project's proxy-auth
# username; this firewall's only job is to make sure nothing can bypass it.
#
# Uses nftables (nft) with a single dual-stack `inet` table, so IPv4 and IPv6 are
# locked by one ruleset — no separate iptables/ip6tables passes (and no chance of
# feeding an IPv6 address to an IPv4-only tool). nft talks to the same nf_tables
# subsystem the iptables shim already delegates to, and works with NET_ADMIN
# alone — no dependency on the legacy ip_tables kernel module.
#
# The container egresses ONLY to the Squid host (plus DNS to Docker's embedded
# resolver so the Squid network alias can be resolved). Everything else is
# rejected — a process that ignores the HTTP(S)_PROXY env vars doesn't leak, it
# simply fails to connect. This also closes the port-53-to-anywhere DNS
# exfiltration channel, since external DNS is shut and Squid resolves upstream
# names on the container's behalf. See docs/egress-proxy.md.
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

# Resolve the proxy alias. Resolve IPv4 and IPv6 separately (getent ahostsv4 /
# ahostsv6) and pin whichever address families exist into the ruleset — the inet
# table below matches each with its own `ip`/`ip6` rule. A plain `getent hosts`
# would hand back one family in an unpredictable order, which is how the old
# iptables version ended up passing an IPv6 address to an IPv4-only tool.
# The `|| true` matters under `set -o pipefail`: getent exits non-zero when a
# name has no record for that family (e.g. no IPv6 on an IPv4-only network), and
# without it that non-zero pipeline would abort the whole script. We want an
# empty string there and handle it explicitly below.
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

# Allow OUTBOUND to the Docker host (host.docker.internal) on the sound-server
# port only, so container hooks can reach the host-side sound daemon. The host is
# published into /etc/hosts by Docker (not DNS); resolve it to IPv4 (it often has
# an IPv6 too). Narrowly scoped to one tcp port so the container stays unable to
# reach any other host service.
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

# Inbound ports published to the host (docker run --publish) arrive on this
# container's input chain as NEW connections, which the drop policy would
# otherwise reject. Open each requested port explicitly. Values come from run.sh
# as "<port>/<proto>"; validate defensively since this runs as root.
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

# Apply our ruleset atomically (`nft -f -` is transactional: it all loads or
# nothing changes). Crucially we replace ONLY our own `inet firewall` table — we
# must NOT `flush ruleset`, which would also wipe the nftables rules Docker
# installs in the container's netns, notably the DNAT that makes the embedded DNS
# resolver at 127.0.0.11:53 work (and published-port DNAT). Flushing those breaks
# name resolution, so the container can't resolve the `squid` alias and every
# connection fails — this is why the old `iptables -F` (filter table only) was
# safe and a blanket flush is not. The bare `table inet firewall` line creates the
# table if absent so the following `delete` never errors; then we recreate it.
#
# One dual-stack inet table, every chain default-drop:
#   - allow loopback and established/related flows
#   - DNS only to Docker's embedded resolver (127.0.0.11, IPv4) — external DNS is
#     shut, closing the port-53 exfiltration channel; Squid resolves upstream
#   - the proxy port to the resolved Squid address(es)
#   - any published inbound ports; the host sound port
#   - fast-reject the rest (TCP RST / ICMP unreachable) so a blocked connection
#     errors out immediately and names the host, instead of hanging until timeout
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
