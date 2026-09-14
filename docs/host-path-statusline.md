# Host Path in the Status Line

Every session bind-mounts its launch directory to the **same** container path, `/home/dev/repo`
(`run.sh`, `--workdir`). `pwd` is therefore identical in every session, and with several
containerized terminals open it's easy to lose track of which host folder a session belongs to.

`run.sh` passes the host project directory, and the container's own name, in as environment
variables:

```sh
--env CLAUDE_HOST_PROJECT_DIR="${PROJECT_DIR}"
--env CONTAINER_NAME="${CONTAINER_NAME}"
```

and the seeded `settings.json` renders them as a dimmed `📁 /your/host/path  ⬢ 4749197e` at the
bottom of the session:

```json
{
  "statusLine": {
    "type": "command",
    "command": "printf '\\033[2m📁 %s\\033[0m' \"${CLAUDE_HOST_PROJECT_DIR:-$(pwd)}\"; if [ -n \"${CONTAINER_NAME:-}\" ]; then printf '\\033[2m  ⬢ %s\\033[0m' \"${CONTAINER_NAME##*-}\"; fi"
  }
}
```

The `⬢` segment is the **random suffix** of the container name (`run.sh` step 2b), not the whole
thing: the readable half is `claude-<folder>-`, which the 📁 path already tells you. Two terminals
in the same folder differ only in that suffix, and it is what distinguishes them in `docker ps` and
in `cid vnc --container`. The segment is omitted entirely when `CONTAINER_NAME` is unset, so the
line still works outside a container.

`CLAUDE_HOST_PROJECT_DIR` is **not** a variable Claude Code recognizes — the name is arbitrary and
the value flows purely through the shell: `docker run --env` puts it in the container environment,
and the `statusLine` subprocess inherits it. The `:-$(pwd)` fallback keeps the line working when the
var is unset, where it shows `/home/dev/repo`.

## Customizing

- **Folder name only:** `$(basename "${CLAUDE_HOST_PROJECT_DIR:-$PWD}")`. The full path
  disambiguates better when same-named folders live in different locations.
- The status line lives in your config-dir `settings.json` (seeded from
  [`templates/settings.json`](../templates/settings.json) by `make init`). It's mounted read-only,
  so edits take effect on the next launch.
