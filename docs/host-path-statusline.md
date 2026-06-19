# Host Path in the Status Line

Every session bind-mounts the directory you launch from to the **same** path
inside the container, `/home/dev/repo` (`run.sh`, `--workdir`). That makes
`pwd` identical in every session, so when several containerized terminals are
open it's easy to lose track of which host folder a session belongs to.

To disambiguate at a glance, `run.sh` passes the host project directory into the
container as an environment variable:

```sh
--env CLAUDE_HOST_PROJECT_DIR="${PROJECT_DIR}"
```

and the seeded `settings.json` renders it in the status line:

```json
{
  "statusLine": {
    "type": "command",
    "command": "printf '\\033[2m📁 %s\\033[0m' \"${CLAUDE_HOST_PROJECT_DIR:-$(pwd)}\""
  }
}
```

The result is a dimmed `📁 /your/host/path` line shown at the bottom of the
session.

## How it works

`CLAUDE_HOST_PROJECT_DIR` is **not** a variable Claude Code recognizes — the
name is arbitrary and `claude` does nothing special with it. The value flows
purely through the shell:

1. `run.sh` injects it into the container environment via `docker run --env`.
2. Claude Code spawns the `statusLine` command as a shell subprocess, which
   inherits that environment, so `${CLAUDE_HOST_PROJECT_DIR}` expands in the
   `printf`.

The `:-$(pwd)` fallback keeps the line working in sessions started before this
feature existed (or with the env var unset), where it shows `/home/dev/repo`.

## Customizing

- **Show only the folder name** instead of the full path:
  `$(basename "${CLAUDE_HOST_PROJECT_DIR:-$PWD}")`. The full path is more
  disambiguating when same-named folders live in different locations.
- The status line lives in your gitignored root `settings.json` (seeded from
  [`templates/settings.json`](../templates/settings.json) by `make init`). Edit
  it freely — it's mounted read-only into the container, so changes take effect
  on the next launch.
