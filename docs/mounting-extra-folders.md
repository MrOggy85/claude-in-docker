# Mounting Extra Folders

By default `run.sh` mounts only the current directory, at `/home/dev/repo`. Set `CLAUDE_MOUNTS` to a comma-separated list to add more. Each entry is mounted **read-only** at `/home/dev/<basename>`:

```bash
CLAUDE_MOUNTS="~/shared-lib,../sibling-repo" run.sh
# -> /home/dev/shared-lib (ro), /home/dev/sibling-repo (ro)
```

- Append `:rw` to make an entry writable (`:ro` is accepted to be explicit): `CLAUDE_MOUNTS="~/scratch:rw"`.
- Paths may use `~` and may be relative (resolved against the launch directory).
- Entries that don't exist, collide with a reserved target (`repo`, `.claude`), or reuse a basename are skipped with a warning.
- Session state and usage tracking key off the primary repo only — extra mounts don't affect them.

An env var rather than a flag keeps every CLI argument free to pass through to `claude`. Parsing lives in [`scripts/extra-mounts.sh`](../scripts/extra-mounts.sh).
