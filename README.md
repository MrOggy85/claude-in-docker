[![Tests](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml/badge.svg)](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml)

# Claude Code in Docker Container

This is a solution for running Claude Code in a Docker container. It assumes you are on macOS.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/b55b3975-9adf-4c28-9778-fdb799f64d6c" />


It is **not** an air-gapped, 100% secure setup. It is a solution to mitigate the obvious risks — both from within the container and from outside it. Inside, we run a non-deterministic AI agent we cannot fully trust; this adds guard rails around it. From outside, if your host gets pwned, your conversations and credentials here won't be trivially reachable to a non-determined attacker.

> You don't have to run faster than the bear to get away. You just have to run faster than the guy next to you.

## Prerequisites
- docker

## Setup

**tl;dr**
Run `make init`

This copies every template in `templates/` into your **config directory** —
`~/.config/claude-in-docker/` by default (override with `CLAUDE_DOCKER_CONFIG_DIR`,
or point `XDG_CONFIG_HOME` elsewhere) — in one step; existing files are left
untouched, and the repo itself stays clean. Then edit the copies. List and inspect
them any time with `./cid list` / `./cid show <file>`. `cid` also **edits** the
egress allowlists in place — `cid domains add <host>` / `cid domains rm <host>`
— so you rarely need to open the files by hand. See [The `cid` config CLI](docs/config-cli.md).

> **Upgrading?** Older versions kept these files gitignored in the repo root. Run
> `make migrate` once to move your config — and your per-project dirs — into the
> config directory. It is non-destructive (never overwrites anything already there).

All of the following files live in the config directory and are your personal files:

- `settings.json` add your own settings here that will be used by Claude Code
- `claude.json` contains onboarding state and your user-level MCP server config
- `container-CLAUDE.md` add your personal instructions for Claude Code here; mounted into the container as `~/.claude/CLAUDE.md` (user-global). Distinct from the repo's own `CLAUDE.md`, which holds project instructions for working on this tool.
- `allowed-domains.txt` domains listed here are the only outbound destinations the container can reach. It is the allowlist enforced by the shared Squid egress proxy (read live — edits apply within ~30s, no image rebuild). See [Centralized Egress Proxy](docs/egress-proxy.md) for how egress filtering works.
- `.gitconfig` set your git `user.name` / `user.email` here.
- `.gitignore_global` optional global (user-level) gitignore; mounted read-only at `~/.config/git/ignore`, which git reads automatically (no `.gitconfig` entry needed). Patterns apply to every repo you work in inside the container.
- `.env` arbitrary `KEY=VALUE` environment variables injected into the container via `docker --env-file`. Created (comment-only) by `make init` and required — `run.sh` aborts with a `make init` pointer if it is missing — but may safely stay empty. See [Passing environment variables](docs/passing-env-vars.md).

One file stays **in the repo** (not the config dir): `install_additional_packages.sh`.
It runs at image build time as root — add commands here to install extra tools a
workflow needs (e.g. Deno), then rebuild the image. It must stay in the repo because
it is `COPY`'d into the image and Docker's build context is the repo directory.

Per-project overrides (a per-repo `allowed-domains.txt`, `.env`, `container-CLAUDE.md`,
`mcp-servers.json`, or `install_additional_packages.sh`) live under
`<config-dir>/projects/<key>/`, created automatically the first time you run in a
project. Find the right directory with `./cid project`, see the effective egress
allowlist with `./cid domains`, and add/remove entries with `./cid domains add|rm
<host>` (per-project by default, or `-g` for the shared baseline).

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

Any arguments you pass are forwarded verbatim to `claude` (e.g. `run.sh --model opus "fix the bug"`).

> **Note:** Running `run.sh` directly from your home directory (`~`) is blocked on purpose. Doing so would mount your entire home directory into the container, defeating the sandboxing. `cd` into a project subdirectory first.

## Authentication

`make init` seeds an empty `.credentials.json` in the config directory
(`~/.config/claude-in-docker/` by default) which `run.sh` bind-mounts into the
container. The first time you run Claude Code, log in with the `/login` command and
complete the OAuth flow; your credentials are written to that file, so a single
login is shared across **every** project you run in the container — you only need to do it once.

To force a re-login, delete `.credentials.json` from the config directory and re-run `make init` to recreate it empty.

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

- [The `cid` config CLI](docs/config-cli.md) — inspect config and add/remove egress-allowlist domains (`cid domains add|rm`, per-project or `-g` baseline) without hand-editing files; put it on `$PATH` and ships zsh completion
- [MCP Servers](docs/mcp-servers.md) — configure user-level, project-level, and GitHub MCP servers
- [Mounting extra folders](docs/mounting-extra-folders.md) — make additional host folders visible inside the container via `CLAUDE_MOUNTS`
- [Publishing ports](docs/publishing-ports.md) — expose a server running inside the container to the host via `CLAUDE_PORTS`
- [Host-outbound ports](docs/host-outbound-ports.md) — let the container connect out to host services via `CLAUDE_HOST_OUTBOUND_PORTS` (generalizes `SOUND_PORT`)
- [Chrome DevTools MCP](docs/chrome-devtools-mcp.md) — drive a real Chrome on the host from the container via the `chrome-devtools-mcp` server, bridged over HTTP (host MCP + `CLAUDE_HOST_OUTBOUND_PORTS`)
- [Passing environment variables](docs/passing-env-vars.md) — inject arbitrary env vars into the container via a `.env` file in the config dir
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
