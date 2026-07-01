#!/bin/bash
# Locks container egress to the central Squid proxy (runs as root at container
# start, before privilege drop). This is the in-container half of the egress
# boundary: all outbound policy lives in Squid, keyed by the project's proxy-auth
# username; this firewall's only job is to make sure nothing can bypass it.
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

iptables -F
iptables -A INPUT  -i lo                                -j ACCEPT
iptables -A OUTPUT -o lo                                -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS only to Docker's embedded resolver (127.0.0.11) so the container can
# resolve the proxy's network alias; external DNS is closed (Squid resolves
# upstream names), which also removes the port-53 exfiltration channel.
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

# Resolve the proxy alias and allow egress ONLY to it on the proxy port.
PROXY_IP="$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}')"
if [[ -z "$PROXY_IP" ]]; then
  # Fail closed: with no proxy reachable and a DROP policy below, the container
  # simply has no egress — better than silently widening access.
  log "FATAL: egress proxy '$PROXY_HOST' did not resolve — no outbound access"
  exit 1
fi
iptables -A OUTPUT -d "$PROXY_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
log "proxy egress: ${PROXY_HOST} (${PROXY_IP}):${PROXY_PORT} — all other egress denied"

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

# Allow OUTBOUND to the Docker host (host.docker.internal) on the sound-server
# port only, so container hooks can reach the host-side sound daemon. The host
# is published into /etc/hosts by Docker (not DNS), so add it as an explicit
# rule. Narrowly scoped to one tcp port so the container stays unable to reach
# any other host service.
if [[ "$SOUND_PORT" =~ ^[0-9]+$ ]] && (( 10#$SOUND_PORT >= 1 && 10#$SOUND_PORT <= 65535 )); then
  HOST_IP="$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1; exit}')"
  if [[ -n "$HOST_IP" ]]; then
    iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$SOUND_PORT" -j ACCEPT
    log "allow host: ${HOST_IP}:${SOUND_PORT}/tcp (sound server)"
  else
    log "warn: host.docker.internal did not resolve — sound server unreachable from container"
  fi
else
  log "warn: invalid SOUND_PORT '$SOUND_PORT' — not opening host sound port"
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

log "ready"
