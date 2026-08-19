# Updating Claude Code

The Claude Code version is fixed at **image build time**. Three pieces decide it:

- **`package.json`** — declares `"@anthropic-ai/claude-code": "latest"`. Only the resolution
  *target*, not the installed version.
- **`package-lock.json`** — the source of truth: exact version, tarball URL, integrity hash. The
  `Dockerfile` runs `npm ci` against it, and the build **fails** if the lockfile is missing (no
  unlocked fallback).
- **`DISABLE_AUTOUPDATER=1`** (`Dockerfile`) — the in-container self-updater is off, since the
  runtime user cannot write to `/usr/local`. The version only moves when you rebump the lock and
  rebuild.

## Update process

```bash
make update-claude      # bump the lockfile pin to the latest published version
git add package-lock.json
git commit -m "chore: update @anthropic-ai/claude-code to <version>"
```

The next `run.sh` rebuilds automatically: `context_hash()` includes `package-lock.json`, so the lock
change invalidates the cached image. Confirm afterwards with `claude --version` in a container.

### Or wait for the weekly PR

`.github/workflows/update-claude.yml` runs the same `make update-claude` every Monday, builds the
image against the new lockfile, runs `claude --version` in it, then opens (or force-updates) a PR on
`chore/update-claude-code`. Merging it is the whole update; nothing happens if the pin is current.

Dependabot cannot cover this: `package.json` says `"latest"`, which every published version
satisfies, so it never sees an update to propose.

### Why not plain `make lockfile`?

`make lockfile` runs `npm install --package-lock-only`, which regenerates the lock from
`package.json` but does **not** upgrade an already-pinned version — npm treats the locked version as
satisfying `latest` and reports "up to date". Use it after adding or removing a package.

`make update-claude` runs `npm update @anthropic-ai/claude-code --package-lock-only`, forcing
re-resolution of the `latest` tag. It leaves `package.json` alone; only the lock's pin moves.

## Pinning to a specific version

```bash
npm install @anthropic-ai/claude-code@<version> --package-lock-only
git checkout package.json      # keep the spec as "latest"; only the lock should change
```

`npm install <pkg>@<version>` rewrites `package.json`'s dependency spec as a side effect, so revert
it — the design keeps `package.json` at `"latest"` and lets the lockfile pin.
