#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (set by run.sh from CLAUDE_PORTS), SOUND_PORT, and
# EGRESS_PROXY_HOST are passed as arguments because sudo resets the environment.
# CONTAINER_OPEN_PORTS is empty when no ports are published; SOUND_PORT defaults
# to 4767 in the firewall script. EGRESS_PROXY_HOST is set by run.sh to the Squid
# host ("squid") so init-firewall.sh locks egress to the proxy — see that script.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}" "${SOUND_PORT:-}" "${EGRESS_PROXY_HOST:-}"

exec "$@"
