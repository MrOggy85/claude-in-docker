# Claude Code in Docker Container

This is a solution for running Claude Code in a Docker container. It assumes you are on macOS.

It is **not** an air-gapped, 100% secure setup. It is a solution to mitigate the obvious risks — both from within the container and from outside it. Inside, we run a non-deterministic AI agent we cannot fully trust; this adds guard rails around it. From outside, if your host gets pwned, your conversations and credentials here won't be trivially reachable to a non-determined attacker.

> You don't have to run faster than the bear to get away. You just have to run faster than the guy next to you.

## Prerequisites
- docker

## Setup

**tl;dr**
Run `make init`

This copies every `*.example` template to its target in one step (existing files are left untouched), then edit the copies.
All of the following files are gitignored and your personal files:

- `settings.json` add your own settings here that will be used by Claude Code
- `claude.json` contains onboarding state and your user-level MCP server config
- `CLAUDE.md` add your personal instructions for Claude Code here
- `allowed-domains.txt` domains listed here are baked into the Docker image and are the only outbound destinations the container can reach. Rebuild the image after changing this file.
- `.gitconfig` set your git `user.name` / `user.email` here.
- `install_additional_packages.sh` runs at image build time as root; add commands here to install extra tools a workflow needs (e.g. Deno). Rebuild the image after changing this file.

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

Any arguments you pass are forwarded verbatim to `claude` (e.g. `run.sh --model opus "fix the bug"`).

## Authentication

The first time you run Claude Code, log in with the `/login` command and complete the OAuth
flow. Your credentials are written to `.credentials.json` (next to `run.sh`, gitignored) and
bind-mounted into the container, so a single login is shared across **every** project you run
in the container — you only need to do it once.

To force a re-login, delete `.credentials.json` (it is re-created empty on the next run).

### Shell profile alias

Add this function to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.) so you can invoke `claude` from any directory without specifying the path — and so it overrides a locally installed `claude` binary if you have one:

```bash
function claude {
  ~/code/claude-in-docker/run.sh "$@"
}
```

Reload your shell (`source ~/.zshrc`) or open a new terminal, then run `claude` from any project directory.

#### Injecting `MCP_GH_BEARER` from the macOS Keychain

`run.sh` passes `--env MCP_GH_BEARER` through to the container for the [GitHub MCP](docs/mcp-servers.md#github-mcp) server. Rather than hardcoding the token, store it in the Keychain once:

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

## Additional Features

- [MCP Servers](docs/mcp-servers.md) — configure user-level, project-level, and GitHub MCP servers
- [Mounting extra folders](docs/mounting-extra-folders.md) — make additional host folders visible inside the container via `CLAUDE_MOUNTS`
- [Tracking usage (ccusage)](docs/tracking-usage.md) — report token usage across all projects with `ccusage`, despite logs living in Docker volumes

## Additional Information

See [docs/index.md](docs/index.md) for guides on optional features.

## Credits

This solution is heavily inspired by Anthropic's own approach to running Claude Code in a [devcontainer](https://containers.dev/):

- [Anthropic's devcontainer Dockerfile](https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile)
- [Claude Code devcontainer docs](https://code.claude.com/docs/en/devcontainer)
