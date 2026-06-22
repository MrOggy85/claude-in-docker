# MCP Servers

## User-level servers
Define servers in `mcp-servers.json` next to `run.sh` (created by `make init`
from `templates/mcp-servers.json`). It holds a single `mcpServers` object and
applies to every project you run in the container:

```json
{
  "mcpServers": {
    "atlassian": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp"
    }
  }
}
```

This file is kept deliberately separate from `claude.json` — the latter is
Claude Code's mutable state blob (caches, project history, onboarding flags), so
editing MCP config there means hand-merging one key into a large, churning file.
`run.sh` mounts `mcp-servers.json` read-only and points `claude --mcp-config` at
it, making it the single source of truth: add or remove a server and the change
applies on the next container start — no image rebuild, no `claude.json`
surgery. A per-project `projects/<key>/mcp-servers.json` overrides the root copy
for that project.

## Project-level servers
Add a `.mcp.json` file at the root of your project repository. Claude Code picks it up automatically from the mounted workspace. These are scoped to that repo and are typically checked in.

## GitHub MCP

The `gh` CLI is intentionally **not** installed in the container. GitHub access goes through the remote GitHub MCP server instead, configured in `mcp-servers.json`:

```json
"github": {
  "type": "http",
  "url": "https://api.githubcopilot.com/mcp/",
  "headers": {
    "Authorization": "Bearer ${MCP_GH_BEARER}"
  }
}
```

Use a **fine-grained personal access token with read-only scopes**, not an OAuth token. An OAuth token's `repo` scope grants push access (and `gh auth login` can't drop below it), which is a no-go for this container — it should not be able to mutate your repos.

The token is not stored in `mcp-servers.json`; the config references `${MCP_GH_BEARER}`, which Claude Code expands from the container environment. `run.sh` passes `--env MCP_GH_BEARER` through from your host shell, so export `MCP_GH_BEARER` before running (see [Shell profile alias](../README.md#shell-profile-alias) for pulling it from the macOS Keychain). The non-standard variable name is deliberate — it avoids the well-known `GH_TOKEN`/`GITHUB_TOKEN` names that opportunistic secret scanners grep for. This is a minor convenience, not a security control; the real protections are the read-only token scope and the outbound allowlist.
