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
