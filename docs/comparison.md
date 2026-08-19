# How This Compares to Alternatives

Ways to run Claude Code in Docker cluster at two poles: **lightweight recipes** (a Dockerfile and a
`docker run` line) and **heavy frameworks** that own your per-project workflow. `claude-in-docker`
sits between them, optimizing for *host parity* — it should feel like bare-host Claude — plus a
small set of sharp security guarantees, and stays a readable `run.sh` wrapper rather than a
framework.

For the deep-dive on Dev Containers (including the Codespaces / Squid-sidecar path), see
[Devcontainers Alternative](devcontainers.md).

## vs. the devcontainer convention

The [Dev Container](https://containers.dev/) spec covers the "feel like home" primitives well:
non-root user matched to the host UID (`remoteUser` + `updateRemoteUserUID`), git/ssh credential
forwarding, personal `dotfiles`, `forwardPorts`, composable `features`, bind mounts and environment
variables.

It covers **none** of the Claude-specific hardening here, and it is **IDE-centric and per-repo**:
you add a `.devcontainer/` to every repository and typically drive it from VS Code or Codespaces.

> **Nuance:** Anthropic ships an official `.devcontainer` *reference* for Claude Code including a
> firewall `init-firewall.sh` — almost certainly this project's inspiration. But that is one
> reference config, not part of the devcontainer *convention*, and it is bound to VS Code /
> Codespaces. In Codespaces it can't use iptables (no `NET_ADMIN`) and falls back to a Squid sidecar.

See [Devcontainers Alternative](devcontainers.md) for the full feature table and sidecar setup.

## vs. lightweight recipes

The blog-post pattern — a Dockerfile, `docker run`, a bind mount, and a copy of your credentials —
gets you isolation and little else. It is a strict subset of this project, omitting:

- a default-deny egress firewall with a hostname allowlist
- volume-backed package isolation (`node_modules` off the host disk)
- the credential / MCP-token and project-settings guards
- usage accounting
- a multi-project single-login model

`claude-in-docker` is what one of those recipes grows into once you care about untrusted-package
egress and not re-authenticating per repository.

## vs. claudebox

[claudebox](https://github.com/RchGrav/claudebox) is a heavier, opinionated framework: 15+ language
profiles, interactive menus, a task engine, tmux integration, an oh-my-zsh/powerline shell, and its
own command surface (`install`, `save`, `allowlist`, …).

They overlap on fundamentals — per-project isolation, host-UID matching, per-project firewall
allowlists, layer caching. The difference is philosophical:

| | claudebox | claude-in-docker |
|---|---|---|
| Posture | Batteries-included framework | Thin, readable `run.sh` wrapper |
| In-container env | Rich, opinionated (zsh, profiles, tmux) | Minimal — your host config comes along |
| Owns your workflow | Yes — its own command surface | No — you just run `claude` |
| Primary goal | A great per-project dev environment | Bare-host parity + sharp guards |

## What's genuinely differentiated here

Uncommon-to-absent in the alternatives above:

- **No-code-push GitHub MCP token validation** — `guards/mcp-bearer-no-push.sh` aborts if the token
  can push code (Contents:write). Issues / Pull requests write is permitted.
- **Project-settings / hooks consent gate** — `guards/project-settings.sh` prompts before honoring a
  repo's `.claude/settings.json`, which can register arbitrary hook commands.
- **Privacy-stripped usage sync** — `sync-volume.sh` / `usage.sh` copy only cost fields out of the
  session volume; conversation text, tool I/O, and attachments never leave it.
- **Auto volume-backing of `node_modules`** — `run.sh` scans for every `package.json` and backs each
  sibling `node_modules` with a named volume, keeping untrusted packages off the host disk.
- **Run-from-anywhere, one shared login, host identity** — one `run.sh` works from any project
  directory with no per-repo `.devcontainer/`; one `/login` covers every project, and the container
  carries your host git identity and config.

## Quick chooser

| Pick… | When |
|---|---|
| **A devcontainer** | You're IDE- or Codespaces-first and want colleagues to open a repo with `claude` ready — and you accept a weaker (or sidecar-based) network boundary. See [Devcontainers Alternative](devcontainers.md). |
| **A lightweight recipe** | You want quick isolation and don't need egress control, package isolation, the guards, or usage accounting. |
| **claudebox** | You want a batteries-included per-project framework with profiles, menus, and a rich in-container shell. |
| **claude-in-docker** | You want terminal-first bare-host parity (one login, host identity, run from anywhere) plus practical hardening — egress firewall, off-host packages, credential/settings guards. |
