# Additional Information

- [Centralized Egress Proxy](egress-proxy.md) — the network boundary: every container egresses through one shared Squid proxy that filters by hostname per project, with a thin nftables rule locking egress to the proxy
- [MCP Servers](mcp-servers.md) — configure user-level, project-level, and GitHub MCP servers
- [Mounting Extra Folders](mounting-extra-folders.md) — mount additional host folders into the container via `CLAUDE_MOUNTS`
- [Publishing Ports](publishing-ports.md) — expose a server running inside the container to the host via `CLAUDE_PORTS`
- [Passing Environment Variables](passing-env-vars.md) — inject arbitrary env vars into the container via a `.env` file in the config dir
- [Per-Project Launch Config](per-project-env.md) — keep per-repo mounts, ports, and secrets in a gitignored `.claude-env` sourced at launch
- [Volume-Backed Paths](volume-backed-paths.md) — `node_modules` is kept off the host disk by default; add paths via `CLAUDE_VOLUME_PATHS`, opt out via `SKIP_CLAUDE_VOLUME_PATHS`
- [Installing Additional Packages](installing-packages.md) — install extra tools a workflow needs (e.g. Deno) at image build time
- [Host Path in the Status Line](host-path-statusline.md) — show which host folder a session belongs to via `CLAUDE_HOST_PROJECT_DIR`
- [Sound Effects](sound-effects.md) — play sounds on the host when Claude Code events fire
- [Chrome DevTools MCP](chrome-devtools-mcp.md) — run the `chrome-devtools-mcp` server on the host and reach it from the container over HTTP, so Claude can drive a real browser
- [Devcontainers Alternative](devcontainers.md) — using Dev Containers / Codespaces with a squid proxy sidecar instead of `run.sh`
- [How This Compares to Alternatives](comparison.md) — how this project compares to the devcontainer convention, lightweight recipes, and claudebox, and when to pick each
- [Known Attack Vectors](attack-vectors.md) — threats not handled by this solution
- [Tracking Usage (ccusage)](tracking-usage.md) — report token usage across all projects with `ccusage`
- [Usage Log Synchronization](usage-sync.md) — how transcript logs reach `~/.claude-docker-usage/` for `ccusage`
- [Environment Variables](environment-variables.md) — reference for every environment variable this project reads or sets
