# Volume-Backed Paths (keep `node_modules` off the host)

The project directory is bind-mounted, so anything an in-container install writes would otherwise
land on the host disk (see [Known Attack
Vectors](attack-vectors.md#untrusted-package-artifacts-on-the-host)). To keep those files **out of
the host filesystem entirely**, the relevant paths are backed by per-project named volumes mounted
at that path inside the container.

`npm install` then writes packages into the volume: inside the container the path is fully populated
and writable, while on the host it appears as an **empty directory** (the mount point).

- Volume names are derived per project and per path (`claude-vol-<dir>-<hash>`) and are **stable**,
  so packages persist across runs.
- A fresh volume is root-owned, so `run.sh` chowns it to your UID on **every** run — not only at
  creation — in one batch container that skips volumes you already own. Asserting it every time is
  what stops a run interrupted between `docker volume create` and the chown from leaving a
  permanently root-owned volume, where installs fail with `EACCES`. It costs one short-lived
  container per run: on Docker Desktop the volume's mountpoint isn't reachable from the host, so
  ownership can only be checked from inside.
- Nesting a volume over the repo bind mount is a standard Docker pattern — the deeper, more-specific
  mount wins for that subtree.

**Single-user assumption.** The volume name has no UID component, so on a shared machine two users
running against the same project path would hand the volume back and forth, each run chowning it to
whoever started it. Ownership is never merged or per-user. Same for the session volume and the
per-project config dir. For multiple users on one host, give each their own
`CLAUDE_DOCKER_CONFIG_DIR` and project checkout.

## Secure by default: every `node_modules` is covered

**On by default.** Each run, `run.sh` scans for every directory containing a `package.json` (pruning
`node_modules` and `.git`) and backs each one's `./node_modules` with its own volume. A
`node_modules` is always a sibling of the `package.json` declaring the deps — the root package and
each workspace package — so `package.json` locations are the complete set of candidates. Non-JS
projects pay one cheap `find` and get no volumes.

- A `package.json` whose deps are fully hoisted won't get a `node_modules`; the path is still backed,
  harmlessly masking an empty dir.
- It keys off `package.json`, so a stray `node_modules` in a directory without one is not covered —
  add it via `CLAUDE_VOLUME_PATHS`.
- If a path already has contents on the host, `run.sh` warns: the volume hides them inside the
  container, but the host copy remains until you delete it.

Detection lives in
[`scripts/find-node-modules-paths.sh`](../scripts/find-node-modules-paths.sh), driven by
[`scripts/path-volumes.sh`](../scripts/path-volumes.sh), which owns everything on this page.

## pnpm

pnpm keeps two directories: `node_modules/.pnpm` (the virtual store, inside the covered path) and a
content-addressable store it **hardlinks** from. That store goes on the same drive as the project,
and in the container `$HOME` (image layer) and the repo (bind mount) are different devices — so
pnpm's default lands at `<repo>/.pnpm-store`, on the host disk, exactly what this feature prevents.

So `run.sh` points the store inside the root `node_modules` volume:

```
npm_config_store_dir=/home/dev/repo/node_modules/.pnpm-store
```

That location keeps the store off the host and persistent, and puts it on the same filesystem as
`node_modules/.pnpm` so pnpm can hardlink into place. A separate volume would be a separate mount,
so `link()` across it fails with `EXDEV` and pnpm silently falls back to copying every package.

- Set only when the root `node_modules` is volume-backed — otherwise the store would be redirected
  onto the host bind mount, worse than the default.
- Workspace packages need nothing special: each has a `package.json`, so the scan already covers its
  `node_modules`. A workspace *root* need not have one, so the presence of `pnpm-lock.yaml` or
  `pnpm-workspace.yaml` also forces the root `node_modules` to be backed.
- `npm_config_store_dir` is npm-style env config: npm and yarn accept and ignore the key, so it's
  inert for non-pnpm projects. Their own caches (`~/.npm`, `~/.cache/yarn`) live in the container
  layer and are discarded each run.
- Deleting `node_modules` deletes the store with it; pnpm refetches. The store is per project, not
  shared.
- pnpm is not in the image. Install it per project via `install_additional_packages.sh`
  (`npm i -g pnpm@<version>`) or corepack.

With `SKIP_CLAUDE_VOLUME_PATHS` set, pnpm's own default takes over and `.pnpm-store` appears in your
project tree on the host.

## Adding more paths — `CLAUDE_VOLUME_PATHS`

To back additional in-repo paths on top of the automatic coverage, set a comma-separated list of
repo-relative paths — e.g. a Deno cache, with `DENO_DIR` pointed at it:

```bash
CLAUDE_VOLUME_PATHS=".deno" run.sh
```

Paths must be repo-relative; absolute paths and `..` escapes are rejected, and entries are
de-duplicated against the automatic coverage. The literal token `auto` re-triggers the
`node_modules` scan explicitly (`CLAUDE_VOLUME_PATHS="auto, .deno"`), though it's redundant.

## Opting out — `SKIP_CLAUDE_VOLUME_PATHS`

Any non-empty value disables all of this. Installs then land on the host as plain bind-mounted
files, and the [attack vectors](attack-vectors.md#untrusted-package-artifacts-on-the-host) apply.

The main reason to opt out is a **host GUI editor**: because the packages aren't on the host, a
host-side language server can't read their type declarations. The default suits editing *inside* the
container (server-in-container or TUI editor), where the language server sees `node_modules`
normally.

Parsing and volume preparation live in
[`scripts/path-volumes.sh`](../scripts/path-volumes.sh), called by `run.sh` at step 3d. It prints one
`docker run` token per line — the `--volume=` mounts plus pnpm's `--env=` — which `run.sh` passes
straight on. Run it standalone from a project dir to see what a session will get.
