#!/usr/bin/env bash
# Thin shim: build the Go binary if missing, then exec it.
# The `claude` binary (cmd/claude/main.go) is the real entry point.
# This script exists so the documented shell alias (function claude { .../run.sh "$@" })
# continues to work without any changes on the user's side.
#
# To skip the build check and run the binary directly, point the alias at ./claude instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/claude" ] || go build -o "${SCRIPT_DIR}/claude" "${SCRIPT_DIR}/cmd/claude"
exec "${SCRIPT_DIR}/claude" "$@"
