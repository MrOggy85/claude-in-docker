# Sandbox Self-Awareness

Some facts about the container exist only **outside** it. The important one is the host side of a
published port:

```bash
CLAUDE_PORTS="9345:3000" ./run.sh
```

The container sees a server on `3000`; the host reaches it on `9345`. `run.sh` passes only the
container-side port inward, for the firewall.

That gap causes wrong answers. The [chrome-devtools MCP server](chrome-devtools-mcp.md) drives a
browser **on the host**, so `http://localhost:3000` hits the host's own port 3000, not your dev
server — same for any URL handed to the user. And since the host port varies per session, it can't
be written into config once.

## What ships

An on-demand `sandbox` skill, mounted read-only at `~/.claude/skills/sandbox`:

| File | Role |
| --- | --- |
| [`skills/sandbox/SKILL.md`](../skills/sandbox/SKILL.md) | when to consult it, and how to read the output |
| [`skills/sandbox/sandbox-info.sh`](../skills/sandbox/sandbox-info.sh) | prints the report; reads environment variables only |

It is **on demand by design**: nothing is injected into context and no `SessionStart` hook is
installed. Only the skill's one-line description is always present; the facts are fetched when they
matter (a server needs a URL, a request got blocked, a written file is missing on the host).

Run it yourself to see exactly what a session is told:

```bash
# inside a session
~/.claude/skills/sandbox/sandbox-info.sh
```

It reports, in order:

- **Files** — the repo's host path ↔ `/home/dev/repo`, extra `CLAUDE_MOUNTS` targets, and the
  [volume-backed paths](volume-backed-paths.md) that exist only inside the container.
- **Ports published to the host (inbound)** — each container port with the host endpoint forwarding
  to it, or an explicit "none" plus the `CLAUDE_PORTS` relaunch route. See [Publishing
  Ports](publishing-ports.md).
- **Host services (outbound)** — the `host.docker.internal` ports the firewall opened, labelled
  where `run.sh` knows their purpose. See [Host-Outbound Ports](host-outbound-ports.md).
- **Everything else on the network** — egress passes the [Squid allowlist](egress-proxy.md), so a
  blocked request is policy: the skill reports the hostname and points at `cid domains add <host>`
  rather than trying another route.
- **Using this** — container port for in-container `curl`, host endpoint for anything on the host.
  The chrome-devtools bridge is named only when its port is open, so no session is pointed at a
  server it cannot reach.

## How it stays correct across parallel sessions

`sandbox-info.sh` is a pure function of the environment, and the environment is per container.
`run.sh` (step 3g) forwards `CONTAINER_PUBLISHED_PORTS`, `CONTAINER_HOST_PORT_LABELS`,
`CONTAINER_EXTRA_MOUNTS` and `CONTAINER_VOLUME_PATHS` alongside the `CLAUDE_HOST_PROJECT_DIR` and
`CONTAINER_HOST_OUTBOUND_PORTS` it already set. Two sessions in one project with different
`CLAUDE_PORTS` each report their own mapping, with nothing generated on the host to clean up.

The host side of a mapping is computed once, in
[`scripts/extra-ports.sh`](../scripts/extra-ports.sh), emitted as a third tab-separated field next
to the publish spec and the firewall's container port.

Nothing is baked into the image, so edits to either file apply on the next run — no rebuild.

## Turning it off

```bash
CLAUDE_SANDBOX_INFO=0 ./run.sh
```

Accepts `0`/`false`/`no`/`off`. The mount is skipped entirely, so `~/.claude/skills/sandbox` does
not exist and the four env vars are unset. What the sandbox *is* does not change — ports are still
published and opened identically; only the session's ability to look them up goes away.

## Avoiding the permission prompt

Running the script is a `Bash` call, so it may prompt. Pre-approve it in your config-dir
`settings.json` (`cid show settings.json`):

```json
{
  "permissions": {
    "allow": ["Bash(~/.claude/skills/sandbox/sandbox-info.sh)"]
  }
}
```

`make init` seeds `settings.json` only when missing, so an existing config needs this added by hand.

## Is telling Claude about its sandbox a risk?

No meaningful increase, which is why it's on by default:

- **Nothing here is secret.** Every fact is already derivable inside the container — `printenv`,
  listening sockets, `ip route`, `/proc/self/mountinfo`, `sudo -l`.
- **Confinement is enforced elsewhere** — the in-container nftables policy, Squid's per-project
  allowlist, and each host bridge's own authorization, all outside the container's control. None of
  it depends on the container not knowing its own shape. See [Threat Model](threat-model.md).
- **Secrets are reported as present/absent only.** `DOCKER_BRIDGE_TOKEN` gates a line saying the
  bridge is enabled; the value is never printed, nor is `MCP_GH_BEARER` or the proxy URL's
  credentials. The tests assert this.
- **It is read-only.** No network calls, no writes, and it cannot change what it describes — ports
  and mounts are fixed at `docker run` time.

The practical argument runs the other way: a session that doesn't know its host port guesses, and
one that reads a blocked domain as a network fault retries or hunts for a workaround instead of
telling you to run `cid domains add`.
