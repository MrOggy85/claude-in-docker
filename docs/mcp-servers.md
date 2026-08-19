# MCP Servers

## User-level servers

Define servers in `mcp-servers.json` in the config dir (`~/.config/claude-in-docker/`, created by
`make init` from `templates/mcp-servers.json`). It holds a single `mcpServers` object and applies to
every project:

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

It is deliberately separate from `claude.json`, Claude Code's mutable state blob (caches, project
history, onboarding flags) — editing MCP config there means hand-merging one key into a large,
churning file. `run.sh` mounts `mcp-servers.json` read-only and points `claude --mcp-config` at it,
so adding or removing a server applies on the next container start: no image rebuild, no
`claude.json` surgery. A per-project `<config-dir>/projects/<key>/mcp-servers.json` overrides the
baseline for that project.

## Project-level servers

Add a `.mcp.json` at the root of your project repository. Claude Code picks it up automatically from
the mounted workspace. These are scoped to that repo and are typically checked in.

## GitHub MCP

The `gh` CLI is intentionally **not** installed. GitHub access goes through the remote GitHub MCP
server, configured in `mcp-servers.json`:

```json
"github": {
  "type": "http",
  "url": "https://api.githubcopilot.com/mcp/",
  "headers": {
    "Authorization": "Bearer ${MCP_GH_BEARER}"
  }
}
```

### Token scope

Use a **fine-grained personal access token**, not an OAuth/classic one — the latter's `repo` scope
bundles Contents:write and can't be scoped below it, so it is rejected.

- **Contents must be Read-only.** This is the code-push vector `guards/mcp-bearer-no-push.sh`
  blocks; it rejects any token where a repo reports `permissions.push`.
- **Other write permissions are your call.** Issues and Pull requests **Read and write** pass the
  guard and let Claude open, comment on, and update issues and PRs on your behalf.
- Merging a PR would land code, but that first requires committing to a branch (Contents:write,
  blocked), so there is nothing to merge.

### Passing the token

The token is not stored in `mcp-servers.json`; the config references `${MCP_GH_BEARER}`, which
Claude Code expands from the container environment. `run.sh` forwards `--env MCP_GH_BEARER` from
your host shell, so export it before running — see [Shell profile
alias](../README.md#shell-profile-alias) for pulling it from the macOS Keychain.

The non-standard variable name avoids the well-known `GH_TOKEN`/`GITHUB_TOKEN` names that
opportunistic secret scanners grep for. That is a convenience, not a security control; the real
protections are the Contents-read-only scope and the outbound allowlist.
