#!/bin/bash
set -e

# CONTAINER_OPEN_PORTS (set by run.sh from CLAUDE_PORTS) is passed as an argument
# because sudo resets the environment. Empty when no ports are published.
sudo /usr/local/bin/init-firewall.sh "${CONTAINER_OPEN_PORTS:-}"

# Run per-project install script if mounted by run.sh (projects/<key>/install_additional_packages.sh).
# Runs as root via sudo (same privilege as the image-build install) so it can install packages.
if [[ -f "/usr/local/bin/project-install.sh" ]]; then
  echo ">> running per-project install_additional_packages.sh"
  sudo bash /usr/local/bin/project-install.sh
fi

exec "$@"
