# Project: claude-in-docker

Project instructions for working **on this repository** — a wrapper that runs
Claude Code inside a hardened Docker container as the host user. Not to be
confused with `container-CLAUDE.md`, which is the user's personal CLAUDE.md
mounted *into* the container at `~/.claude/CLAUDE.md`.

See `README.md` for setup, usage, and a fuller description of the project.

## Layout
- `run.sh` — entrypoint: builds the image on context change, derives the
  per-project session volume and a unique container name, assembles mounts, runs
  `claude`, then syncs usage. The most important file to understand.
- `Dockerfile`, `entrypoint.sh`, `init-firewall.sh`, `allowed-domains.txt` —
  image build context; their hash gates rebuilds (`run.sh` `context_hash`).
- `scripts/extra-mounts.sh` — turns `CLAUDE_MOUNTS` into `--volume` tokens.
- `guards/` — pre-flight security gates, each `source`d by `run.sh` so it can
  `exit` the run before any build/container work (home-dir, project-settings,
  MCP token read-only check). Add new guards here, not inline in `run.sh`.
- `sync-volume.sh` / `usage.sh` — copy per-session usage records out of the
  volume for `ccusage`, keeping only cost fields (no conversation content).
- `templates/` + `Makefile` (`make init`) — user-local config is copied from the
  committed templates in `templates/` into the repo root and gitignored. Edit the
  file in `templates/` when changing defaults.
- `docs/` — feature guides.
