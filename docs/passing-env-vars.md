# Passing Environment Variables

To inject arbitrary environment variables into the container, put them in the
`.env` file in the config dir (`~/.config/claude-in-docker/`). `run.sh` always
passes it to `docker run --env-file`, so every `KEY=VALUE` line becomes an env
var inside the container.

`make init` creates a comment-only `.env` from the template, and `run.sh`
refuses to start until it exists (a first-time run without it aborts with a
`make init` pointer). The file may safely stay empty — a comment-only `.env`
injects nothing. Add lines when you need them:

```bash
# .env in the config dir (~/.config/claude-in-docker/):
# DATABASE_URL=postgres://user:pass@localhost:5432/app
# MY_API_KEY=sk-xxxxxxxx
```

A per-project `.env` in `projects/<key>/.env` takes precedence over the
config-dir one when present.

## `docker --env-file` parsing caveats

Docker's `--env-file` does **not** behave like a shell sourcing a script or a
dotenv library. The differences are the common surprises:

- **Values are literal.** `FOO="bar"` injects the value `"bar"` *including the
  quotes*. Do not quote values.
- **No interpolation.** `FOO=$BAR` and `FOO=${BAR}` are passed literally; they
  are not expanded.
- **No multiline values**, and `#` comments must be on their own line.
- **A bare line `FOO`** (no `=`) pulls `FOO` from the environment `run.sh` was
  launched in — useful for forwarding a secret without writing it to disk.

## Precedence and protected variables

`run.sh` places `--env-file` **before** its explicit `--env` flags on the docker
command line. Docker applies env settings left-to-right and the last duplicate
wins, so the internal variables set by `run.sh` — `HOME`, `COLORTERM`,
`MCP_GH_BEARER`, `CONTAINER_OPEN_PORTS` — always take precedence and cannot be
overridden from `.env`. (`HOME` in particular is load-bearing: it makes `~`
resolve for the passwd-less runtime UID.)

## Security notes

- `.env` lives in the config dir, outside the repo; keep it there for anything secret.
- Values land in the container's process environment and are readable by any
  process there (including Claude Code). Treat `.env` as convenience config, not
  a vault.
- This does not touch the firewall (`init-firewall.sh` / `allowed-domains.txt`),
  so it does not widen the container's outbound network access.

## Forwarding a secret from the launch shell instead

If you prefer not to write a secret to disk, export it before launching and list
just its name (no `=`) in `.env`:

```bash
# .env
SOME_TOKEN
```

```bash
SOME_TOKEN="$(keychain_get some_token)" claude
```

This mirrors how `MCP_GH_BEARER` is handled (see the README), keeping the value
out of any committed or on-disk file.
