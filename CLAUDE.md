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
`cid`. Per-project overrides live under `<config-dir>/projects/<key>/`. Two
files are exceptions, both because they are baked into the image at build time
and the Docker build context is the repo dir: `install_additional_packages.sh`
(the user's own) and `egress-ca.crt` (derived — `run.sh` copies the public half
of `<config-dir>/ca/ca.crt` there every run). Both are gitignored.

## Comments
In general keep any comments very breif while still informative

`run.sh` is the orchestrator; the detail lives in the files it sources and links
(`guards/*`, `scripts/paths.sh`, `proxy/`, `docs/`). When a sourced or referenced
file already carries the full explanation, keep the comment at the call site
brief — one line on what happens and why, plus a pointer ("see the guard file",
"see docs/egress-proxy.md"). Do not restate the linked file's description inline;
that duplication drifts out of sync. Put the authoritative description in the
sourced file, not in `run.sh`.

## Docs
Brevity comes from cutting prose, never facts. `docs/` was tightened to this
standard in f6b85b1 (24 guides, 21,873 -> 18,698 words); read
`docs/publishing-ports.md` for the target density before writing or editing a
guide. Every technical claim, table row, code block, command, env var and caveat
stays. What goes:
- the intro that restates the title, and the closing paragraph that restates the
  body
- explanation duplicated from the file or doc already linked — name the link and
  stop (the `## Comments` rule above, applied to prose)
- a fact's second phrasing ("use a port >=1024" then "cannot bind privileged
  ports (<1024)")
- hedging, and parenthetical examples that add no constraint

Then try to cut 15% of the words with no fact lost; if that succeeds, it was not
finished. `/tighten-docs` runs this pass and proves the "no fact lost" half
mechanically.

Wrap prose at 100 columns in `docs/`, 80 in `CLAUDE.md`, `README.md` and
`skills/*/SKILL.md`. Never leave a 600-character single-line paragraph — make it
wrapped bullets.

## Layout
- `run.sh` — entrypoint: builds the image on context change, derives the
  per-project session volume and a unique container name, assembles mounts, runs
  `claude`, then syncs usage. The most important file to understand.
- `scripts/paths.sh` — sourced helper: `config_dir()`, `projects_dir()`,
  `path_hash()`, `safe_name()`, `project_key()`. Change config-location or
  key-derivation logic here, never inline.
- `scripts/colors.sh` — sourced helper owning terminal colour: the
  NO_COLOR/CLICOLOR_FORCE/TERM/tty precedence (`color_init <info-fd>`, decided
  per stream) and the emitters every run-time message goes through
  (`say`/`kv`/`ok` on the info fd, `warn`/`fail`/`cont` on stderr). Change how a
  message looks here, never at the call site. `init-firewall.sh` carries the one
  deliberate copy — it runs inside the image, where this file does not exist.
- `scripts/notify.sh` — sourced helper owning host desktop notifications, the way
  `colors.sh` owns terminal output: `notify_init <log>` picks the backend
  (CLAUDE_NOTIFY_CMD, then macOS `osascript`, then `notify-send`, then log-only)
  and `notify <info|alert> <title> <body>` emits, always also appending to the
  alert log. `info` auto-dismisses, `alert` does not. It strips every character
  outside a safe charset first — its input carries an attacker-chosen hostname
  headed for an AppleScript string, so that sanitisation stays HERE, not at the
  call sites. Only `proxy/watch.sh` sources it. See docs/egress-alerts.md.
- `cid` — the config CLI. Read-only viewers (`list` / `show` / `project` /
  `domains` / `skip-decryption` / `containers` / `settings` / `ca` / `watch` /
  `hosts` / `env`) plus
  in-place allowlist editing (`domains add|rm <host>`,
  `skip-decryption add|rm <host>`,
  `containers add|rm <name>`, `settings trust|untrust <rule>`, `-g` for the
  shared baseline, `-C dir` to pick the project; all four share `_resolve_target` +
  `_entries_add`/`_entries_rm`, so add a kind there rather than duplicating).
  `watch` operates `proxy/watch.sh` and reads its alert log; `hosts` shows and
  clears one project's `seen-hosts.txt`. `env` lists the settable host env vars
  (terminal mirror of
  docs/environment-variables.md — keep the ENV_VARS list in sync). Meant to go on
  `$PATH`; ships a zsh completion in `completions/_cid`. See docs/config-cli.md.
- `scripts/migrate-config.sh` — `make migrate`: moves a pre-existing repo-root
  config (and per-project dirs) into the config dir, non-destructively.
