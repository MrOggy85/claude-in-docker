# Environment Variables

A reference for the environment variables you can set to change how the container
runs. Set one inline for a single run:

```bash
CLAUDE_MOUNTS="$HOME/data:/data" ./run.sh
```

…or export it from your shell profile / `claude` alias to make it permanent.

All are optional — with none set, the container runs with its defaults.

## Configuration variables

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_DOCKER_CONFIG_DIR` | `$XDG_CONFIG_HOME/claude-in-docker` (i.e. `~/.config/claude-in-docker`) | Directory holding all user config (settings, credentials, allowed-domains, per-project dirs). Read by `run.sh`, `proxy/up.sh`, `cid`, and the `Makefile`. | — |
| `CLAUDE_PROJECTS_DIR` | `<config-dir>/projects` | Base directory for the per-project config dirs. Override to relocate them (the test suite points this at a throwaway dir). | — |
| `CLAUDE_MOUNTS` | _(unset)_ | Extra host folders to bind-mount into the container. | [Mounting Extra Folders](mounting-extra-folders.md) |
| `CLAUDE_PORTS` | _(unset)_ | Ports to publish from the container to the host (and open in the firewall). | [Publishing Ports](publishing-ports.md) |
| `CLAUDE_VOLUME_PATHS` | _(unset)_ | Extra in-container paths to back with named volumes (in addition to `node_modules`), keeping them off the host disk. | [Volume-Backed Paths](volume-backed-paths.md) |
| `SKIP_CLAUDE_VOLUME_PATHS` | _(unset)_ | When set, disables all volume-backing, including the default `node_modules`. | [Volume-Backed Paths](volume-backed-paths.md) |
| `MCP_GH_BEARER` | _(unset)_ | Read-only GitHub token forwarded to the GitHub MCP server. The run aborts if the token is write-capable. | [MCP Servers](mcp-servers.md) |
| `CLAUDE_ALLOW_PROJECT_SETTINGS` | _(unset)_ | Accepts `1`/`true`/`yes`/`on`. Skips the prompt that warns about a project-level `.claude/settings.json` and proceeds with it. | [Known Attack Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default) |
| `SOUND_PORT` | `4767` | Host port the container reaches to play sound effects. Opened outbound to the host by default; a special case of `CLAUDE_HOST_OUTBOUND_PORTS`. | [Sound Effects](sound-effects.md) |
| `CLAUDE_HOST_OUTBOUND_PORTS` | _(unset)_ | Extra host ports the container may connect **out** to (direct to `host.docker.internal`, bypassing Squid). Comma-separated `PORT` or `PORT/udp`. Merged with `SOUND_PORT`. | [Host-Outbound Ports](host-outbound-ports.md) |
| `CHROME_DEVTOOLS_MCP_PORT` | `9333` | Host port the `chrome-devtools-mcp` HTTP bridge listens on. Read by the host bridge, **not** by `run.sh` — unlike `SOUND_PORT` it is not auto-merged into the firewall, so open it yourself with `CLAUDE_HOST_OUTBOUND_PORTS="9333"`. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` | _(unset)_ | Extra space-separated flags the host bridge passes to `chrome-devtools-mcp` (e.g. `--channel canary`). Host-only, not read by `run.sh`. | [Chrome DevTools MCP](chrome-devtools-mcp.md) |
| `CLAUDE_VOLUME` | `claude-<project>-<hash>` | Override the per-project session volume name (e.g. a throwaway one). | — |
| `CLAUDE_CONTAINER_NAME` | `claude-<project>-<random>` | Pin a specific container name instead of the randomized default. | — |

### Egress proxy

The shared Squid proxy is the sole egress path and is always on (`run.sh`
auto-starts it); there is no enable/disable flag. These variables only rename the
shared network and container.

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_EGRESS_NETWORK` | `claude-egress` | Docker network shared by the proxy and the Claude containers (read by `run.sh` and `proxy/up.sh`). | [Centralized Egress Proxy](egress-proxy.md) |
| `CLAUDE_EGRESS_PROXY_NAME` | `claude-egress-proxy` | Name of the long-running Squid container. | [Centralized Egress Proxy](egress-proxy.md) |
| `CLAUDE_EGRESS_IMAGE` | `ubuntu/squid:latest` | Squid image `proxy/up.sh` runs; pin a digest for supply-chain safety. | [Centralized Egress Proxy](egress-proxy.md) |

### Usage tracking (`ccusage`)

| Variable | Default | Description | Reference |
| --- | --- | --- | --- |
| `CLAUDE_AUTO_USAGE` | `1` | Set to `0`/`false`/`no`/`off` to skip the automatic usage sync after each run. | [Usage Log Synchronization](usage-sync.md) |
| `CLAUDE_USAGE_DIR` | `~/.claude-docker-usage` | Where the aggregated, cost-only usage logs are kept. | [Usage Log Synchronization](usage-sync.md) |
| `CLAUDE_USAGE_ONLINE` | _(unset)_ | When set, fetches live LiteLLM pricing instead of the image's bundled offline pricing. | [Tracking Usage](tracking-usage.md) |
| `CCUSAGE_VERSION` | `latest` | npm version used for the `npx ccusage` fallback; pin it to a specific version if needed. | [Usage Log Synchronization](usage-sync.md) |

## The `.env` file

Beyond the variables above, any `KEY=VALUE` lines in a `.env` in the config dir
(`~/.config/claude-in-docker/`) are injected straight into the container via
`docker --env-file`. This
is how you pass variables your own workflow needs inside the container — e.g.
`DATABASE_URL`, or `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` to point Claude
at a gateway.

Mind the `--env-file` parsing rules (literal values, no interpolation, no
multiline) and note that the variables `run.sh` sets itself take precedence over
anything in `.env`. See [Passing Environment Variables](passing-env-vars.md) for
the full rules and security notes.
