# Host Path in the Status Line

Every session bind-mounts its launch directory to the **same** container path, `/home/dev/repo`
(`run.sh`, `--workdir`). `pwd` is therefore identical in every session, and with several
containerized terminals open it's easy to lose track of which host folder a session belongs to.

`run.sh` passes the host project directory in as an environment variable:

```sh
--env CLAUDE_HOST_PROJECT_DIR="${PROJECT_DIR}"
```

and the seeded `settings.json` renders it as a dimmed `📁 /your/host/path` at the bottom of the
session:

```json
{
  "statusLine": {
    "type": "command",
    "command": "printf '\\033[2m📁 %s\\033[0m' \"${CLAUDE_HOST_PROJECT_DIR:-$(pwd)}\""
  }
}
```

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
