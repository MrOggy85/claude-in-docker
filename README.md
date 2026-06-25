[![Tests](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml/badge.svg)](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml)

# Claude Code in Docker Container

This is a solution for running Claude Code in a Docker container. It assumes you are on macOS.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/d0eee09d-e1dd-4e51-83a8-de675c92f3ad" />


![Two people being chased by a bear](docs/images/bear-chase.svg)

*Composite of [OpenMoji](https://openmoji.org/) artwork (emoji `1F43B` and `1F3C3`), [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) — runners and bear mirrored/scaled and arranged into a scene. See [`docs/images/ATTRIBUTION.md`](docs/images/ATTRIBUTION.md).*

It is **not** an air-gapped, 100% secure setup. It is a solution to mitigate the obvious risks — both from within the container and from outside it. Inside, we run a non-deterministic AI agent we cannot fully trust; this adds guard rails around it. From outside, if your host gets pwned, your conversations and credentials here won't be trivially reachable to a non-determined attacker.

> You don't have to run faster than the bear to get away. You just have to run faster than the guy next to you.

## Prerequisites
- docker

## Setup

**tl;dr**
Run `make init`

This copies every template in `templates/` to its target in the repo root in one step (existing files are left untouched), then edit the copies.
All of the following files are gitignored and your personal files:

- `settings.json` add your own settings here that will be used by Claude Code
- `claude.json` contains onboarding state and your user-level MCP server config
- `container-CLAUDE.md` add your personal instructions for Claude Code here; mounted into the container as `~/.claude/CLAUDE.md` (user-global). Distinct from the repo's own `CLAUDE.md`, which holds project instructions for working on this tool.
- `allowed-domains.txt` domains listed here are baked into the Docker image and are the only outbound destinations the container can reach. Rebuild the image after changing this file. See [Outbound Firewall](docs/firewall.md) for how the allowlist and IP-rotation handling work.
- `.gitconfig` set your git `user.name` / `user.email` here.
- `.gitignore_global` optional global (user-level) gitignore; mounted read-only at `~/.config/git/ignore`, which git reads automatically (no `.gitconfig` entry needed). Patterns apply to every repo you work in inside the container.
- `install_additional_packages.sh` runs at image build time as root; add commands here to install extra tools a workflow needs (e.g. Deno). Rebuild the image after changing this file.
- `.env` optional; arbitrary `KEY=VALUE` environment variables injected into the container via `docker --env-file`. See [Passing environment variables](docs/passing-env-vars.md).

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

Any arguments you pass are forwarded verbatim to `claude` (e.g. `run.sh --model opus "fix the bug"`).

> **Note:** Running `run.sh` directly from your home directory (`~`) is blocked on purpose. Doing so would mount your entire home directory into the container, defeating the sandboxing. `cd` into a project subdirectory first.

## Authentication

`make init` seeds an empty `.credentials.json` (next to `run.sh`, gitignored) which `run.sh`
bind-mounts into the container. The first time you run Claude Code, log in with the `/login`
command and complete the OAuth flow; your credentials are written to that file, so a single
login is shared across **every** project you run in the container — you only need to do it once.

To force a re-login, delete `.credentials.json` and re-run `make init` to recreate it empty.

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
- [Publishing ports](docs/publishing-ports.md) — expose a server running inside the container to the host via `CLAUDE_PORTS`
- [Passing environment variables](docs/passing-env-vars.md) — inject arbitrary env vars into the container via a gitignored `.env` file
- [Per-project launch config](docs/per-project-env.md) — keep per-repo mounts, ports, and secrets in a gitignored `.claude-env` sourced at launch
- [Volume-backed paths](docs/volume-backed-paths.md) — `node_modules` is kept off the host disk by default (named volumes); add paths with `CLAUDE_VOLUME_PATHS`, opt out with `SKIP_CLAUDE_VOLUME_PATHS`
- [Installing additional packages](docs/installing-packages.md) — install extra tools a workflow needs (e.g. Deno) via `install_additional_packages.sh`
- [Tracking usage (ccusage)](docs/tracking-usage.md) — report token usage across all projects with `ccusage`, despite logs living in Docker volumes
- [Environment variables](docs/environment-variables.md) — reference for every environment variable this project reads or sets

## Additional Information

See [docs/index.md](docs/index.md) for guides on optional features.

## Contributors 

- [j-svensmark](https://github.com/j-svensmark)
- [a-gravy](https://github.com/a-gravy)

## Credits

This solution is heavily inspired by Anthropic's own approach to running Claude Code in a [devcontainer](https://containers.dev/):

- [Anthropic's devcontainer Dockerfile](https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile)
- [Claude Code devcontainer docs](https://code.claude.com/docs/en/devcontainer)
