# Project: claude-in-docker

Project instructions for working **on this repository** — a wrapper that runs
Claude Code inside a hardened Docker container as the host user. Not to be
confused with `container-CLAUDE.md`, which is the user's personal CLAUDE.md
mounted *into* the container at `~/.claude/CLAUDE.md`.

See `README.md` for setup, usage, and a fuller description of the project.

## Config location
All user-managed config lives OUTSIDE the repo, in a dedicated XDG-style dir
(`~/.config/claude-in-docker/` by default; override with `CLAUDE_DOCKER_CONFIG_DIR`
or `XDG_CONFIG_HOME`). `scripts/paths.sh` is the single source of truth for that
location and for the per-project key, shared by `run.sh`, `proxy/up.sh`, and
`config.sh`. Per-project overrides live under `<config-dir>/projects/<key>/`. The
one exception is `install_additional_packages.sh`, which stays in the repo because
it is baked into the image at build time (Docker build context = repo dir).

## Comments
In general keep any comments very breif while still informative

`run.sh` is the orchestrator; the detail lives in the files it sources and links
(`guards/*`, `scripts/paths.sh`, `proxy/`, `docs/`). When a sourced or referenced
file already carries the full explanation, keep the comment at the call site
brief — one line on what happens and why, plus a pointer ("see the guard file",
"see docs/egress-proxy.md"). Do not restate the linked file's description inline;
that duplication drifts out of sync. Put the authoritative description in the
sourced file, not in `run.sh`.

## Layout
- `run.sh` — entrypoint: builds the image on context change, derives the
  per-project session volume and a unique container name, assembles mounts, runs
  `claude`, then syncs usage. The most important file to understand.
- `scripts/paths.sh` — sourced helper: `config_dir()`, `projects_dir()`,
  `path_hash()`, `safe_name()`, `project_key()`. Change config-location or
  key-derivation logic here, never inline.
- `config.sh` — read-only CLI to view config (`list` / `show` / `project` /
  `domains`). Users edit the files by hand; this just helps them find/inspect them.
- `scripts/migrate-config.sh` — `make migrate`: moves a pre-existing repo-root
  config (and per-project dirs) into the config dir, non-destructively.
- `Dockerfile`, `entrypoint.sh`, `init-firewall.sh` — image build context; their
  hash gates rebuilds (`run.sh` `context_hash`). `init-firewall.sh` is the thin
  in-container egress-lock: it confines outbound traffic to the Squid proxy and
  nothing else (all allowlist policy lives in Squid, see `proxy/`).
- `proxy/` — the shared Squid egress proxy: the sole path out for every
  container. `up.sh` brings it up; `squid.conf` + `ext-allowlist.sh` enforce each
  project's `allowed-domains.txt` by CONNECT hostname. See `docs/egress-proxy.md`.
- `allowed-domains.txt` — the egress allowlist, read live by Squid (not baked
  into the image). The baseline copy lives at `<config-dir>/allowed-domains.txt`;
  `<config-dir>/projects/<key>/allowed-domains.txt` is the per-project list.
- `scripts/extra-mounts.sh` — turns `CLAUDE_MOUNTS` into `--volume` tokens.
- `guards/` — pre-flight security gates, each `source`d by `run.sh` so it can
  `exit` the run before any build/container work (home-dir, project-settings,
  MCP token read-only check). Add new guards here, not inline in `run.sh`.
- `sync-volume.sh` / `usage.sh` — copy per-session usage records out of the
  volume for `ccusage`, keeping only cost fields (no conversation content).
- `templates/` + `Makefile` (`make init`) — user-local config is copied from the
  committed templates in `templates/` into the config dir. Edit the file in
  `templates/` when changing defaults.
- `docs/` — feature guides.
