# Mounting Extra Folders

By default `run.sh` mounts only the current directory, at `/home/dev/repo`. To make additional host folders visible inside the container, set `CLAUDE_MOUNTS` to a comma-separated list. Each entry is mounted **read-only** at `/home/dev/<basename>`:

```bash
CLAUDE_MOUNTS="~/shared-lib,../sibling-repo" run.sh
# -> /home/dev/shared-lib (ro), /home/dev/sibling-repo (ro)
```

- Append `:rw` to an entry to make it writable (`:ro` is accepted to be explicit): `CLAUDE_MOUNTS="~/scratch:rw"`.
- Paths may use `~` and may be relative (resolved against the directory you launch from).
- Entries that don't exist, that collide with a reserved target (`repo`, `.claude`), or that map to an already-used basename are skipped with a warning.
- The per-project session volume and usage tracking still key off the primary repo (the current directory) only — extra mounts don't create or affect session state.

Using `CLAUDE_MOUNTS` instead of a flag keeps every CLI argument free to pass through to `claude`.

The parsing lives in [`scripts/extra-mounts.sh`](../scripts/extra-mounts.sh), which `run.sh` calls to turn `CLAUDE_MOUNTS` into `docker run --volume` arguments.
