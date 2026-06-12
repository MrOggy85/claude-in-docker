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
- A fresh volume is root-owned; `run.sh` chowns it to your UID once on creation,
  so the non-root container user can write to it.
- Nesting a volume over the repo bind mount is a standard Docker pattern. There
  is no mount conflict: the deeper, more-specific mount wins for that subtree.

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
[`scripts/find-node-modules-paths.sh`](../scripts/find-node-modules-paths.sh).

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

The parsing and volume preparation live in `run.sh` (step 3d).
