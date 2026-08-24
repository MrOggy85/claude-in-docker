---
name: sandbox
description: Report this session's sandbox shape — which host port maps to a container port, what is mounted from the host, which paths are Docker volumes, what is installed and how to get more, and why network requests get blocked. Read this BEFORE reaching for apt-get, sudo, or any install command, and whenever a command is "not found" — apt-get cannot succeed here. Also use when you need the URL the user (or a host-side browser such as the chrome-devtools MCP server) must open to reach a server you started, when a fetch/curl/install fails on the network, when a file you wrote is not visible on the host, or when the user asks what is reachable from where. The values change per session, so read them rather than assuming.
---

# This session's sandbox

Claude Code runs in a Docker container. Ports, mounts and volumes are fixed when
the container starts and differ between sessions — never assume them.

## Get the facts

```bash
~/.claude/skills/sandbox/sandbox-info.sh
```

Plain markdown on stdout, from environment variables only: no network, no writes,
nothing to clean up. Re-run it any time; it is cheap.

## How to read it

- **Ports published to the host (inbound).** Each line pairs a container port with
  the host endpoint that forwards to it (e.g. container `3000/tcp` ← host
  `localhost:9345`). The two numbers are usually different.
  - From inside the container use the **container** port: `curl http://localhost:3000`.
  - For anything on the **host** use the host endpoint: the URL you give the user,
    and — where the output lists a chrome-devtools bridge — every `chrome-devtools`
    MCP call. That server drives a browser on the host, so pointing it at the
    container port hits the host's own port instead of your server, which usually
    looks like a connection refused or, worse, someone else's app.
  - "None" means nothing you listen on is reachable from the host. Say so and give
    the user the relaunch command the output prints; you cannot publish a port
    from in here.
- **Host services (outbound).** The `host.docker.internal` ports you may dial,
  labelled where known. Anything not listed is firewalled off.
- **Everything else on the network.** Non-host traffic passes a proxy that permits
  only allowlisted domains. Treat a blocked request as policy: report the exact
  hostname and tell the user to run `cid domains add <host>` on the host. Do not
  try another host, port, mirror, registry or proxy to get around it.
- **TLS.** That proxy terminates HTTPS with its own CA, which this image trusts, so
  certificates here are issued by `claude-in-docker egress CA` **by design** — not an
  attack, and not a reason to reach for `--insecure`,
  `NODE_TLS_REJECT_UNAUTHORIZED=0` or `verify=False`. A certificate error means one of
  two things, both worth reporting verbatim: a client that pins certificates (the
  user's fix is `cid skip-decryption add <host>`), or a runtime shipping its own CA
  bundle that needs pointing at `$SSL_CERT_FILE`.
- **Files.** The repo's host path (use it when telling the user which folder to
  open) plus extra mounts, and the volume-backed paths — those exist only inside
  the container, so a `node_modules` you install is invisible to host tooling.
- **Installing packages.** Which package managers work, and the host file the
  user must edit for anything else.

## Toolchain

The base image ships git, ripgrep, `fd`, `bat`, jq, curl, wget, python3, `uv`,
Node via nvm, sqlite3, shellcheck, yamllint, make, tree, zip/unzip and an editor.
A per-project install script may have added more — confirm with `command -v`.

What you can install yourself, with no permission and no rebuild:

- **Node** — `npm i -g <pkg>`; npm's prefix is the writable nvm directory.
  `nvm install <ver>` also works. `nvm use` affects only the shell it runs in and
  each Bash call is a fresh shell, so a project's `.nvmrc` needs chaining:
  `nvm use && npm test`.
- **Python** — `uv`, not pip: there is no `pip` and no working `python3 -m venv`
  (no `ensurepip`). `uv venv` and `uv pip install` replace both; `uv run <script>`
  needs neither.

Anything else cannot be installed from in here. See the script's
"Installing packages" section for why, and for the host file the user edits.

## Rules

- Report facts from the script, not guesses; if a value is absent, say it is absent.
- Never try to install your way past a missing tool. Do not run `apt-get`, do not
  retry it under `sudo`, and do not look for a portable binary to drop somewhere
  writable. Name the tool, give the user the host-side edit, and carry on with
  what is installed.
- Never print or echo secret values (`DOCKER_BRIDGE_TOKEN`, `MCP_GH_BEARER`, the
  proxy URL's credentials). The script reports secrets as present/absent only —
  keep it that way.
