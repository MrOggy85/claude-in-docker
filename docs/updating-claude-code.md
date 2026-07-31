# Updating Claude Code

The Claude Code version is fixed at **image build time**, not at runtime. Three
pieces decide it:

- **`package.json`** — declares `"@anthropic-ai/claude-code": "latest"`. This is
  only the resolution *target*; it is not the version that gets installed.
- **`package-lock.json`** — the source of truth. It pins the exact version,
  tarball URL, and integrity hash. The `Dockerfile` runs `npm ci` against it, so
  the build always installs exactly what the lock says. The build **fails** if
  the lockfile is missing (no unlocked fallback).
- **`DISABLE_AUTOUPDATER=1`** (`Dockerfile`) — the in-container self-updater is
  off, because the runtime user cannot write to `/usr/local`. The version never
  changes inside a running container; it only moves when you rebump the lock and
  rebuild.

## Update process

```bash
make update-claude      # bump the lockfile pin to the latest published version
git add package-lock.json
git commit -m "chore: update @anthropic-ai/claude-code to <version>"
```

The next time `run.sh` launches, it rebuilds the image automatically:
`context_hash()` in `run.sh` includes `package-lock.json`, so the lock change
invalidates the cached image and triggers a fresh build with the new version.

Confirm the new version afterwards with `claude --version` inside a container.

### Or wait for the weekly PR

`.github/workflows/update-claude.yml` runs the same `make update-claude` every
Monday, builds the image against the new lockfile and runs `claude --version` in
it, then opens (or force-updates) a PR on `chore/update-claude-code`. Merging it
is the whole update. Nothing happens if the pin is already current.

Dependabot cannot cover this: `package.json` says `"latest"`, which every
published version satisfies, so it never sees an update to propose.

### Why not plain `make lockfile`?

`make lockfile` runs `npm install --package-lock-only`, which regenerates the
lock from `package.json` but does **not** upgrade an already-pinned version — npm
treats the locked version as already satisfying the `latest` tag and reports "up
to date". Use it after adding or removing a package, not to upgrade.

`make update-claude` runs `npm update @anthropic-ai/claude-code
--package-lock-only`, which forces re-resolution of the `latest` tag and moves
the lock's pin forward. It leaves `package.json` as `"latest"` — only the lock's
pinned version changes.

## Pinning to a specific version

To install a version other than the newest, edit the pin directly:

```bash
npm install @anthropic-ai/claude-code@<version> --package-lock-only
git checkout package.json      # keep the spec as "latest"; only the lock should change
```

`npm install <pkg>@<version>` rewrites `package.json`'s dependency spec as a side
effect, so revert it — the design keeps `package.json` at `"latest"` and lets the
lockfile do the pinning.
