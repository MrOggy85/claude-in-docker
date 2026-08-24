# Installing Additional Packages

The image ships a baseline toolchain (Node, git, ripgrep, Python, etc.). Add anything else via
`install_additional_packages.sh`.

The container user is not root and `sudo` is scoped to the firewall script alone, so a session
cannot install a system package itself — under `sudo` it gets the misleading `account validation
failure, is your account locked?`. The [`sandbox` skill](sandbox-info.md) says so and prints the
host path below.

> **Node comes from [nvm](https://github.com/nvm-sh/nvm)** and needs no script. One pinned version
> (`NODE_VERSION` in the `Dockerfile`) is the default; at runtime `nvm install` / `nvm use` adds or
> switches versions (`nodejs.org` is in the baseline allowlist). Caveat: `nvm use` affects only the
> shell it runs in, and Claude's Bash tool starts a fresh shell per command, so bare `node` always
> gets the pinned default. To honor a project's `.nvmrc`, chain it: `nvm use && npm test`.
>
> `npm i -g` needs no script either: npm's prefix is the writable nvm directory.

> **Python packages come from [uv](https://github.com/astral-sh/uv)** (`UV_VERSION` in the
> `Dockerfile`), also with no script — Debian ships pip and `ensurepip` separately, so the image's
> `python3` has neither `pip` nor a working `python3 -m venv`. Runtime use needs `pypi.org` and
> `files.pythonhosted.org`, both in the baseline template, so an existing config needs
> `cid domains add pypi.org files.pythonhosted.org`. `uv python install` also reaches `github.com`
> and `objects.githubusercontent.com`; `uv venv --python 3.13` reuses the image's interpreter
> instead.

`make init` creates the script from `templates/install_additional_packages.sh`. Unlike other user
config it stays **in the repo root**, because it is `COPY`'d into the image and Docker's build
context is the repo directory. It is gitignored, and the default is a no-op.

Edit it to install what you need. It runs as **root** during the build, so no `sudo`:

```bash
#!/bin/bash
set -euo pipefail

# Deno 2.3.1
curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s v2.3.1
```

It executes near the end of the `Dockerfile`, so editing it only rebuilds that layer onward. Rebuild
for changes to take effect. Outbound access during the build is constrained by the firewall: any
host your install commands reach must be in `allowed-domains.txt`.

## Per-project packages

For per-project needs, use the project's own copy. On first run `run.sh` creates a per-project
config directory, seeds it with an inert stub of this file (plus a copy of `allowed-domains.txt`),
and prints the path:

```
>> per-project config dir: …/projects/<key>
```

Add your commands to `<config-dir>/projects/<key>/install_additional_packages.sh`. The next run
builds a **per-project image** layered `FROM` the shared base, baking the packages in at build time
so they install once rather than per container start:

```
>> building per-project image claude-code:<key>...
>> per-project image: claude-code:<key>
```

It rebuilds only when the base image or the project script changes. While the script holds only
comments and blank lines it counts as empty and the project runs the shared base image directly.

If a project needs a domain the baseline allowlist omits, edit
`<config-dir>/projects/<key>/allowed-domains.txt` — Squid reads the allowlist live (≈2s verdict
cache, no rebuild), so changes apply within ~2s (see [Centralized Egress Proxy](egress-proxy.md)).

To promote a per-project script to the global default, copy it to the repo-root
`install_additional_packages.sh`.
