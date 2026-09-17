# Remote Sessions

`CLAUDE_REMOTE=1` detaches the container and hands the session to claude.ai/code and the Claude
mobile app, freeing your terminal:

```bash
CLAUDE_REMOTE=1 run.sh
# -> container claude-repo-3f2a started; your shell is free
```

Detaching and Remote Control are one switch because they are useless apart: nothing reads a
detached pty, so a detached session with no bridge could only be reached with `docker attach`.

`run.sh` passes `--remote-control <container-name>` for you, so the name in the Claude app, in
`docker ps` and in the status line is one string. Pass `--remote-control <name>` yourself to
choose it:

```bash
CLAUDE_REMOTE=1 run.sh --remote-control laptop
```

Pin the container name with `CLAUDE_CONTAINER_NAME` if you prefer the default to be readable;
`run.sh` supports concurrent sessions in one folder, sharing the session volume.

## Ending a session

`/remote-control` in the Claude app only disconnects the bridge. To end the session, `/exit` from
the app, or from the host:

```bash
docker stop claude-repo-3f2a
```

`--rm` still applies, so stopping removes the container.

## What stays in your terminal

Everything before `docker run`: the image build, the guards, and every `kv` line. This is
deliberate. [`guards/project-settings.sh`](../guards/project-settings.sh) prompts for a keypress
on `/dev/tty`, and a pane nobody is watching has a working `/dev/tty` — it would block unseen
rather than fall through to the safe default. Detaching only the container keeps that prompt in
front of you.

`--detach` is added to `--interactive --tty`, not swapped for them. `-t` gives the TUI its pty
and the daemon drains it into the container log, so nothing blocks on a full buffer. `-i` keeps
stdin open: without it the TUI reads EOF and exits immediately, and `docker attach` could only
watch.

## Attaching from the host

`entrypoint.sh` ends in `exec "$@"`, so `claude` is PID 1 and `docker attach` reaches it:

```bash
docker attach claude-repo-3f2a
```

Leave without stopping the session using the detach sequence `ctrl-p` `ctrl-q`. Pressing
`ctrl-c` or `ctrl-d` instead goes to Claude Code and ends the session.

To read the scrollback without attaching at all:

```bash
docker logs -f claude-repo-3f2a
```

A bridge that cannot start is not fatal. Claude Code prints a notice and the session runs on, so
the injected flag can never cost you the session. `claude doctor` names the blocking cause.

## The usage sync is skipped

`run.sh` normally copies cost records out of the session volume after the session ends. A
detached run returns while the session is still starting, so there is nothing to copy, and `--rm`
removes the container before there ever is.

The records themselves are written to the session **volume**, which outlives the container, so
nothing is lost. Recover them whenever you like:

```bash
./usage.sh
```

See [Usage Log Synchronization](usage-sync.md).
