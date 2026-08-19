# Passing Environment Variables

Put environment variables in the `.env` file in the config dir
(`~/.config/claude-in-docker/`). `run.sh` always passes it to `docker run --env-file`, so every
`KEY=VALUE` line becomes an env var in the container.

`make init` creates a comment-only `.env` from the template, and `run.sh` refuses to start until it
exists. It may safely stay empty:

```bash
# .env in the config dir (~/.config/claude-in-docker/):
# DATABASE_URL=postgres://user:pass@localhost:5432/app
# MY_API_KEY=sk-xxxxxxxx
```

A per-project `projects/<key>/.env` takes precedence over the config-dir one.

## `docker --env-file` parsing caveats

`--env-file` is neither a shell sourcing a script nor a dotenv library:

- **Values are literal.** `FOO="bar"` injects the quotes too. Do not quote values.
- **No interpolation.** `FOO=$BAR` and `FOO=${BAR}` are passed literally.
- **No multiline values**, and `#` comments must be on their own line.
- **A bare line `FOO`** (no `=`) pulls `FOO` from the environment `run.sh` was launched in.

## Precedence and protected variables

`run.sh` places `--env-file` **before** its explicit `--env` flags, and Docker's last duplicate
wins — so `HOME`, `COLORTERM`, `MCP_GH_BEARER`, and `CONTAINER_OPEN_PORTS` always take precedence
and cannot be overridden from `.env`. (`HOME` is load-bearing: it makes `~` resolve for the
passwd-less runtime UID.)

## Security notes

- `.env` lives in the config dir, outside the repo; keep it there for anything secret.
- Values land in the container's process environment, readable by any process there including Claude
  Code. Treat `.env` as convenience config, not a vault.
- It does not touch the firewall or `allowed-domains.txt`, so it cannot widen outbound access.

## Forwarding a secret from the launch shell instead

To keep a secret off disk, export it before launching and list only its name in `.env`:

```bash
# .env
SOME_TOKEN
```

```bash
SOME_TOKEN="$(keychain_get some_token)" claude
```

This mirrors how `MCP_GH_BEARER` is handled (see the README).
