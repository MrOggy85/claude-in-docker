# Installing Additional Packages

The image ships a fixed toolchain (Node, git, ripgrep, Python, etc.). When a workflow needs
something extra — e.g. Claude wants to run `deno` to check tests pass — add it via
`install_additional_packages.sh`.

`make init` creates the script from `templates/install_additional_packages.sh`; it is gitignored,
so your additions stay local. The default is a no-op:

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

If different projects need different packages, place an
`install_additional_packages.sh` inside the project's config directory instead
of the root copy. `run.sh` prints the config directory on each run:

```
>> per-project config dir: …/projects/<key>
```

Create `projects/<key>/install_additional_packages.sh` — it runs as **root**
(via `sudo`) in the entrypoint on every container start, after the firewall is
up. The root-level script is still run at image build time; the per-project
script adds to it at runtime. If your install command needs a domain that isn't
in the root allowlist, also add a `projects/<key>/allowed-domains.txt`.

> **Note:** because the per-project script runs on every start (not just the
> first), keep it idempotent (e.g. check before installing).

To promote a per-project script to the global default, copy it to the root
`install_additional_packages.sh` and trigger a rebuild.
