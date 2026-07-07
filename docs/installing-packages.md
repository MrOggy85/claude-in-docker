# Installing Additional Packages

The image ships a baseline toolchain (Node, git, ripgrep, Python, etc.). When a workflow needs
something extra — e.g. Claude wants to run `deno` to check tests pass — add it via
`install_additional_packages.sh`.

> **Node is provided via [nvm](https://github.com/nvm-sh/nvm)** and is user-controllable, so
> you don't need this script to manage it. A single pinned version (see `NODE_VERSION` in the
> `Dockerfile`) is installed as the default; at runtime you can `nvm install <ver>` / `nvm use
> <ver>` to add or switch versions (`nodejs.org` is in the baseline `allowed-domains.txt`).
> Caveat: an `nvm use` only affects the shell it runs in, and Claude's Bash tool starts a fresh
> shell per command — so bare `node` always uses the pinned default. To honor a project's
> `.nvmrc`, chain the switch into the same command: `nvm use && npm test`.

`make init` creates the script from `templates/install_additional_packages.sh`. Unlike the
other user config, this global script stays **in the repo root** (not the config dir) — it is
the one exception, because it is `COPY`'d into the base image and Docker's build context is the
repo directory. It is gitignored, so your additions stay local. The default is a no-op:

```bash
#!/bin/bash
echo "no additional packages to install"
```

Edit it to install whatever you need. The script runs as **root** during the Docker build, so no
`sudo` is required:

```bash
#!/bin/bash
set -euo pipefail

# Deno 2.3.1
curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s v2.3.1
```

It is copied and executed near the end of the `Dockerfile`, so editing it only rebuilds that
layer onward. Rebuild the image after changing the script for the packages to take effect —
a rare activity, so the rebuild cost is acceptable.

Outbound network access during the build is constrained by the firewall: any host your install
commands reach must be listed in `allowed-domains.txt`.

## Per-project packages

If different projects need different packages, use the project's own
`install_additional_packages.sh`. On first run, `run.sh` creates a per-project
config directory and seeds it with an inert stub of this file (plus a copy of
`allowed-domains.txt`). It prints the directory on each run:

```
>> per-project config dir: …/projects/<key>
```

Edit `<config-dir>/projects/<key>/install_additional_packages.sh` and add your install
commands. The next run builds a **per-project image** layered `FROM` the shared
base image, baking those packages in at **build time** — so they install once,
not on every container start. `run.sh` reports the image it uses:

```
>> building per-project image claude-code:<key>...
>> per-project image: claude-code:<key>
```

The image is only rebuilt when the base image or the project script changes.
While the script holds only comments and blank lines (the seeded state) it is
treated as empty and the project just runs the shared base image directly — no
extra image is built.

Because the install runs as **root** at build time, no `sudo` is needed (the
runtime user is unprivileged). If a project needs a domain the baseline allowlist
omits, edit `<config-dir>/projects/<key>/allowed-domains.txt`; the Squid egress
proxy reads the allowlist live (≈30s verdict cache, no rebuild), so domain changes
apply within ~30s (see [Centralized Egress Proxy](egress-proxy.md)).

To promote a per-project script to the global default, copy it to the repo-root
`install_additional_packages.sh`.
