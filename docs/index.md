# Additional Information

- [MCP Servers](mcp-servers.md) — configure user-level, project-level, and GitHub MCP servers
- [Mounting Extra Folders](mounting-extra-folders.md) — mount additional host folders into the container via `CLAUDE_MOUNTS`
- [Publishing Ports](publishing-ports.md) — expose a server running inside the container to the host via `CLAUDE_PORTS`
- [Volume-Backed Paths](volume-backed-paths.md) — `node_modules` is kept off the host disk by default; add paths via `CLAUDE_VOLUME_PATHS`, opt out via `SKIP_CLAUDE_VOLUME_PATHS`
- [Installing Additional Packages](installing-packages.md) — install extra tools a workflow needs (e.g. Deno) at image build time
- [Sound Effects](sound-effects.md) — play sounds on the host when Claude Code events fire
- [Known Attack Vectors](attack-vectors.md) — threats not handled by this solution
- [Tracking Usage (ccusage)](tracking-usage.md) — report token usage across all projects with `ccusage`
- [Usage Log Synchronization](usage-sync.md) — how transcript logs reach `~/.claude-docker-usage/` for `ccusage`
