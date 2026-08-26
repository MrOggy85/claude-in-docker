#!/usr/bin/env bash
#
# Guard: the host chrome-devtools bridge (chrome-devtools-mcp/, see
# docs/chrome-devtools-mcp.md) runs the browser on the host, so a bridge that is
# not up surfaces mid-session as a confusing MCP failure rather than as a
# startup error. Warn now instead.
#
# Policy checks do NOT live here: the token is minted by run.sh (step 3c-d) and
# the browser's own URL allowlist is tracked separately, so there is nothing to
# fail closed on — this is a liveness warning only.
#
# No-op unless CLAUDE_CHROME_DEVTOOLS is on.
#
# Sourced by run.sh (not run standalone): reads CLAUDE_CHROME_DEVTOOLS and
# CHROME_DEVTOOLS_MCP_PORT from the caller.

case "${CLAUDE_CHROME_DEVTOOLS:-}" in
  1|true|yes|on|TRUE|YES|ON)
    _cdg_port="${CHROME_DEVTOOLS_MCP_PORT:-9333}"
    if command -v curl >/dev/null 2>&1 \
       && ! curl -s -o /dev/null --max-time 2 "http://localhost:${_cdg_port}/mcp"; then
      warn "nothing is listening on localhost:${_cdg_port} — the chrome-devtools" \
           "bridge looks down, so its MCP tools will fail in-session. Start it with" \
           "./chrome-devtools-mcp/host-chrome-devtools-mcp.sh (or load the launchd agent)."
    fi
    unset _cdg_port
    ;;
  *) ;;  # bridge off: nothing to check
esac
