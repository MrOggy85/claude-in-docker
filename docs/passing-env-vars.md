# Passing Environment Variables

To inject arbitrary environment variables into the container, put them in a
gitignored `.env` file next to `run.sh`. When that file exists, `run.sh` passes
it to `docker run --env-file`, so every `KEY=VALUE` line becomes an env var
inside the container.

```bash
make init          # creates .env from templates/.env (comments only, a no-op)
# edit .env:
# DATABASE_URL=postgres://user:pass@localhost:5432/app
# MY_API_KEY=sk-xxxxxxxx
```

The file is optional and absent-safe: with no `.env`, no `--env-file` flag is
emitted. A comments-only `.env` (as created by `make init`) injects nothing.

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

- `.env` is gitignored; keep it that way for anything secret.
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
