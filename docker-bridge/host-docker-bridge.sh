#!/bin/bash
# Wrapper for launchd/systemd --user: sources nvm so `node` resolves to the
# user's default version, exports the config locations from scripts/paths.sh
# (the single source of truth, so the JS never re-derives them), then exec's
# the Node bridge.
set -e
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/paths.sh disable=SC1091
. "$SCRIPT_DIR/../scripts/paths.sh"
CID_CONFIG_DIR="$(config_dir)"
CID_PROJECTS_DIR="$(projects_dir)"
export CID_CONFIG_DIR CID_PROJECTS_DIR
# Service managers start agents with a minimal PATH; Docker Desktop's CLI (macOS)
# and common manual-install locations (Linux) live here.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
exec node "$SCRIPT_DIR/host-docker-bridge.js"
