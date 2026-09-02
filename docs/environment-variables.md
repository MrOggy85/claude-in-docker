# Environment Variables

Every variable that changes how the container runs. All are optional. Set one inline for a single
run, or export it from your shell profile / `claude` alias to make it permanent:

```bash
CLAUDE_MOUNTS="$HOME/data:/data" ./run.sh
```

> `cid env` is the terminal version of this page (optionally filtered, e.g. `cid env EGRESS`): it
> shows each variable's current value or default and flags the ones that are set. See [The `cid`
> config CLI](config-cli.md).

## Configuration variables

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_DOCKER_CONFIG_DIR` | `$XDG_CONFIG_HOME/claude-in-docker` (i.e. `~/.config/claude-in-docker`) | All user config: settings, credentials, allowed-domains, per-project dirs. Read by `run.sh`, `proxy/up.sh`, `cid`, `Makefile`. | — |
| `CLAUDE_PROJECTS_DIR` | `<config-dir>/projects` | Base directory for per-project config dirs. The test suite points this at a throwaway dir. | — |
| `CLAUDE_MOUNTS` | _(unset)_ | Extra host folders to bind-mount in. | [Mounting Extra Folders](mounting-extra-folders.md) |
| `CLAUDE_PORTS` | _(unset)_ | Ports to publish container → host (and open in the firewall). | [Publishing Ports](publishing-ports.md) |
| `CLAUDE_VOLUME_PATHS` | _(unset)_ | Extra in-container paths to back with named volumes, beyond `node_modules`. | [Volume-Backed Paths](volume-backed-paths.md) |
| `SKIP_CLAUDE_VOLUME_PATHS` | _(unset)_ | Disables all volume-backing, including the default `node_modules`. | [Volume-Backed Paths](volume-backed-paths.md) |
| `MCP_GH_BEARER` | _(unset)_ | GitHub token forwarded to the GitHub MCP server. The run aborts if it is write-capable. | [MCP Servers](mcp-servers.md) |
| `CLAUDE_ALLOW_PROJECT_SETTINGS` | _(unset)_ | `1`/`true`/`yes`/`on`. Skips the project-settings guard and honors `.claude/settings.json` as-is. | [Known Attack Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default) |
| `CLAUDE_PROJECT_SETTINGS_STRICT` | _(unset)_ | `1`/`true`/`yes`/`on`. Reviews the **whole** settings file every run, ignoring the capability scan and any recorded approval. For auditing. | [Known Attack Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default) |
| `SOUND_PORT` | `4767` | Host port the container reaches to play sounds. Opened outbound by default — a special case of `CLAUDE_HOST_OUTBOUND_PORTS`. | [Sound Effects](sound-effects.md) |
| `CLAUDE_HOST_OUTBOUND_PORTS` | _(unset)_ | Extra host ports the container may connect **out** to, bypassing Squid. Comma-separated `PORT` or `PORT/udp`. Merged with `SOUND_PORT`. | [Host-Outbound Ports](host-outbound-ports.md) |
| `CLAUDE_CHROME_DEVTOOLS` | _(unset)_ | `1`/`true`/`yes`/`on`. Enables the host Chrome bridge: mints the per-project token, forwards it as `CHROME_DEVTOOLS_MCP_TOKEN`, opens `CHROME_DEVTOOLS_MCP_PORT`. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CLAUDE_CHROME_PROFILE` | `default` | Names this container's Chrome profile within the project (`[A-Za-z0-9._-]{1,64}`). Give a second container on the same project its own, or it falls back to a temp profile. | [Chrome DevTools MCP](chrome-devtools-mcp.md#profiles) |
| `CHROME_DEVTOOLS_MCP_PORT` | `9333` | Port the `chrome-devtools-mcp` bridge listens on. Read by **both** the bridge and `run.sh`, so it is auto-merged into the firewall when the bridge is on — keep it in sync with the `url` in `mcp-servers.json`. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` | _(unset)_ | Extra flags the host bridge passes to `chrome-devtools-mcp` (e.g. `--channel canary`). Not `--isolated`/`--user-data-dir`, which the bridge owns. Host-only. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CHROME_DEVTOOLS_MCP_PROFILE_ROOT` | `~/.cache/claude-in-docker/chrome-profiles` | Where per-project Chrome profiles live. Host-only. | [Chrome DevTools MCP](chrome-devtools-mcp.md#profiles) |
| `CHROME_DEVTOOLS_MCP_PROFILE` | _(unset)_ | `off` gives every session a throwaway profile instead of a persistent one. Host-only. | [Chrome DevTools MCP](chrome-devtools-mcp.md#profiles) |
| `CHROME_DEVTOOLS_MCP_MAX_SESSIONS` | `4` | How many browsers may run at once; the oldest session is closed past the cap. Host-only. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CLAUDE_DOCKER_BRIDGE` | _(unset)_ | `1`/`true`/`yes`/`on`. Enables read-only host Docker access: mints the per-project token, forwards it as `DOCKER_BRIDGE_TOKEN`, opens `DOCKER_BRIDGE_PORT`. | [Host Docker Bridge](docker-bridge.md) |
| `DOCKER_BRIDGE_PORT` | `9334` | Port the docker bridge listens on. Read by **both** the bridge and `run.sh`, so it is auto-merged into the firewall when the bridge is on — keep it in sync with the `url` in `mcp-servers.json`. | [Host Docker Bridge](docker-bridge.md) |
| `DOCKER_BRIDGE_BIND` | `0.0.0.0` | Address the docker bridge binds. `0.0.0.0` is required to be reachable over the Docker gateway; narrow it if you know your gateway address. Host-only. | [Host Docker Bridge](docker-bridge.md) |
| `DOCKER_BRIDGE_DOCKER_CMD` | `docker` | Path to the `docker` CLI the bridge invokes (launchd's `PATH` is minimal). Host-only. | [Host Docker Bridge](docker-bridge.md) |
| `CLAUDE_SANDBOX_INFO` | `1` | `0`/`false`/`no`/`off` stops mounting the `sandbox` skill, so the session cannot look up its own ports, mounts and egress policy. The sandbox itself is unchanged. | [Sandbox Self-Awareness](sandbox-info.md) |
| `CLAUDE_MEMORY` | 25% of the host's RAM, floor `2g` | Memory cap (`--memory`). `0`/`off`/`unlimited` removes it. | [Resource Limits](resource-limits.md) |
| `CLAUDE_MEMORY_SWAP` | same as `CLAUDE_MEMORY` (swap off) | Memory+swap **total** (`--memory-swap`); must be ≥ `CLAUDE_MEMORY`. | [Resource Limits](resource-limits.md) |
| `CLAUDE_CPUS` | host cores − 2 | CPU quota (`--cpus`); accepts fractions. Unset on a 1–2 core host. | [Resource Limits](resource-limits.md) |
| `CLAUDE_PIDS_LIMIT` | `2048` | Max processes/threads (`--pids-limit`). | [Resource Limits](resource-limits.md) |
| `CLAUDE_VOLUME` | `claude-<project>-<hash>` | Override the per-project session volume name. | — |
| `CLAUDE_CONTAINER_NAME` | `claude-<project>-<random>` | Pin a container name instead of the randomized default. | — |

### Egress proxy

The Squid proxy is the sole egress path and is always on (`run.sh` auto-starts it) — there is no
enable/disable flag, and none for TLS interception either: `run.sh` aborts without a CA. These
rename the shared network and container, or swap the image.

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_EGRESS_NETWORK` | `claude-egress` | Docker network shared by the proxy and the Claude containers. | [Centralized Egress Proxy](egress-proxy.md) |
| `CLAUDE_EGRESS_PROXY_NAME` | `claude-egress-proxy` | Name of the long-running Squid container. | [Centralized Egress Proxy](egress-proxy.md) |
| `CLAUDE_EGRESS_IMAGE` | `claude-egress-squid:local` | Squid image `proxy/up.sh` runs. Set it to use your own image instead of building `proxy/Dockerfile` — it must be an `ssl_bump`-capable build. | [TLS Inspection](tls-inspection.md) |
| `CLAUDE_EGRESS_MEMORY` | `1g` | Memory cap for the proxy container, applied with swap off. | [Resource Limits](resource-limits.md) |

Read by the egress alert watcher (`proxy/watch.sh`), which `run.sh` starts alongside the proxy:

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_EGRESS_ALERTS` | `1` | Set `0` to skip starting the watcher, turning off first-time-host and denial notifications. | [Egress Alerts](egress-alerts.md) |
| `CLAUDE_NOTIFY_CMD` | (unset) | Command to notify with instead of `osascript` / `notify-send`, called as `<cmd> <urgency> <title> <body>`. | [Egress Alerts](egress-alerts.md) |
| `CLAUDE_DENY_ALERT_COOLDOWN` | `300` | Seconds before the same denied host may alert again. | [Egress Alerts](egress-alerts.md) |

Read by `make ca` (`scripts/gen-ca.sh`) only, when generating the CA — changing one later has no
effect until you rotate:

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CA_DAYS` | `3650` | Validity period of the generated CA. | [TLS Inspection](tls-inspection.md) |
| `CA_KEY_BITS` | `4096` | RSA key size. The test suite uses `2048` for speed. | [TLS Inspection](tls-inspection.md) |
| `CA_CN` | `claude-in-docker egress CA` | Common name, i.e. the issuer a session sees. | [TLS Inspection](tls-inspection.md) |

### Usage tracking (`ccusage`)

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_AUTO_USAGE` | `1` | `0`/`false`/`no`/`off` skips the automatic usage sync after each run. | [Usage Log Synchronization](usage-sync.md) |
| `CLAUDE_USAGE_DIR` | `~/.claude-docker-usage` | Where the aggregated, cost-only usage logs are kept. | [Usage Log Synchronization](usage-sync.md) |
| `CLAUDE_USAGE_ONLINE` | _(unset)_ | Fetch live LiteLLM pricing instead of the image's offline snapshot. | [Tracking Usage](tracking-usage.md) |
| `CCUSAGE_VERSION` | `latest` | npm version for the `npx ccusage` fallback. | [Usage Log Synchronization](usage-sync.md) |

### Output

Host-side messages — `run.sh`, the guards, the proxy, `usage.sh` — are colour-coded to a terminal:
cyan for a named value, green for confirmation, yellow for `WARNING:`, bold red for `ERROR:`. Piped
or redirected output is plain, decided per stream.

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `NO_COLOR` | _(unset)_ | Any value disables colour. Wins over everything else ([no-color.org](https://no-color.org)). | — |
| `CLICOLOR_FORCE` | _(unset)_ | Force colour through a pipe or under `TERM=dumb`. Loses only to `NO_COLOR`. | — |

Neither reaches the `[firewall]` lines: those come from inside the container, where `sudo` strips
the environment, so they follow the terminal test alone.

## The `.env` file

Any `KEY=VALUE` lines in a `.env` in the config dir are injected straight into the container via
`docker --env-file` — this is how you pass variables your own workflow needs, e.g. `DATABASE_URL`,
or `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` to point Claude at a gateway.

Mind the `--env-file` parsing rules (literal values, no interpolation, no multiline); variables
`run.sh` sets itself take precedence. See [Passing Environment Variables](passing-env-vars.md).
