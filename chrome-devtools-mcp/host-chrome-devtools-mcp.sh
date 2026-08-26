#!/bin/bash
# Wrapper for launchd: sources nvm so `node`/`npx` resolve to the user's default
# version, exports the config locations from scripts/paths.sh (the single source
# of truth, so the JS never re-derives them), then exec's the Node bridge.
# Survives nvm version bumps.
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
exec node "$SCRIPT_DIR/host-chrome-devtools-mcp.js"
