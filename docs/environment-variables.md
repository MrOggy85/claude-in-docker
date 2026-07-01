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
| `CLAUDE_MOUNTS` | _(unset)_ | Extra host folders to bind-mount into the container. | [Mounting Extra Folders](mounting-extra-folders.md) |
| `CLAUDE_PORTS` | _(unset)_ | Ports to publish from the container to the host (and open in the firewall). | [Publishing Ports](publishing-ports.md) |
| `CLAUDE_VOLUME_PATHS` | _(unset)_ | Extra in-container paths to back with named volumes (in addition to `node_modules`), keeping them off the host disk. | [Volume-Backed Paths](volume-backed-paths.md) |
| `SKIP_CLAUDE_VOLUME_PATHS` | _(unset)_ | When set, disables all volume-backing, including the default `node_modules`. | [Volume-Backed Paths](volume-backed-paths.md) |
| `MCP_GH_BEARER` | _(unset)_ | Read-only GitHub token forwarded to the GitHub MCP server. The run aborts if the token is write-capable. | [MCP Servers](mcp-servers.md) |
| `CLAUDE_ALLOW_PROJECT_SETTINGS` | _(unset)_ | Accepts `1`/`true`/`yes`/`on`. Skips the prompt that warns about a project-level `.claude/settings.json` and proceeds with it. | [Known Attack Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default) |
| `SOUND_PORT` | `4767` | Host port the container reaches to play sound effects. | [Sound Effects](sound-effects.md) |
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

Beyond the variables above, any `KEY=VALUE` lines in a gitignored `.env` next to
`run.sh` are injected straight into the container via `docker --env-file`. This
is how you pass variables your own workflow needs inside the container — e.g.
`DATABASE_URL`, or `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` to point Claude
at a gateway.

Mind the `--env-file` parsing rules (literal values, no interpolation, no
multiline) and note that the variables `run.sh` sets itself take precedence over
anything in `.env`. See [Passing Environment Variables](passing-env-vars.md) for
the full rules and security notes.
