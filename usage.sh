#!/usr/bin/env bash
# Thin shim: build the Go binary if missing, then exec it.
# The `claude-usage` binary (cmd/usage/main.go) is the real entry point.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/claude-usage" ] || go build -o "${SCRIPT_DIR}/claude-usage" "${SCRIPT_DIR}/cmd/usage"
exec "${SCRIPT_DIR}/claude-usage" "$@"