- `scripts/release.sh` — `make release`: derives the next version from the
  Conventional Commits since the last tag, prepends a `CHANGELOG.md` section,
  commits it and annotates the tag. The annotated TAG is the only version store —
  no `VERSION` file, and no `version` field in `package.json` (that file is the
  image's npm manifest). Never pushes: the tag push is what fires `release.yml`.
  Operates on the git repo containing `$PWD`, not on its own location, so it is
  testable and can be pointed at a scratch clone. See docs/releasing.md.
- `Dockerfile`, `entrypoint.sh`, `init-firewall.sh`, `egress-ca.crt` — image
  build context; their hash gates rebuilds (`run.sh` `context_hash`), so rotating
  the CA rebuilds. `init-firewall.sh` is the thin in-container egress-lock: it
  confines outbound traffic to the Squid proxy and nothing else (all allowlist
  policy lives in Squid, see `proxy/`).
- `proxy/` — the shared Squid egress proxy: the sole path out for every
  container. `up.sh` builds the image (`Dockerfile` + `entrypoint.sh`: Debian's
  plain `squid` rejects `ssl_bump`, so `squid-openssl` it is) and brings it up;
  `squid.conf` + `ext-allowlist.sh` enforce each project's `allowed-domains.txt`
  by hostname — and, for a decrypted request, by path and method too — and decide
  whether to decrypt. `watch.sh` is the detection half and
  the only host-side file here: `run.sh` starts it per run, it tails
  `docker logs -f` on the proxy and notifies on a first-time or denied host. Its
  `process` verb is the whole classifier — access-log lines in, alert lines out,
  no docker — so keep new parsing there, where test/watch.bats can reach it. It
  tells a denied CONNECT (unlisted host) from a `403` inside a tunnel (a path or
  method rule refused it) because the suggested fix differs and one must never be
  offered for the other. Being
  outside the container is the point; nothing about this may move inside one. See
  `docs/egress-proxy.md`, `docs/tls-inspection.md` and `docs/egress-alerts.md`.
- `scripts/gen-ca.sh` — `make ca`: the CA Squid signs intercepted TLS with, in
  `<config-dir>/ca/`. `ca.key` goes only to the proxy container; `ca.crt` also
  goes into the image trust store. Interception is mandatory —
  `guards/egress-ca.sh` aborts the run without a valid CA. See
  `docs/tls-inspection.md`.
- `allowed-domains.txt` — the egress allowlist, read live by Squid (not baked
  into the image). The baseline copy lives at `<config-dir>/allowed-domains.txt`;
  `<config-dir>/projects/<key>/allowed-domains.txt` is the per-project list. An
  entry is `[METHOD[,METHOD] ]<host>[/path]`; the grammar's one authoritative
  description is `docs/egress-proxy.md#entry-syntax`, mirrored in
  `ext-allowlist.sh`'s `match_in_file` and `cid`'s `_valid_domain_entry` — change
  all three together. `skip-decryption.txt` has the same layout and TTL but only
  the hostname half of the grammar, and answers a different question: which hosts
  Squid must NOT decrypt.
  `docker-containers.txt` follows the same baseline+per-project layout for the
  docker bridge, read per call instead of on a TTL, and so does
  `trusted-settings-rules.txt` (permission rules the settings guard must not
  flag), read per run. Two are per-project only, no baseline, and WRITTEN rather
  than read as policy: `seen-hosts.txt` (by `proxy/watch.sh`) records what has
  been contacted, not what is permitted; `mounts.txt` (by `run.sh`, only with the
  chrome bridge on) records `<container>\t<host>` for each read-write bind mount
  so the bridge can translate paths — ro mounts stay out, or the agent could
  write through the host bridge to a path its container is denied.
- `skills/sandbox/` — the one thing mounted *for* the session rather than the
  user: an on-demand skill (`SKILL.md` + `sandbox-info.sh`) reporting this
  session's published host↔container ports, mounts, volume-backed paths, egress
  policy and what it may install. Static toolchain facts belong in `SKILL.md`,
  per-session ones in the script — keep that split. Mounted ro at
  `~/.claude/skills/sandbox` (a bind nested under the session volume), gated by
  `CLAUDE_SANDBOX_INFO`. `sandbox-info.sh` runs INSIDE the container, so like
  `init-firewall.sh` it is self-contained (no `scripts/colors.sh`) and reads only
  env vars `run.sh` sets — never secret values. Nothing is baked into the image,
  so edits apply next run. See docs/sandbox-info.md.
- `scripts/extra-mounts.sh` — turns `CLAUDE_MOUNTS` into `--volume` tokens.
- `scripts/path-volumes.sh` — owns the volume-backed in-repo paths: the automatic
  `node_modules` coverage (via `find-node-modules-paths.sh`), `CLAUDE_VOLUME_PATHS`,
  volume creation, the per-run ownership pass, and pnpm's store. Prints one
  `docker run` token per line (`--volume=`, plus one `--env=` for pnpm) and is
  called by `run.sh` (step 3d) via command substitution, so a failure there aborts
  the run. See docs/volume-backed-paths.md.
- `scripts/resource-limits.sh` — owns the container's memory/CPU/pids caps: the
  defaults derived from `docker info` (so Docker Desktop's VM, not the Mac's
  RAM), the validation, and swap-off-by-default. Prints one `docker run` token
  per line like `path-volumes.sh`, called by `run.sh` (step 3g) via command
  substitution, so a malformed `CLAUDE_MEMORY` aborts the run rather than
  starting an uncapped container. The proxy's own caps are inline in
  `proxy/up.sh` — a known, bounded workload needs no derivation. See
  docs/resource-limits.md.
- `scripts/scan-project-settings.sh` — classifies a project's
  `.claude/settings*.json` by capability (dependency-free: a literal key scan
  plus an awk JSON walk, both fail-closed). Backs both
  `guards/project-settings.sh` and `cid settings`; the risky-command and
  dangerous-key lists live at the top of it, and `--render` holds the one copy of
  the grouped output both callers print. See docs/attack-vectors.md.
- `guards/` — pre-flight security gates, each `source`d by `run.sh` so it can
  `exit` the run before any build/container work (home-dir, project-settings,
  MCP token no-code-push check, docker bridge, chrome bridge, egress CA). Add new
  guards here, not inline in `run.sh`.
  `project-settings.sh` prompts only about what the scanner flags and remembers
  the approved risk digest per project, so an unchanged profile never re-asks.
- `sync-volume.sh` / `usage.sh` — copy per-session usage records out of the
  volume for `ccusage`, keeping only cost fields (no conversation content).
- `templates/` + `Makefile` (`make init`) — user-local config is copied from the
  committed templates in `templates/` into the config dir. Edit the file in
  `templates/` when changing defaults.
- `docker-bridge/` — host-side bridge (third of the family, same four-file shape
  as `chrome-devtools-mcp/`): a zero-dep Node MCP server exposing read-only
  `docker_ps` / `docker_logs` / `docker_stats` over Streamable HTTP. Not a stdio
  proxy — it answers MCP itself and spawns one `docker` per call. Enforcement is
  host-side and in this order: bearer token (which also selects the project's
  allowlist), per-project `docker-containers.txt`, fixed argv. Opt-in via
  `CLAUDE_DOCKER_BRIDGE=1`; sanity-checked by `guards/docker-bridge.sh`. No
  mutating verb exists — see docs/docker-bridge.md.
- `chrome-devtools-mcp/` — host-side bridge (the four-file shape again, plus a
  `Makefile` wrapping launchctl: `install` rewrites the plist's path to this
  checkout, `restart`/`status`/`log`/`profiles` operate the running agent): an
  nvm-sourcing launcher + a macOS launchd plist that run a small zero-dep Node
  bridge (`host-chrome-devtools-mcp.js`) which spawns the stdio `chrome-devtools-mcp`
  server on the host and re-exposes it over MCP Streamable HTTP; the container
  reaches it via `host.docker.internal` on a host-outbound port. Auth and session
  routing are lifted from `docker-bridge/` — a per-project bearer token names the
  project, an `X-Claude-Profile` label names a Chrome profile inside it
  (`~/.cache/claude-in-docker/chrome-profiles/<key>/<label>`), and one session per
  browser means concurrent containers no longer evict each other. It is a
  transparent JSON-RPC pipe with ONE exception: filesystem paths. The client is
  in a container and the server is not, so `roots/list` answers, `tools/call`
  `filePath`s and the saved-path text in results are rewritten across
  `mounts.txt` — the container's spelling is the only one Claude ever sees,
  and keeping it that way is the point (a model told to switch spellings
  mid-task will not). Opt-in via `CLAUDE_CHROME_DEVTOOLS=1`. See
  docs/chrome-devtools-mcp.md.
- `docs/` — feature guides.
- `.claude/commands/` — committed slash commands (`/tighten-docs`); the only
  negation in `.gitignore`'s `.claude/*` rule. Prompts only: never add a settings
  file or anything granting a permission, since a clone gets whatever is here.
- `.github/workflows/` — CI. `test.yml` runs bats (ubuntu + macOS) and
  `make lint` on every non-doc change; both are gates, so run `make test` and
  `make lint` before pushing. `image.yml` builds the image weekly and on
  Dockerfile/lockfile changes — the image is the one thing here that rots with no
  commit behind it. `update-claude.yml` opens the weekly claude-code bump PR
  (Dependabot cannot: package.json pins `"latest"`). `release.yml` fires on a
  `v*` tag push and turns that tag's `CHANGELOG.md` section into a GitHub
  Release; it derives nothing, so a tag/changelog mismatch fails the run.
- `.github/PULL_REQUEST_TEMPLATE/` — `feature.md` and `bugfix.md`. GitHub picks
  neither on its own: a directory of templates is reachable only through
  `?template=<file>` on the compare URL, and there is no default
  `pull_request_template.md` on purpose (a wrong-shaped default gets deleted by
  hand every time). Both close on the breaking-change footer, and both say the
  same load-bearing thing: the PR BODY never reaches `scripts/release.sh`. We
  squash-merge, so the PR title becomes the commit subject but GitHub builds the
  squash body from the branch's commit messages — a `BREAKING CHANGE:` footer
  has to live in a commit, and a `## Breaking Change` heading flags nothing. The
  `!` in the title is what actually forces the major bump.
