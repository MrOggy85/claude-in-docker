# Claude Code in Docker Container

This is a solution for running claude code in a docker container. It assumes you are in MacOS.

## Prerequisites
- docker
- Claude Code Oauth Token
  - saved in Apple keychain under the name `claude_ouath_token`

## Setup
- copy `settings.json.example` to `settings.json`
  - `settings.json` is gitignored. Add your own settings here that will be used by Claude Code
- copy `claude.json.example` to `claude.json`
  - `claude.json` is gitignored. Contains onboarding state and your user-level MCP server config
- copy `CLAUDE.md.example` to `CLAUDE.md`
  - `CLAUDE.md` is gitignored. Add your personal instructions for Claude Code here
- copy `allowed-domains.txt.example` to `allowed-domains.txt`
  - `allowed-domains.txt` is gitignored. Domains listed here are baked into the Docker image and are the only outbound destinations the container can reach. Rebuild the image after changing this file.

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

## Additional Information

See [docs/index.md](docs/index.md) for guides on optional features.
