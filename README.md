# Claude Code in Docker Container

This is a solution for running Claude Code in a Docker container. It assumes you are on macOS.

It is **not** an air-gapped, 100% secure setup. It is a solution to mitigate the obvious risks — both from within the container and from outside it. Inside, we run a non-deterministic AI agent we cannot fully trust; this adds guard rails around it. From outside, if your host gets pwned, your conversations and credentials here won't be trivially reachable to a non-determined attacker.

> You don't have to run faster than the bear to get away. You just have to run faster than the guy next to you.

## Prerequisites
- docker

## Setup
- copy `settings.json.example` to `settings.json`
  - `settings.json` is gitignored. Add your own settings here that will be used by Claude Code
- copy `claude.json.example` to `claude.json`
  - `claude.json` is gitignored. Contains onboarding state and your user-level MCP server config
- copy `CLAUDE.md.example` to `CLAUDE.md`
  - `CLAUDE.md` is gitignored. Add your personal instructions for Claude Code here
- copy `allowed-domains.txt.example` to `allowed-domains.txt`
  - `allowed-domains.txt` is gitignored. Domains listed here are baked into the Docker image and are the only outbound destinations the container can reach. Rebuild the image after changing this file.

## Authentication

The first time you run Claude Code, log in with the `/login` command and complete the OAuth
flow. Your credentials are written to `.credentials.json` (next to `run.sh`, gitignored) and
bind-mounted into the container, so a single login is shared across **every** project you run
in the container — you only need to do it once.

To force a re-login, delete `.credentials.json` (it is re-created empty on the next run).

## MCP Servers

### User-level servers
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

### Project-level servers
Add a `.mcp.json` file at the root of your project repository. Claude Code picks it up automatically from the mounted workspace. These are scoped to that repo and are typically checked in.

### GitHub MCP

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

The token is not stored in `claude.json`; the config references `${MCP_GH_BEARER}`, which Claude Code expands from the container environment. `run.sh` passes `--env MCP_GH_BEARER` through from your host shell, so export `MCP_GH_BEARER` before running (see [Shell profile alias](#shell-profile-alias) for pulling it from the macOS Keychain). The non-standard variable name is deliberate — it avoids the well-known `GH_TOKEN`/`GITHUB_TOKEN` names that opportunistic secret scanners grep for. This is a minor convenience, not a security control; the real protections are the read-only token scope and the outbound allowlist.

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

### Shell profile alias

Add this function to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.) so you can invoke `claude` from any directory without specifying the path — and so it overrides a locally installed `claude` binary if you have one:

```bash
function claude {
  ~/code/claude-in-docker/run.sh "$@"
}
```

Reload your shell (`source ~/.zshrc`) or open a new terminal, then run `claude` from any project directory.

#### Injecting `MCP_GH_BEARER` from the macOS Keychain

`run.sh` passes `--env MCP_GH_BEARER` through to the container for the [GitHub MCP](#github-mcp) server. Rather than hardcoding the token, store it in the Keychain once:

```bash
security add-generic-password -a "$USER" -s "github_pat" -w "github_pat_xxx"
```

Then have the alias read it at launch with a small helper, so the token only lives in the Keychain:

```bash
function keychain_get {
  local entry="$1"
  if [[ -z "$entry" ]]; then
    echo "Usage: keychain_get \"Entry Name\""
    return 1
  fi
  security find-generic-password -a "$USER" -s "$entry" -w
}

function claude {
  MCP_GH_BEARER="$(keychain_get "github_pat")" ~/code/claude-in-docker/run.sh "$@"
}
```

## Additional Information

See [docs/index.md](docs/index.md) for guides on optional features.
