#!/bin/bash
# Wrapper for launchd: sources nvm so `node`/`npx` resolve to the user's default
# version, then exec's the Node bridge. Survives nvm version bumps.
set -e
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/host-chrome-devtools-mcp.js"
