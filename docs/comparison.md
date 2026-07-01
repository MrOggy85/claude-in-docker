# How This Compares to Alternatives

There are many ways to run Claude Code inside Docker. They tend to cluster at
two poles: **lightweight recipes** (a Dockerfile and a `docker run` line from a
blog post) and **heavy frameworks** that own your whole per-project workflow.
`claude-in-docker` sits deliberately in between — it optimizes for *host
parity* (it should feel almost the same as bare-host Claude) plus a small set of
*sharp security guarantees*, and stays a thin, readable `run.sh` wrapper rather
than a framework.

This page situates the project against the broader field so you can decide what
fits. For the dedicated deep-dive on running Claude in a Dev Container (including
the Codespaces / Squid-sidecar path), see
[Devcontainers Alternative](devcontainers.md).

---

## vs. the devcontainer convention

The [Dev Container](https://containers.dev/) spec covers the "feel like home"
primitives well:

- non-root user matched to the host UID (`remoteUser` + `updateRemoteUserUID`)
- git and ssh credential forwarding
- personal `dotfiles`
- `forwardPorts`
- composable `features` for toolchains
- bind mounts and environment variables

It covers **none** of the Claude-specific hardening this project adds, and it is
**IDE-centric and per-repo**: you add a `.devcontainer/` to every repository and
typically drive it from VS Code or Codespaces.

> **Nuance:** Anthropic ships an official `.devcontainer` *reference* for Claude
> Code that includes a firewall `init-firewall.sh` — almost certainly the
> inspiration for this project's firewall. But that is one specific reference
> config, not part of the devcontainer *convention*, and it is bound to VS Code /
> Codespaces. In Codespaces it can't even use iptables (no `NET_ADMIN`), so it
> falls back to a Squid sidecar.

See [Devcontainers Alternative](devcontainers.md) for the full `run.sh`-vs-
devcontainer feature table and the Squid-sidecar setup.

---

## vs. lightweight recipes

The common blog-post pattern is a Dockerfile plus `docker run`, a bind mount of
the project, and a copy of your credentials into the container. That gets you
isolation and not much else. It is a strict subset of this project — it omits:

- a default-deny egress firewall with a hostname allowlist
- volume-backed package isolation (keeping `node_modules` off the host disk)
- the credential / MCP-token and project-settings guards
- usage accounting
- a multi-project single-login model

`claude-in-docker` is essentially what one of those recipes grows into once you
care about untrusted-package egress and not re-authenticating per repository.

---

## vs. claudebox

[claudebox](https://github.com/RchGrav/claudebox) is a heavier, opinionated
framework. It ships 15+ language profiles, interactive menus, a task engine,
tmux integration, an oh-my-zsh/powerline shell, and a `claudebox` command surface
(`install`, `save`, `allowlist`, …).

The two overlap on the fundamentals — per-project isolation, host-UID matching,
per-project firewall allowlists, and layer caching. The difference is
philosophical:

| | claudebox | claude-in-docker |
|---|---|---|
| Posture | Batteries-included framework | Thin, readable `run.sh` wrapper |
| In-container env | Rich, opinionated (zsh, profiles, tmux) | Minimal — your host config comes along |
| Owns your workflow | Yes — its own command surface | No — you just run `claude` |
| Primary goal | A great per-project dev environment | Bare-host parity + sharp guards |

claudebox owns and enriches a per-project development environment; this repo
deliberately adds *less* environment and focuses on preserving the bare-host
experience.

---

## What's genuinely differentiated here

These pieces are uncommon-to-absent in the alternatives above:

- **Read-only GitHub MCP token validation** — `guards/mcp-bearer-readonly.sh`
  aborts the run if the GitHub MCP token has write-capable scopes, so Claude
  can't mutate repos through it.
- **Project-settings / hooks consent gate** — `guards/project-settings.sh`
  prompts before honoring a repo's `.claude/settings.json` (which can register
  arbitrary hook commands).
- **Privacy-stripped usage sync** — `sync-volume.sh` / `usage.sh` copy only cost
  fields out of the session volume for `ccusage`; conversation text, tool I/O,
  and attachments never leave the volume.
- **Auto volume-backing of `node_modules`** — `run.sh` scans for every
  `package.json` (via `scripts/find-node-modules-paths.sh`) and backs each
  sibling `node_modules` with a named volume, keeping untrusted packages off the
  host disk by default.
- **Run-from-anywhere, one shared login, host identity** — a single `run.sh`
  works from any project directory with no per-repo `.devcontainer/`; one
  `/login` is shared across all projects, and the container carries your host
  git identity and config.

---

## Quick chooser

| Pick… | When |
|---|---|
| **A devcontainer** | You're IDE- or Codespaces-first and want colleagues to open a repo and have `claude` ready — and you accept a weaker (or sidecar-based) network boundary. See [Devcontainers Alternative](devcontainers.md). |
| **A lightweight recipe** | You just want quick isolation and don't need egress control, package isolation, the guards, or usage accounting. |
| **claudebox** | You want a batteries-included, per-project framework with profiles, menus, and a rich in-container shell. |
| **claude-in-docker** | You want terminal-first, bare-host parity (one login, host identity, run from anywhere) plus practical hardening — egress firewall, off-host packages, and the credential/settings guards. |
