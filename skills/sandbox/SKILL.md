---
name: sandbox
description: Report this session's sandbox shape — which host port maps to a container port, what is mounted from the host, which paths are Docker volumes, and why network requests get blocked. Use when you need the URL the user (or a host-side browser such as the chrome-devtools MCP server) must open to reach a server you started, when a fetch/curl/install fails on the network, when a file you wrote is not visible on the host, or when the user asks what is reachable from where. The values change per session, so read them rather than assuming.
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
- **Files.** The repo's host path (use it when telling the user which folder to
  open) plus extra mounts, and the volume-backed paths — those exist only inside
  the container, so a `node_modules` you install is invisible to host tooling.

## Rules

- Report facts from the script, not guesses; if a value is absent, say it is absent.
- Never print or echo secret values (`DOCKER_BRIDGE_TOKEN`, `MCP_GH_BEARER`, the
  proxy URL's credentials). The script reports secrets as present/absent only —
  keep it that way.
