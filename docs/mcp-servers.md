# MCP Servers

## User-level servers
Add servers to the `mcpServers` object in your local `claude.json`. They apply to every project you run in the container. Example:

```json
"mcpServers": {
  "atlassian": {
    "type": "sse",
    "url": "https://mcp.atlassian.com/v1/sse"
  }
}
```

`claude.json` is mounted from the host at runtime, so changes take effect on the next container start — no image rebuild required.

## Project-level servers
Add a `.mcp.json` file at the root of your project repository. Claude Code picks it up automatically from the mounted workspace. These are scoped to that repo and are typically checked in.

## GitHub MCP

The `gh` CLI is intentionally **not** installed in the container. GitHub access goes through the remote GitHub MCP server instead, configured in `claude.json`:

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

The token is not stored in `claude.json`; the config references `${MCP_GH_BEARER}`, which Claude Code expands from the container environment. `run.sh` passes `--env MCP_GH_BEARER` through from your host shell, so export `MCP_GH_BEARER` before running (see [Shell profile alias](../README.md#shell-profile-alias) for pulling it from the macOS Keychain). The non-standard variable name is deliberate — it avoids the well-known `GH_TOKEN`/`GITHUB_TOKEN` names that opportunistic secret scanners grep for. This is a minor convenience, not a security control; the real protections are the read-only token scope and the outbound allowlist.

## Chrome DevTools MCP

Chromium is pre-installed in the container image (`CHROME_BIN=/usr/bin/chromium`), so Chrome DevTools MCP works without any extra packages. Running Chrome inside the container — rather than pointing at a host Chrome — means every request the browser makes is subject to the same iptables egress rules as everything else.

Add this to the `mcpServers` object in your `claude.json`:

```json
"chrome-devtools": {
  "command": "npx",
  "args": [
    "-y", "chrome-devtools-mcp@latest",
    "--headless", "--isolated",
    "--no-sandbox", "--disable-setuid-sandbox",
    "--executablePath", "/usr/bin/chromium"
  ]
}
```

`--no-sandbox` is required because the container runs as root; it is orthogonal to network egress — the iptables allowlist still governs every packet. `--isolated` gives each run a throwaway user-data-dir, which keeps sessions clean.

**Firewall notes:**
- Loopback is already allowed in `init-firewall.sh`, so Chrome can reach an app at `http://localhost:PORT`.
- Any external domains the loaded page fetches (fonts, CDNs, APIs) must be in `allowed-domains.txt`. A page that renders incompletely is often the allowlist doing its job, not a Chrome bug.
