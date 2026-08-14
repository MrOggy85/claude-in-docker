# Sandbox Self-Awareness

Claude Code runs inside the container, but some facts about the container only
exist **outside** it. The important one is the host side of a published port:

```bash
CLAUDE_PORTS="9345:3000" ./run.sh
```

The container sees a server on port `3000`. The host reaches it on `9345`. Until
now nothing inside the container was told about `9345` — `run.sh` passed only the
container-side port inward, for the firewall.

That gap causes wrong answers, not just missing trivia. The
[chrome-devtools MCP server](chrome-devtools-mcp.md) drives a browser **on the
host**, so pointing it at `http://localhost:3000` hits the host's own port 3000 —
not your dev server. Same for any URL handed to the user. And because the host
port varies per session, it cannot be written into config once.

## What ships

An on-demand `sandbox` skill, mounted read-only into every session at
`~/.claude/skills/sandbox`:

| File | Role |
| --- | --- |
| [`skills/sandbox/SKILL.md`](../skills/sandbox/SKILL.md) | when to consult it, and how to read the output |
| [`skills/sandbox/sandbox-info.sh`](../skills/sandbox/sandbox-info.sh) | prints the report; reads environment variables only |

It is **on demand by design**: nothing is injected into the session's context and
no `SessionStart` hook is installed. Only the skill's one-line description is
always present; the facts are fetched when they matter (a server needs a URL, a
request got blocked, a written file is missing on the host).

Run it yourself any time to see exactly what a session is told:

```bash
# inside a session
~/.claude/skills/sandbox/sandbox-info.sh
```

It reports, in this order:

- **Files** — the repo's host path ↔ `/home/dev/repo`, extra `CLAUDE_MOUNTS`
  targets, and the [volume-backed paths](volume-backed-paths.md) that exist only
  inside the container.
- **Ports published to the host (inbound)** — each container port with the host
  endpoint that forwards to it, or an explicit "none" plus the `CLAUDE_PORTS`
  relaunch route. See [Publishing Ports](publishing-ports.md).
- **Host services (outbound)** — the `host.docker.internal` ports the firewall
  opened, labelled where `run.sh` knows their purpose (sound server, docker
  bridge, and the chrome bridge when you opened its port). See
  [Host-Outbound Ports](host-outbound-ports.md).
- **Everything else on the network** — that egress passes the
  [Squid allowlist](egress-proxy.md), so a blocked request is policy: the skill is
  told to report the hostname and point you at `cid domains add <host>` rather
  than trying another route.
- **Using this** — the operative rule: container port for in-container `curl`,
  host endpoint for anything on the host. The chrome-devtools bridge is named here
  only when its port is open; otherwise the same warning stays generic, so no
  session is pointed at a server it cannot reach.

## How it stays correct across parallel sessions

`sandbox-info.sh` is a pure function of the environment, and the environment is
per container. `run.sh` (step 3g) forwards `CONTAINER_PUBLISHED_PORTS`,
`CONTAINER_HOST_PORT_LABELS`, `CONTAINER_EXTRA_MOUNTS` and
`CONTAINER_VOLUME_PATHS` alongside the `CLAUDE_HOST_PROJECT_DIR` and
`CONTAINER_HOST_OUTBOUND_PORTS` it already set. Two sessions in the same project
with different `CLAUDE_PORTS` each report their own mapping, with nothing
generated on the host and nothing to clean up.

The host side of a mapping is computed once, in
[`scripts/extra-ports.sh`](../scripts/extra-ports.sh), which emits it as a third
tab-separated field next to the publish spec and the firewall's container port.

Nothing is baked into the image, so editing either file takes effect on the next
run — no rebuild.

## Turning it off

```bash
CLAUDE_SANDBOX_INFO=0 ./run.sh
```

Accepts `0`/`false`/`no`/`off`. The skill is not merely disabled: the mount is
skipped, so `~/.claude/skills/sandbox` does not exist, and the four env vars are
not set. What the sandbox *is* does not change — ports are still published and
opened exactly the same way; only the session's ability to look them up goes away.

## Avoiding the permission prompt

Running the script is a `Bash` call, so it may prompt. To pre-approve it, add to
your `settings.json` in the config dir (`cid show settings.json`):

```json
{
  "permissions": {
    "allow": ["Bash(~/.claude/skills/sandbox/sandbox-info.sh)"]
  }
}
```

`make init` only seeds `settings.json` when it is missing, so an existing config
needs this added by hand.

## Is telling Claude about its sandbox a risk?

No meaningful increase, which is why this is on by default:

- **Nothing here is secret.** Every fact is already derivable from inside the
  container — `printenv`, listening sockets, `ip route`, `/proc/self/mountinfo`,
  `sudo -l`. The report is a summary of what the container can already see.
- **Confinement is enforced elsewhere.** The boundary is the in-container
  nftables policy, Squid's per-project allowlist, and each host bridge's own
  authorization — all outside the container's control. None of it depends on the
  container not knowing its own shape. See [Threat Model](threat-model.md).
- **Secrets are reported as present/absent only.** `DOCKER_BRIDGE_TOKEN` gates a
  line saying the bridge is enabled; the value is never printed, and neither is
  `MCP_GH_BEARER` or the proxy URL's credentials. The `sandbox-info` tests assert
  this.
- **It is read-only.** The script makes no network calls, writes nothing, and
  cannot change any of what it describes. Ports and mounts are fixed at
  `docker run` time; changing them means you relaunching.

The practical argument runs the other way: a session that does not know its host
port guesses, and a session that reads a blocked domain as a network fault retries
or hunts for a workaround instead of telling you to run `cid domains add`.
