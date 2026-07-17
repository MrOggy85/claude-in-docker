#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (from CLAUDE_PORTS), CONTAINER_HOST_OUTBOUND_PORTS (from
# SOUND_PORT + CLAUDE_HOST_OUTBOUND_PORTS, merged by run.sh), and EGRESS_PROXY_HOST
# are passed as arguments because sudo resets the environment. CONTAINER_OPEN_PORTS
# is empty when no ports are published. EGRESS_PROXY_HOST is set by run.sh to the
# Squid host ("squid") so init-firewall.sh locks egress to the proxy — see that script.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}" "${CONTAINER_HOST_OUTBOUND_PORTS:-}" "${EGRESS_PROXY_HOST:-}"

exec "$@"
