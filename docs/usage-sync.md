# Usage Log Synchronization

How Claude Code's transcript logs get from the Docker container to your host
archive at `~/.claude-docker-usage/` so that `ccusage` can read them.

The key point: logs are **not** live-synced. The container writes them into a
per-project Docker volume, and a separate strip-and-copy step extracts a
**cost-only** version of those logs onto the host — either automatically when a
session ends or on demand via `./usage.sh`.

## Where the logs live

Inside the container, Claude Code writes its JSONL transcript logs to
`~/.claude/projects/**/*.jsonl`. But the container's `~/.claude` is **not**
mounted from your host `~/.claude`. Instead, `run.sh` mounts a per-project Docker
volume:

```
--volume "${VOLUME}:/home/dev/.claude"
```

where `VOLUME` is `claude-<project-name>-<hash-of-path>`. Each project gets its
own named volume that persists across runs (`--rm` removes the container but not
the volume). Because the logs never touch your host `~/.claude`, running
`npx ccusage` directly on the host reports `No usage data found`.

## How they reach `~/.claude-docker-usage/`

The sync is a **strip-and-copy** step, not a bind mount. The transform itself
lives in one place — `sync-volume.sh`, which syncs a single volume — and is
invoked from two places:

1. **Automatically after every session** (`run.sh`, step 5). When your `claude`
   session exits, `run.sh` calls `sync-volume.sh` for that session's volume.
   Gated by `CLAUDE_AUTO_USAGE` (default on; set to `0`/`false`/`no`/`off` to
   skip).

2. **On demand via `./usage.sh`**, which calls `sync-volume.sh` for **every**
   `claude-*` volume on the machine, then runs `ccusage` over the combined
   archive.

`sync-volume.sh` starts a short-lived container with the entrypoint overridden
to `sh`, mounting:

```
--volume "${VOLUME}:/data:ro"     # the session volume, read-only
--volume "${ARCHIVE}:/archive"    # ~/.claude-docker-usage, read-write
```

and runs a `jq` script inside it (the image ships `jq`; the host need not) that
writes a sanitized copy of every `*.jsonl` to `/archive/projects/<PROJECT>/`.

## What actually gets copied

It is an **allowlist, not a denylist**. The `jq` filter rebuilds each record from
scratch, keeping only the fields `ccusage` needs to compute cost:

- `timestamp`
- `message.usage` (token counts only)
- `message.model`
- `message.id`, `requestId` (ccusage's dedup keys)
- `costUSD`
- `isApiErrorMessage`
- `cwd`, **rewritten** to `/home/dev/<PROJECT>` — inside the container the
  working dir is always `/home/dev/repo`, which would otherwise collapse every
  project into one entry. The real project name comes from the host directory
  (`run.sh`) or is recovered from the volume name (`usage.sh`).

Any record without `message.usage` is dropped entirely, and a file with any
unparseable line is skipped wholesale. So conversation text, thinking, tool
I/O, file snapshots, and secrets **never leave the volume** — only cost
metadata does.

## Why re-running is safe

The copy only ever **reads** the session volumes (`:ro`), so per-project
resume/isolation is untouched. And `ccusage` dedups by `message.id` /
`requestId`, so re-copying resumed sessions never double-counts. The archive is
created `0700` (owner-only) before anything is written into it.

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

- `CLAUDE_USAGE_DIR` — override the archive location (default `~/.claude-docker-usage`).
- `CLAUDE_AUTO_USAGE` — set to `0`/`false`/`no`/`off` to stop `run.sh` from refreshing the
  archive after each session. By default `./usage.sh` — or `npx ccusage` run against the
  archive — is always current.
- `CCUSAGE_VERSION` — npm version used for the `npx` fallback (default `latest`).

## Requirements and caveats

- **The `claude-code:local` image must exist.** The strip-and-copy runs `jq` inside the image
  (the host need not have it), and the image is built locally by `run.sh` — it cannot be pulled.
  If it is missing (first run, or after an image prune), `sync-volume.sh` exits with a hint to
  run `./run.sh` once to build it.
- **`ccusage` must be available.** `usage.sh` prefers a globally installed `ccusage` and
  otherwise falls back to `npx`. Because the report runs on the host, outside the container's
  firewall, and `npx` executes a third-party package with your user privileges, install and
  audit it once with `npm i -g ccusage` rather than fetching it on every run. The npx fallback
  is pinned to `CCUSAGE_VERSION` (default `latest`); set it to a specific version you have
  vetted. Either path requires Node.js.
- **The archive holds usage metadata only, but still protect it.** Message content and tool
  output are stripped during the copy, so source code, command output, and secrets are not
  written to the host (auth credentials are never copied either). What remains is token counts,
  model names, timestamps, and ids. As defense in depth the archive is created `0700`
  (owner-only); keep it out of cloud-synced folders, untrusted backups, and git repositories,
  and do not point `CLAUDE_USAGE_DIR` into a synced or version-controlled directory. On macOS,
  enabling FileVault encrypts it at rest along with the rest of your disk.
- **Only sessions still held in volumes are included.** The per-project `claude-*` volumes
  persist across runs, but removing a volume discards that history. Note that because each
  session runs with `--rm`, these volumes are not attached to any container between sessions, so
  `docker volume prune` and `docker system prune --volumes` will delete them. Deleting or
  renaming a project also orphans its volume, since the volume name is derived from the project
  path. Run `./usage.sh` before pruning so the archive is up to date first. Because
  `ccusage monthly` groups by date, the archive can safely accumulate across months even after
  the source volumes are removed.
- **Projects are relabelled by host directory name.** The working directory inside the container
  is always `/home/dev/repo`, so Claude Code records every session under the same key. To keep
  the reports readable, the copy files each session under the real project name — taken from the
  host directory (`run.sh`) or recovered from the volume name (`usage.sh`) — and rewrites the
  `cwd` field to match. Two different projects that share the same directory name (in different
  locations) will therefore be merged in the report.
