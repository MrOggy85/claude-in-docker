# Volume-Backed Paths (keep `node_modules` off the host)

The project directory is bind-mounted, so anything an in-container install
writes — `node_modules/`, caches — would otherwise land on the host disk (see
[Known Attack Vectors](attack-vectors.md#untrusted-package-artifacts-on-the-host)).
To keep those files **out of the host filesystem entirely**, the relevant paths
are backed by per-project named volumes mounted at that path inside the
container.

`npm install` inside the container then writes packages into the volume. Inside
the container the path is fully populated and writable; on the host the same
path appears as an **empty directory** (the mount point) — the package files
exist only in the Docker volume, never in your project tree.

- The volume name is derived per project and per path (`claude-vol-<dir>-<hash>`)
  and is **stable**, so packages persist across runs — no reinstall each session.
- A fresh volume is root-owned, so `run.sh` chowns it to your UID — on **every**
  run, not only at creation, in one batch container that skips the volumes
  already owned by you. Asserting it every time is what keeps a run interrupted
  between `docker volume create` and the chown from leaving a permanently
  root-owned volume, where in-container installs fail with `EACCES`. It costs one
  short-lived container per run — the volume's mountpoint is not reachable from
  the host on Docker Desktop, so ownership can only be checked from inside.
- Nesting a volume over the repo bind mount is a standard Docker pattern. There
  is no mount conflict: the deeper, more-specific mount wins for that subtree.

**Single-user assumption.** These volumes are designed for one host user. The
volume name has no UID component, so a shared machine where two users run against
the same project path would hand the volume back and forth — each run chowns it to
whoever started it, and the other user's next run chowns it back. Ownership is
never merged and never per-user. Same for the session volume and the per-project
config dir. If you need multiple users on one host, give each their own
`CLAUDE_DOCKER_CONFIG_DIR` and project checkout.

## Secure by default: every `node_modules` is covered

This is **on by default** — you don't set anything. On each run, `run.sh` scans
the project for every directory containing a `package.json` (pruning
`node_modules` and `.git`) and backs each one's `./node_modules` with its own
volume. A `node_modules` is always created as a sibling of the `package.json`
that declares the deps — the root package and each workspace package in a
monorepo — so package.json locations are the complete set of potential
`node_modules` locations. The assumption is that the host should hold no
`node_modules` at all. Non-JS projects just pay one cheap `find` and get no
volumes.

Notes:
- A `package.json` whose deps are fully hoisted won't actually get a
  `node_modules`; the path is still backed, harmlessly masking an empty dir.
- It keys off `package.json`, so a stray `node_modules` in a directory without
  one is not covered — add it via `CLAUDE_VOLUME_PATHS` (below).
- If a path already has contents on the host, `run.sh` warns: the volume hides
  them inside the container, but the host copy remains until you delete it.

The detection lives in
[`scripts/find-node-modules-paths.sh`](../scripts/find-node-modules-paths.sh); it is
driven by [`scripts/path-volumes.sh`](../scripts/path-volumes.sh), which owns
everything on this page.

## pnpm

pnpm needs one extra step, because it keeps two directories, not one:
`node_modules/.pnpm` (the virtual store, inside the covered path) and a
content-addressable store it **hardlinks** from. That store is placed on the same
drive as the project, and in the container `$HOME` (image layer) and the repo
(bind mount) are different devices — so pnpm's default lands at
`<repo>/.pnpm-store`, on the host disk, which is precisely what this feature
exists to prevent.

So `run.sh` points the store inside the root `node_modules` volume:

```
npm_config_store_dir=/home/dev/repo/node_modules/.pnpm-store
```

That location is deliberate. It keeps the store off the host and persistent, and
it puts the store on the same filesystem as `node_modules/.pnpm`, so pnpm can
hardlink into place. A separate volume would not: two volumes are separate mounts,
so `link()` between them fails with `EXDEV` and pnpm silently falls back to
copying every package.

Notes:
- Set only when the root `node_modules` is volume-backed — otherwise the store
  would be redirected onto the host bind mount, which is worse than the default.
- Workspace packages need nothing special: each has a `package.json`, so the scan
  already covers its `node_modules` (which pnpm fills with symlinks). A workspace
  root, though, need not have a `package.json` at all, so the presence of
  `pnpm-lock.yaml` or `pnpm-workspace.yaml` also forces the root `node_modules` to
  be backed.
- `npm_config_store_dir` is npm-style env config: npm and yarn accept the key and
  ignore it, so it is inert for non-pnpm projects. Their own caches (`~/.npm`,
  `~/.cache/yarn`) live in the container layer and are still discarded each run.
- Deleting `node_modules` deletes the store with it; pnpm refetches. The store is
  per project, not shared across projects — matching the isolation everything else
  here assumes.
- pnpm is not in the image. Install it per project via
  `install_additional_packages.sh` (`npm i -g pnpm@<version>`) or corepack.

With `SKIP_CLAUDE_VOLUME_PATHS` set none of this applies and pnpm's own default
takes over, so `.pnpm-store` appears in your project tree on the host.

## Adding more paths — `CLAUDE_VOLUME_PATHS`

To back additional in-repo paths on top of the automatic `node_modules`
coverage, set `CLAUDE_VOLUME_PATHS` to a comma-separated list of repo-relative
paths. For example, a Deno cache — point `DENO_DIR` at an in-repo path and add
it:

```bash
CLAUDE_VOLUME_PATHS=".deno" run.sh
```

The literal token `auto` re-triggers the `node_modules` scan if you want it
explicitly alongside other paths (`CLAUDE_VOLUME_PATHS="auto, .deno"`); it is
redundant since the scan already runs by default. Paths must be repo-relative;
absolute paths and `..` escapes are rejected. Entries are de-duplicated against
the automatic coverage.

## Opting out — `SKIP_CLAUDE_VOLUME_PATHS`

Set `SKIP_CLAUDE_VOLUME_PATHS` to any non-empty value (e.g. `1` or `true`) to
disable all of this. Installs then land on the host as plain bind-mounted files,
and the [attack vectors](attack-vectors.md#untrusted-package-artifacts-on-the-host)
apply. The main reason to opt out is editing with a host GUI editor (see below).

## Trade-off: a host editor can't see the types

Because the packages are not on the host, a **host-side** language server cannot
read their type declarations. This default suits editing **inside** the
container (a server-in-container or TUI editor), where the language server runs
where the volume is mounted and sees `node_modules` normally. If you edit with a
host GUI editor that relies on host-side LSP, you need `node_modules` on the host
for type info — opt out with `SKIP_CLAUDE_VOLUME_PATHS=1`.

The parsing and volume preparation live in
[`scripts/path-volumes.sh`](../scripts/path-volumes.sh), called by `run.sh` at
step 3d. It prints one `docker run` token per line — the `--volume=` mounts plus
pnpm's `--env=` — and `run.sh` does nothing with them but pass them on. Run it
standalone from a project dir to see exactly what a session will get.
