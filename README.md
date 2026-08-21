[![Tests](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml/badge.svg)](https://github.com/MrOggy85/claude-in-docker/actions/workflows/test.yml)
[![Image](https://github.com/MrOggy85/claude-in-docker/actions/workflows/image.yml/badge.svg)](https://github.com/MrOggy85/claude-in-docker/actions/workflows/image.yml)

# Claude Code in Docker Container

One Claude Code login, shared across every project. `cd` into any repo and run
`run.sh`. Outbound network is locked to a hostname allowlist by default, so a 
compromised dependency can't phone home. It assumes you are on macOS.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/b55b3975-9adf-4c28-9778-fdb799f64d6c" />

It is **not** an air-gapped, 100% secure setup — see [Known Attack Vectors](docs/attack-vectors.md)
for what is and isn't mitigated. This is a solution to reduce the obvious risks —
both from within the container and from outside it. Inside, we run a
non-deterministic AI agent we cannot fully trust; this adds guard rails around
it. Also running third-party code from npm etc, will be executed in this sandbox, behind a firewall, instead of your host. 
From outside, if your host gets pwned, your conversations and credentials
here won't be trivially reachable to a non-determined attacker.

> You don't have to run faster than the bear to get away. You just have to run faster than the guy next to you.

## Why this instead of...

| | claude-in-docker | Official Anthropic devcontainer | Bare host |
|---|---|---|---|
| Login | One login, shared across every project | Per devcontainer / Codespace | One login |
| Per-project setup | None — `cd` and run | Add `.devcontainer/` to every repo | None |
| Works from | Any terminal | IDE / Codespaces-first | Any terminal |
| Outbound egress | Hostname allowlist, on by default | Firewall reference exists, but opt-in and VS Code/Codespaces-bound | Unrestricted |
| HTTPS visibility | Decrypted and logged by URL at the proxy | No — CONNECT hostname only | None |
| `node_modules` on host disk | No — volume-backed by default | Yes | Yes |
| Credential / hook guards | Yes (settings, MCP token) | No | No |

Full breakdown, including claudebox and lightweight Dockerfile recipes: [How This
Compares to Alternatives](docs/comparison.md) and [Devcontainers
Alternative](docs/devcontainers.md).

## Prerequisites
- docker

## Quickstart

```bash
make init                        # seed your config in ~/.config/claude-in-docker/
cd your-project                  # any directory — no .devcontainer/ needed
~/code/claude-in-docker/run.sh   # builds the image on first run, then drops you into claude
```

Run `/login` once inside `claude` — the credential is saved to your config
directory and shared across every project from then on. See [Shell profile
alias](#shell-profile-alias) below to invoke `claude` from any directory
without the full path.

See [Setup](#setup) below for what `make init` creates and how to customize it.

## Setup

**tl;dr** Run `make init`

This copies every template in `templates/` into your **config directory** —
`~/.config/claude-in-docker/` by default (override with `CLAUDE_DOCKER_CONFIG_DIR`,
or point `XDG_CONFIG_HOME` elsewhere) — in one step; existing files are left
untouched, and the repo itself stays clean. Then edit the copies. List and inspect
them any time with `./cid list` / `./cid show <file>`. `cid` also **edits** the
egress allowlists in place — `cid domains add <host>` / `cid domains rm <host>`
— so you rarely need to open the files by hand. See [The `cid` config CLI](docs/config-cli.md).

All of the following files live in the config directory and are your personal files:

- `settings.json` add your own settings here that will be used by Claude Code
- `claude.json` contains onboarding state and your user-level MCP server config
- `container-CLAUDE.md` add your personal instructions for Claude Code here; mounted into the container as `~/.claude/CLAUDE.md` (user-global). Distinct from the repo's own `CLAUDE.md`, which holds project instructions for working on this tool.
- `allowed-domains.txt` domains listed here are the only outbound destinations the container can reach. It is the allowlist enforced by the shared Squid egress proxy (read live — edits apply within ~2s, no image rebuild). See [Centralized Egress Proxy](docs/egress-proxy.md) for how egress filtering works.
- `splice-domains.txt` hosts the proxy tunnels **without** decrypting. Everything else is decrypted and logged by URL; list a host here when its client pins certificates. Edit with `./cid splice add|rm <host>`. See [TLS Inspection](docs/tls-inspection.md).
- `ca/ca.key` + `ca/ca.crt` the CA the proxy signs decrypted TLS with, created by `make ca` (part of `make init`). The key is mounted only into the proxy container, never into a Claude container; the certificate is baked into the image's trust store. `run.sh` refuses to start without it. Inspect with `./cid ca`.
- `.gitconfig` set your git `user.name` / `user.email` here.
- `.gitignore_global` optional global (user-level) gitignore; mounted read-only at `~/.config/git/ignore`, which git reads automatically (no `.gitconfig` entry needed). Patterns apply to every repo you work in inside the container.
- `.env` arbitrary `KEY=VALUE` environment variables injected into the container via `docker --env-file`. Created (comment-only) by `make init` and required — `run.sh` aborts with a `make init` pointer if it is missing — but may safely stay empty. See [Passing environment variables](docs/passing-env-vars.md).

Two files stay **in the repo** (not the config dir), because Docker's build context is
the repo directory and both are `COPY`'d into the image: `install_additional_packages.sh`,
which runs as root at build time — add commands here to install extra tools a workflow
needs (e.g. Deno), then rebuild — and `egress-ca.crt`, the public half of the CA above,
which `run.sh` copies in for you on every run.

Per-project overrides (a per-repo `allowed-domains.txt`, `.env`, `container-CLAUDE.md`,
`mcp-servers.json`, or `install_additional_packages.sh`) live under
`<config-dir>/projects/<key>/`, created automatically the first time you run in a
project. Find the right directory with `./cid project`, see the effective egress
allowlist with `./cid domains`, and add/remove entries with `./cid domains add|rm
<host>` (per-project by default, or `-g` for the shared baseline).

`claude.json` is always per-project (not an opt-in override like the files above):
`run.sh` seeds `<config-dir>/projects/<key>/claude.json` from the global file the
first time it sees a project, then mounts that private copy. Claude Code keys
trust-dialog acceptance and MCP-server approvals in this file by working-directory
path, and every project mounts at the same in-container path — a single shared
file would let one project's approvals silently apply to an unrelated one. See
[Known Attack Vectors](docs/attack-vectors.md#shared-claudejson-collapses-per-project-trust-state-mitigated).

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

Any arguments you pass are forwarded verbatim to `claude` (e.g. `run.sh --model opus "fix the bug"`). `settings.json` is mounted read-only, so slash commands that persist a setting (`/effort`) fail with `EBUSY` — use the equivalent flag instead; see [Changing Settings for One Session](docs/session-settings.md).

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

- [The `cid` config CLI](docs/config-cli.md) — inspect config and edit the allowlists (`cid domains add|rm`, `cid containers add|rm`, per-project or `-g` baseline) without hand-editing files; put it on `$PATH` and ships zsh completion
- [Centralized Egress Proxy](docs/egress-proxy.md) — the network boundary: every container egresses through one shared Squid proxy that filters by hostname per project
- [TLS Inspection](docs/tls-inspection.md) — the proxy decrypts HTTPS with a local CA: setup, rotation, which runtimes need pointing at it, and how to exempt a host
- [Threat Model](docs/threat-model.md) — one-page summary of what this protects against and what it doesn't, plus how to [report a vulnerability](SECURITY.md)
- [Known Attack Vectors](docs/attack-vectors.md) — the full vector-by-vector detail: what's mitigated (project-settings/permissions guard, MCP token, egress) and what isn't
- [MCP Servers](docs/mcp-servers.md) — configure user-level, project-level, and GitHub MCP servers
- [Mounting extra folders](docs/mounting-extra-folders.md) — make additional host folders visible inside the container via `CLAUDE_MOUNTS`
- [Publishing ports](docs/publishing-ports.md) — expose a server running inside the container to the host via `CLAUDE_PORTS`
- [Host-outbound ports](docs/host-outbound-ports.md) — let the container connect out to host services via `CLAUDE_HOST_OUTBOUND_PORTS` (generalizes `SOUND_PORT`)
- [Sandbox self-awareness](docs/sandbox-info.md) — an on-demand `sandbox` skill telling the session which host port maps to its container port (the host port differs per session, and a host-side browser needs it), what is mounted, and why a request was blocked; `CLAUDE_SANDBOX_INFO=0` to disable
- [Chrome DevTools MCP](docs/chrome-devtools-mcp.md) — drive a real Chrome on the host from the container via the `chrome-devtools-mcp` server, bridged over HTTP (host MCP + `CLAUDE_HOST_OUTBOUND_PORTS`)
- [Host docker bridge](docs/docker-bridge.md) — read-only `docker ps` / `logs` / `stats` for containers you allowlist, via a token-authenticated host MCP bridge instead of the Docker socket (`CLAUDE_DOCKER_BRIDGE=1`); off by default
- [Passing environment variables](docs/passing-env-vars.md) — inject arbitrary env vars into the container via a `.env` file in the config dir
- [Per-project launch config](docs/per-project-env.md) — keep per-repo mounts, ports, and secrets in a gitignored `.claude-env` sourced at launch
- [Volume-backed paths](docs/volume-backed-paths.md) — `node_modules` and the pnpm store are kept off the host disk by default (named volumes); add paths with `CLAUDE_VOLUME_PATHS`, opt out with `SKIP_CLAUDE_VOLUME_PATHS`
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

## License

Licensed under the [Apache License 2.0](LICENSE).

This applies to the wrapper in this repository only. The tools it installs into
the image — Claude Code itself (`@anthropic-ai/claude-code`) and the other
packages in `package.json` / `install_additional_packages.sh` — keep their own
licences and terms.
