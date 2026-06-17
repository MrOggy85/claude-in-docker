#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (set by run.sh from CLAUDE_PORTS) is passed as an argument
# because sudo resets the environment. Empty when no ports are published.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}"

exec "$@"
