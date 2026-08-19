# Usage Log Synchronization

How Claude Code's transcript logs get from the container to `~/.claude-docker-usage/` for `ccusage`.

Logs are **not** live-synced. The container writes them into a per-project Docker volume, and a
separate strip-and-copy step extracts a **cost-only** version onto the host — automatically when a
session ends, or on demand via `./usage.sh`.

## Where the logs live

Claude Code writes JSONL transcripts to `~/.claude/projects/**/*.jsonl`, but the container's
`~/.claude` is a per-project Docker volume, not your host `~/.claude`:

```
--volume "${VOLUME}:/home/dev/.claude"
```

`VOLUME` is `claude-<project-name>-<hash-of-path>` and persists across runs (`--rm` removes the
container, not the volume). Since the logs never touch your host `~/.claude`, `npx ccusage` on the
host reports `No usage data found`.

## How they reach `~/.claude-docker-usage/`

The transform lives in one place — `sync-volume.sh`, which syncs a single volume — invoked from two:

1. **After every session** (`run.sh`, step 5), for that session's volume. Gated by
   `CLAUDE_AUTO_USAGE` (default on).
2. **On demand via `./usage.sh`**, for **every** `claude-*` volume on the machine, then `ccusage`
   over the combined archive.

`sync-volume.sh` starts a short-lived container with the entrypoint overridden to `sh`, mounting:

```
--volume "${VOLUME}:/data:ro"     # the session volume, read-only
--volume "${ARCHIVE}:/archive"    # ~/.claude-docker-usage, read-write
```

and runs a `jq` script inside it (the image ships `jq`; the host need not) that writes a sanitized
copy of every `*.jsonl` to `/archive/projects/<PROJECT>/`.

## What actually gets copied

An **allowlist, not a denylist**. The `jq` filter rebuilds each record from scratch, keeping only
what `ccusage` needs:

- `timestamp`
- `message.usage` (token counts only)
- `message.model`
- `message.id`, `requestId` (ccusage's dedup keys)
- `costUSD`
- `isApiErrorMessage`
- `cwd`, **rewritten** to `/home/dev/<PROJECT>` — the container's working dir is always
  `/home/dev/repo`, which would otherwise collapse every project into one entry. The real name comes
  from the host directory (`run.sh`) or the volume name (`usage.sh`).

Records without `message.usage` are dropped, and a file with any unparseable line is skipped
wholesale. Conversation text, thinking, tool I/O, file snapshots, and secrets **never leave the
volume**.

## Why re-running is safe

The copy only ever **reads** the session volumes (`:ro`), so per-project resume/isolation is
untouched, and `ccusage` dedups by `message.id` / `requestId`, so resumed sessions never
double-count. The archive is created `0700` before anything is written to it.

## Flow summary

```
container: ~/.claude/projects/**/*.jsonl   (Docker volume claude-<proj>-<hash>)
        │
        │  sync-volume.sh: jq allowlist strip + cwd relabel
        │  (run.sh on exit, or usage.sh on demand)
        ▼
host: ~/.claude-docker-usage/projects/<proj>/*.jsonl   (metadata only, 0700)
        │
        ▼
   ccusage  →  cost report
```

## Environment variables

- `CLAUDE_USAGE_DIR` — archive location (default `~/.claude-docker-usage`).
- `CLAUDE_AUTO_USAGE` — `0`/`false`/`no`/`off` stops `run.sh` refreshing the archive after each
  session. On by default, so the archive is always current.
- `CCUSAGE_VERSION` — npm version for the `npx` fallback (default `latest`).

## Requirements and caveats

- **The `claude-code:local` image must exist.** The strip-and-copy runs `jq` inside it, and the
  image is built locally by `run.sh` — it cannot be pulled. If missing (first run, or after a
  prune), `sync-volume.sh` exits with a hint to run `./run.sh` once.
- **`ccusage` must be available.** `usage.sh` prefers a globally installed one and falls back to
  `npx`. The report runs on the host, outside the container's firewall, and `npx` executes a
  third-party package with your privileges — so install and audit it once with `npm i -g ccusage`
  rather than fetching per run. The fallback is pinned to `CCUSAGE_VERSION` (default `latest`); set
  it to a version you have vetted. Either path needs Node.js.
- **The archive holds usage metadata only, but still protect it.** Message content and tool output
  are stripped during the copy, and credentials are never copied; what remains is token counts,
  model names, timestamps, and ids. The archive is created `0700` as defense in depth — keep it out
  of cloud-synced folders, untrusted backups, and git repos, and don't point `CLAUDE_USAGE_DIR` at
  one. On macOS, FileVault encrypts it at rest.
- **Only sessions still held in volumes are included.** Removing a volume discards that history.
  Each session runs with `--rm`, so these volumes are unattached between sessions and `docker volume
  prune` / `docker system prune --volumes` will delete them. Deleting or renaming a project also
  orphans its volume, since the name derives from the project path. Run `./usage.sh` before pruning.
  Because `ccusage monthly` groups by date, the archive safely accumulates across months even after
  the source volumes are gone.
- **Projects are relabelled by host directory name.** Claude Code records every session under
  `/home/dev/repo`, so the copy files each under the real project name and rewrites `cwd` to match.
  Two projects sharing a directory name in different locations will therefore merge in the report.
