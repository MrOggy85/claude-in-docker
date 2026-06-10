#!/bin/bash
set -e

sudo /usr/local/bin/init-firewall.sh

if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  echo "dev:x:$(id -u):$(id -g):dev:/home/dev:/bin/bash" >> /etc/passwd
fi
if ! getent group "$(id -g)" >/dev/null 2>&1; then
  echo "dev:x:$(id -g):" >> /etc/group
fi

exec "$@"
