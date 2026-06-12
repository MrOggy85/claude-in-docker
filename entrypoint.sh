#!/bin/bash
set -e

if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  echo "dev:x:$(id -u):$(id -g):dev:/home/dev:/bin/bash" >> /etc/passwd
fi
if ! getent group "$(id -g)" >/dev/null 2>&1; then
  echo "dev:x:$(id -g):" >> /etc/group
fi

# CONTAINER_OPEN_PORTS (set by run.sh from CLAUDE_PORTS) is passed as an argument
# because sudo resets the environment. Empty when no ports are published.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}"

exec "$@"
