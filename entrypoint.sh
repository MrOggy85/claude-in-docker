#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (set by run.sh from CLAUDE_PORTS) and SOUND_PORT are passed
# as arguments because sudo resets the environment. CONTAINER_OPEN_PORTS is empty
# when no ports are published; SOUND_PORT defaults to 4767 in the firewall script.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}" "${SOUND_PORT:-}"

exec "$@"
