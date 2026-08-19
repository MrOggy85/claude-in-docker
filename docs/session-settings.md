# Changing Settings for One Session

Slash commands that persist a user-level setting into `settings.json` — `/effort` is the one you'll
hit first — fail inside the container:

```
❯ /effort low
  ⎿  Failed to set effort level: Failed to read raw settings from /home/dev/.claude/settings.json:
     Error: EBUSY: resource busy or locked, rename
     '/home/dev/.claude/settings.json.tmp.1.de9fb3007177' -> '/home/dev/.claude/settings.json'
```

Pass the equivalent flag to `run.sh` instead — it applies to that session only:

```sh
./run.sh --effort low
```

## Why the write fails

`run.sh` bind-mounts your config-dir `settings.json` as a **single file** on top of the session
volume:

```sh
add_ro_mount "${CONFIG_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"
```

Claude Code writes settings atomically: temp file next to the target, then `rename(2)`. The temp
file lands in `~/.claude`, which is the writable session volume, so that part succeeds — but
`rename(2)` onto a **mount point** returns `EBUSY` on Linux unconditionally. The `:ro` flag is a
second, independent blocker; mounting read-write would not help.

Keeping it read-only is deliberate (see [Known Attack Vectors](attack-vectors.md)): a session cannot
rewrite its own global settings — adding a hook, say — in a way that outlives the container.

## Flags instead of slash commands

Arguments to `run.sh` are forwarded verbatim to `claude`, so anything the CLI exposes as a flag is
available per session without touching a file:

| Instead of | Launch with |
| --- | --- |
| `/effort low` | `./run.sh --effort low` (`low`, `medium`, `high`, `xhigh`, `max`) |
| any other `settings.json` key | `./run.sh --settings '{"effortLevel":"low"}'` |

`--settings` takes a JSON string or a path and loads those settings for the session, which covers
keys with no dedicated flag. Note `--effort` accepts `max` while the persisted `effortLevel` setting
stops at `xhigh`.

Only commands that **persist** a key are affected. Anything that is session runtime state —
permission mode, for example, whether toggled with <kbd>Shift</kbd>+<kbd>Tab</kbd> or passed as
`--permission-mode` — never touches `settings.json` and works normally.

There is no mid-session equivalent: once the container is up, `/effort` will keep returning `EBUSY`.
Relaunch with the flag.

## Changing the default for every session

`/effort` is not session-scoped even outside the container — it writes `effortLevel` into user
settings, so every future session inherits it. To get that behaviour here, edit the host file
directly:

```sh
cid show settings.json          # print it
$EDITOR ~/.config/claude-in-docker/settings.json
```

```json
{
  "effortLevel": "low"
}
```

It's read live from the host on each launch, so the change applies to the next session — no rebuild.
