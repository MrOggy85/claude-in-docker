#!/bin/bash
# Configures outbound firewall at container start (runs as root, before privilege drop).
# Allowed domains come from /etc/allowed-domains.txt — baked into the image by default,
# or overridden per-project by run.sh mounting a project-specific file there.
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

# Host-side sound-server port to allow OUTBOUND to (see the host rule below),
# from SOUND_PORT via run.sh / entrypoint.sh. Defaults to 4767.
SOUND_PORT="${2:-4767}"

# Egress-proxy host (e.g. "squid"), from EGRESS_PROXY_HOST via run.sh /
# entrypoint.sh. When set, this container runs in PROXY MODE: instead of
# allowing direct egress to the resolved allowlist IPs, it allows egress ONLY to
# the central Squid proxy (plus DNS to Docker's embedded resolver). All policy
# then lives in Squid, keyed by the project's proxy-auth username. Empty => the
# default per-container IP-allowlist mode below. See docs/egress-proxy.md.
PROXY_HOST="${3:-}"

# Port the central Squid proxy listens on. Kept in sync with proxy/squid.conf.
PROXY_PORT=3128

# The domains file is only consumed by IP-allowlist mode. In proxy mode the
# allowlist lives in Squid, so its absence here must NOT short-circuit the
# firewall — that would leave the OUTPUT policy at ACCEPT and defeat the point.
if [[ -z "$PROXY_HOST" && ! -f "$DOMAINS_FILE" ]]; then
  log "no domains file at $DOMAINS_FILE — skipping"
  exit 0
fi

iptables -F
iptables -A INPUT  -i lo                                -j ACCEPT
iptables -A OUTPUT -o lo                                -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if [[ -n "$PROXY_HOST" ]]; then
  # --- PROXY MODE -----------------------------------------------------------
  # DNS only to Docker's embedded resolver (127.0.0.11) so the container can
  # resolve the proxy's network alias; external DNS is closed (Squid resolves
  # upstream names), which also removes the port-53 exfiltration channel.
  iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

  # Resolve the proxy alias and allow egress ONLY to it on the proxy port.
  PROXY_IP="$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}')"
  if [[ -z "$PROXY_IP" ]]; then
    # Fail closed: with no proxy reachable and a DROP policy below, the
    # container simply has no egress — better than silently widening access.
    log "FATAL: egress proxy '$PROXY_HOST' did not resolve — no outbound access"
    exit 1
  fi
  iptables -A OUTPUT -d "$PROXY_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
  log "proxy egress: ${PROXY_HOST} (${PROXY_IP}):${PROXY_PORT} — all other egress denied"
else
  # --- IP-ALLOWLIST MODE (default) ------------------------------------------
  ipset destroy "$IPSET_NAME" 2>/dev/null || true
  ipset create "$IPSET_NAME" hash:net

  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  # Initial synchronous resolution so connectivity is up before claude starts.
  refresh_allowlist 1

  iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT
fi

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
# is published into /etc/hosts by Docker (not DNS), so it can't ride the
# dig-based allowlist above — add it as an explicit rule. Narrowly scoped to one
# tcp port so the container stays unable to reach any other host service.
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

# Start the background refresher now that the ipset ACCEPT rule is live. setsid
# detaches it into its own session so it survives after this script returns and
# the entrypoint exec's claude; it dies with the container. Its output goes to a
# logfile (not the terminal, which would corrupt claude's TUI; not /dev/null, so
# rotations stay inspectable) and stdin is detached so it never holds anything open.
# Proxy mode has no ipset to top up (Squid owns the allowlist), so the refresher
# only runs in IP-allowlist mode.
REFRESH_LOG="/tmp/firewall-refresh.log"
if [[ -z "$PROXY_HOST" ]] && (( REFRESH_SECS > 0 )); then
  setsid "$0" --refresh-loop "$REFRESH_SECS" </dev/null >>"$REFRESH_LOG" 2>&1 &
  disown 2>/dev/null || true
  log "refresher started (every ${REFRESH_SECS}s) → $REFRESH_LOG"
fi

log "ready"
