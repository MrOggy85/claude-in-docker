# Host Docker Bridge (read-only)

Let Claude inspect the Docker containers running on your **host** — `docker ps`,
`docker logs`, `docker stats` — instead of printing commands for you to copy,
paste, and report back.

**Read-only, and off by default.** There is no `build`, `run`, `compose`, `exec`,
`inspect`, `cp`, or any other verb: the bridge exposes exactly three tools, and
only for containers you have explicitly allowlisted. See
[Why not the Docker socket](#why-not-the-docker-socket) and
[Security](#security) before enabling.

## Why a host-side server?

The container has no Docker daemon and no Docker CLI, deliberately. So — like the
[sound server](sound-effects.md) and the
[chrome-devtools bridge](chrome-devtools-mcp.md) — a small **zero-dependency Node
server** runs on the **host** (`docker-bridge/host-docker-bridge.js`, node
built-ins only) and the container reaches it over HTTP via
`host.docker.internal`.

Unlike the chrome bridge, this one is not a proxy for an upstream MCP server:
it answers `initialize` / `tools/list` / `tools/call` itself and spawns one
short-lived `docker` process per call. It reuses the same MCP Streamable HTTP
transport shape (`POST`/`GET`/`DELETE` on `/mcp`, responses as Server-Sent
Events).

```
HOST:  docker ps|logs|stats  <--  host-docker-bridge.js  -->  http://0.0.0.0:9334/mcp
                                    reads <config-dir>/…/docker-containers.txt
CONTAINER:  claude --mcp-config  -->  http://host.docker.internal:9334/mcp
                                      Authorization: Bearer <per-project token>
```

### Why not the Docker socket?

Mounting `/var/run/docker.sock` into the container is the usual shortcut and it is
**root-equivalent on the host**: the socket has no per-command ACL, so
`docker run -v /:/host` reads and writes your whole filesystem as root, and any
container it starts is outside `claude-egress` and outside `init-firewall.sh` —
unfiltered internet. A read-only HTTP socket proxy (`POST=0`) is not enough
either: `/containers/{id}/json` is a `GET`, and it returns `Config.Env` for every
container on the machine — including the other `claude-*` sessions'
`MCP_GH_BEARER` and every value from their per-project `.env`.

This bridge instead keeps the policy on the host, where the agent cannot reach it:

1. **Bearer token, required.** The token also *identifies the project*: it is read
   from `<config-dir>/projects/<key>/docker-bridge.token`, and the matching key
   selects that project's container allowlist. The container never asserts which
   project it is — contrast the self-asserted Squid proxy username
   ([Egress Proxy](egress-proxy.md#trust-model--limitations)).
2. **Container allowlist.** Only containers you listed are visible, and a name
   outside it is refused even when named explicitly.
3. **Fixed argv.** Each tool builds a literal argument array — no shell, ever. The
   only caller-supplied values are a container name (pattern-checked *and*
   allowlisted), a clamped line count, and a validated `--since`.

## Tools

| Tool | What it runs | Notes |
|---|---|---|
| `docker_ps` | `docker ps --no-trunc --format '{{json .}}'` (`--all` optional) | Non-allowlisted containers are dropped. `Labels` and `Mounts` are stripped — they carry host filesystem paths. |
| `docker_logs` | `docker logs --tail N [--since S] [--timestamps] <name>` | One allowlisted container. `tail` defaults to 200, clamped to 5000; `since` must be a duration (`30s`, `10m`, `2h`, `1d`) or a date. |
| `docker_stats` | `docker stats --no-stream --format '{{json .}}'` | Optionally one container; otherwise all allowlisted ones. |

Output is capped at 256 KB (with an explicit truncation marker), each `docker`
call is killed after 15s, at most 4 run concurrently, and calls are rate-limited
to 60/min per project.

## Setup

### 1. Start the bridge on your host

```bash
./docker-bridge/host-docker-bridge.sh
```
Or install it as a service so it starts automatically:

**macOS (launchd):**
```bash
cp docker-bridge/com.user.claude-docker-bridge.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-docker-bridge.plist
launchctl kickstart -k gui/$(id -u)/com.user.claude-docker-bridge
```
The plist assumes the repo lives at `~/code/claude-in-docker`; edit the path in
`ProgramArguments` if yours is elsewhere. To reload after editing the plist,
`bootout` first: `launchctl bootout gui/$(id -u)/com.user.claude-docker-bridge`.
Logs go to `/tmp/claude-docker-bridge.log`.

**Linux (systemd `--user`):**
```bash
cp docker-bridge/claude-docker-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-docker-bridge
```
Same path assumption as the plist; edit `ExecStart` if your repo lives
elsewhere. Logs: `journalctl --user -u claude-docker-bridge -f`.

### 2. Declare which containers Claude may see

```bash
cd ~/code/my-project
cid containers add myapp-web myapp-db     # exact names
cid containers add 'myapp-*'              # trailing '*' = prefix glob (quote it)
cid containers                            # show the effective list
```
`-g` targets the shared baseline (`<config-dir>/docker-containers.txt`, applies to
every project) instead of this project's list; `-C <dir>` picks a different
project. See [the `cid` CLI](config-cli.md).

There is no default and no implicit wildcard: with an empty list the bridge
returns nothing and `run.sh` refuses to launch (see
[the guard](#the-pre-flight-guard)).

### 3. Add the server to your config-dir `mcp-servers.json`

(`~/.config/claude-in-docker/mcp-servers.json`, or a per-project
`<config-dir>/projects/<key>/mcp-servers.json`), inside `mcpServers`:
```json
"docker": {
   "type": "http",
   "url": "http://host.docker.internal:9334/mcp",
   "headers": { "Authorization": "Bearer ${DOCKER_BRIDGE_TOKEN}" }
}
```
`${DOCKER_BRIDGE_TOKEN}` is expanded by Claude Code from the container env;
`run.sh` puts it there. This entry is **not** in the shipped
`templates/mcp-servers.json` on purpose — with the bridge disabled it would show
as a failed MCP server on every run, which just teaches you to ignore MCP errors.

### 4. Launch with the bridge enabled

```bash
CLAUDE_DOCKER_BRIDGE=1 ./run.sh
```
That single switch mints the per-project token if absent (mode `600`), forwards it
to the container, and opens the firewall port. With it unset there is **no
`OUTPUT` rule for the port**, so the container cannot reach the bridge even if the
host daemon is running. Put it in a per-project `.claude-env` if you want it every
time — see [Per-Project Launch Config](per-project-env.md).

## Port and other knobs

- **Port** defaults to `9334`; override with `DOCKER_BRIDGE_PORT`, which both the
  bridge and `run.sh` read. If you change it, keep two places in sync:
  `DOCKER_BRIDGE_PORT` (exported for both processes) and the `url` in
  `mcp-servers.json`. Unlike the chrome bridge you do **not** also set
  `CLAUDE_HOST_OUTBOUND_PORTS` — `CLAUDE_DOCKER_BRIDGE=1` merges the port for you.
- **Bind address** defaults to `0.0.0.0`, because the container reaches the host
  over the Docker gateway and a `127.0.0.1` bind is unreachable from it (see
  [Host-Outbound Ports](host-outbound-ports.md)). Narrow it with
  `DOCKER_BRIDGE_BIND` if you know your Docker gateway address.
- **Docker CLI path** — `DOCKER_BRIDGE_DOCKER_CMD` (default `docker`). The
  launcher already prepends `/usr/local/bin` and `/opt/homebrew/bin` to `PATH`
  because launchd starts agents with a minimal one.
- **Token** — minted per project at
  `<config-dir>/projects/<key>/docker-bridge.token`. Delete it to rotate; the next
  `run.sh` mints a new one. Never commit it, and note it is read by the bridge
  process, which runs as you.

## The pre-flight guard

`guards/docker-bridge.sh` runs before any build or container work whenever the
bridge is enabled, and aborts the run when the allowlist is:

- **empty or missing** — the allowlist is the only limit on what the agent can
  see, so it must be declared, not defaulted;
- **a bare `*`** — that is every container on the host;
- **`claude-…` or a glob covering it** — the other Claude sessions. Their logs
  carry their env, including `MCP_GH_BEARER`;
- **the egress proxy** (`claude-egress-proxy`) — its access log is every URL every
  session has requested.

It also warns (without aborting) when nothing is listening on the port, so a dead
bridge surfaces at launch rather than as a confusing mid-session MCP failure.

## Security

Read this before enabling. These are the caveats of
[Host-Outbound Ports](host-outbound-ports.md#caveats), plus the ones specific to
handing an agent a view of your host's containers.

- **Bypasses the egress allowlist entirely.** Traffic to `host.docker.internal`
  skips Squid (it is in `NO_PROXY`), so `allowed-domains.txt` does **not** apply
  to port `9334`. The firewall port rule and this bridge's own token + allowlist
  are the only controls.
- **The container allowlist is the whole boundary.** Everything the agent can read
  is what you listed. Keep it to the containers of the project at hand; prefer
  exact names over broad globs. `cid containers` shows the effective list.
- **Container logs are an exfiltration sink and may contain secrets.** Your app
  logs its own tokens, connection strings, and user data more often than you
  think, and the agent reads them over a channel Squid does not see. This is the
  main residual risk of the read-only surface — it is a *read* channel, not a
  write one, but what it reads is unfiltered.
- **The bridge runs as the host user.** It shells out to your `docker` CLI with
  your Docker context and your daemon. The allowlist and fixed argv are what keep
  that from mattering; nothing else does.
- **Unauthenticated callers are rejected, but the port is open to the LAN.**
  Binding `0.0.0.0` is required for container reachability, so anything that can
  reach your host on `9334` can attempt requests. They fail without a valid token
  — unlike the [sound server](sound-effects.md) and
  [chrome bridge](chrome-devtools-mcp.md), which have no authentication at all.
  Narrow the bind or firewall the port if your host sits on an untrusted network.
- **Guards cannot gate individual calls.** `guards/docker-bridge.sh` runs once,
  pre-flight. Mid-session the token, the allowlist, and the fixed argv are the
  enforcement — which is why there is no verb that mutates anything.
- **Enable only when needed.** `launchctl bootout` the service, or just omit
  `CLAUDE_DOCKER_BRIDGE=1`, when you are not actively using it.

## Verification

1. Start the bridge; tail `/tmp/claude-docker-bridge.log` for the
   `read-only docker bridge on 0.0.0.0:9334/mcp` line and the token count.
2. Confirm it binds all interfaces, not loopback:
   ```bash
   lsof -nP -iTCP:9334 -sTCP:LISTEN
   ```
   Expect `*:9334`. A `127.0.0.1:9334` result means the container cannot reach it.
3. Confirm an unauthenticated request is rejected, then run the full handshake for
   a project (initialize → `tools/list` → `docker_ps` → teardown):
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9334/mcp   # 401
   ./docker-bridge/smoke-test.sh ~/code/my-project
   ```
   The `docker_ps` result must list only your allowlisted containers, with no
   `Labels`, no `Mounts`, and no host paths.
4. Confirm the scoping holds: `cid containers` should not include any `claude-*`
   name or `claude-egress-proxy`, and asking for one anyway must be refused.
5. Launch with the bridge **off** and check from a container shell that
   `curl -sv http://host.docker.internal:9334/mcp` fails to connect (no `OUTPUT`
   rule). Then launch with `CLAUDE_DOCKER_BRIDGE=1` and confirm it gets an HTTP
   response, and that `init-firewall.sh` logged an accept rule for `9334`.
6. In Claude Code, run `/mcp` — `docker` should list as connected with exactly
   `docker_ps`, `docker_logs`, `docker_stats`.
7. Ask Claude for the status and last 50 log lines of one of your containers. It
   should use the tools rather than printing commands for you to paste.
8. Unit tests: `make test-docker-bridge` and `make test-guards`.

## Troubleshooting

### `docker: not found` in the bridge log

launchd starts agents with a minimal `PATH`. The launcher prepends
`/usr/local/bin` and `/opt/homebrew/bin`; if your `docker` is elsewhere, set
`DOCKER_BRIDGE_DOCKER_CMD` to an absolute path — either exported before running
`host-docker-bridge.sh`, or in the plist's `EnvironmentVariables` dict (see the
same pattern in [Chrome DevTools MCP](chrome-devtools-mcp.md#troubleshooting)).

### Every call returns 401

The container's `DOCKER_BRIDGE_TOKEN` no longer matches any
`<config-dir>/projects/*/docker-bridge.token`. Most often the token file was
deleted or the config dir moved (`CLAUDE_DOCKER_CONFIG_DIR` /
`CLAUDE_PROJECTS_DIR` must resolve the same for `run.sh` and for the bridge — the
launcher derives them from `scripts/paths.sh`, so a mismatch means the two are
being started with different env). Restart the session after rotating a token.

### `no Docker container allowlist yet`

The bridge found no entries for this project. Run
`cid containers add <name>` — no session restart needed, the allowlist is re-read
on every call.

### The tools work but Claude keeps printing commands instead

Check `~/.claude/CLAUDE.md` inside the container (i.e. your
`<config-dir>/container-CLAUDE.md`). Older copies say Docker is unavailable and
tell Claude to hand commands to the human; update that section — see
`templates/container-CLAUDE.md` for the current wording.

## Not implemented: build and run

`docker build` / `docker run` / `docker compose up` are **deliberately absent**,
and adding them is not a small extension:

- `docker run` accepts `-v /:/host`, `--privileged`, `--network host`,
  `--pid host` — each of which is a complete bypass of the container isolation,
  the egress lock, and the filesystem allowlist.
- `docker build` is not milder: `RUN` steps execute as root with unrestricted
  network, and the build context is a caller-chosen host path.
- Any container started this way is not on `claude-egress` and not subject to
  `init-firewall.sh`, so it has unfiltered internet regardless of what the agent
  is otherwise allowed to reach.

If it is added, the shape is a **pre-declared action list** —
`<config-dir>/projects/<key>/docker-actions.txt`, where each line is a complete
invocation you authored (`web-up = compose up -d web`) and the agent may only pass
an action *id*, never flags. Two problems that surface only there:

1. **The compose file lives in the untrusted repo.** The agent can edit
   `docker-compose.yml` to request `privileged: true`, `network_mode: host`, or
   `volumes: ["/:/host"]` and then invoke a pre-declared action. So the bridge
   would have to run `docker compose config --format json` and reject those keys
   **on every call**, not once.
2. **Escaping the egress lock.** The action would need `--network` forced to the
   project's own compose network, and the residual documented.

Per-call human confirmation is also possible without a terminal — `osascript -e
'display dialog …'` from a launchd *user* agent shows a GUI prompt in the Aqua
session — if the pre-declared list alone turns out to be too loose.

Until then, `build`/`run`/`exec` stay a human step: Claude gives you the command,
you run it.
