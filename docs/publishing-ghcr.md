# Publishing the base image to ghcr.io

The `Dockerfile` is split into two stages:

- **`base`** — apt packages, Node (via nvm), Claude Code, the firewall script.
  Identical for every user; this is the stage a future CI workflow publishes.
- **`final`** — layered `FROM` `base` (or a published base, see below): injects
  the caller's host UID/GID and bakes in `install_additional_packages.sh`. This
  stage is per-machine/per-user and always builds locally.

`final` is the last stage, so a plain `docker build .` — what `run.sh` and
`.github/workflows/image.yml` both already do — builds everything from source
in one command, exactly as before. Nothing changes for the default path.

## Building fully from source

No special steps: `run.sh` builds `docker build .` (multi-minute, mostly apt +
`npm ci`). This is still the default and always works, with or without network
access to ghcr.io.

## Consuming a published base image (once one exists)

`final`'s `FROM` is parameterized as `ARG BASE_IMAGE=base`, defaulting to the
local `base` stage above. Pass a different ref via `--build-arg` to reuse a
published image instead:

```
docker build --build-arg BASE_IMAGE=ghcr.io/mroggy85/claude-in-docker:v1.0.0@sha256:<digest> .
```

BuildKit only builds stages reachable from the requested target. Since `final`'s
`FROM` now resolves to the external ref instead of the local `base` stage, `base`
is never built — the apt/nvm/npm layers are skipped entirely, and only the thin
`final` stage (UID/GID injection + `install_additional_packages.sh`) runs. First
run becomes a pull instead of a multi-minute build.

`run.sh` wires this in via `CLAUDE_DOCKER_BASE_IMAGE` (env var, takes
precedence) or a `base-image` file in the config directory
(`~/.config/claude-in-docker/base-image` by default), one ref per file,
whichever is set is passed as `--build-arg BASE_IMAGE=...`. See
[Environment Variables](environment-variables.md). Leave both unset to keep
building from source.

**Always pin by digest** (`@sha256:...`), not just a tag — a tag can move, a
digest can't. `docker pull ghcr.io/mroggy85/claude-in-docker:<tag>` then
`docker inspect --format '{{index .RepoDigests 0}}'` to get one.

## The publish workflow (not yet wired up)

Claude's GitHub App cannot create or edit files under `.github/workflows/`, so
this piece needs to be added by hand. Add a workflow along these lines — it
mirrors the existing build/smoke-test steps in `.github/workflows/image.yml`,
targeting only the `base` stage and pushing it to ghcr.io on a version tag:

```yaml
name: Publish base image

on:
  push:
    tags:
      - 'v*'

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push base stage
        run: |
          docker build \
            --target base \
            --tag "ghcr.io/mroggy85/claude-in-docker:${GITHUB_REF_NAME}" \
            --tag "ghcr.io/mroggy85/claude-in-docker:latest" \
            .
          docker push "ghcr.io/mroggy85/claude-in-docker:${GITHUB_REF_NAME}"
          docker push "ghcr.io/mroggy85/claude-in-docker:latest"
```

Once that workflow exists and a tag has been pushed, point at the published
image with the digest it prints (or `docker inspect` as above) — either
`CLAUDE_DOCKER_BASE_IMAGE=ghcr.io/mroggy85/claude-in-docker:v1.0.0@sha256:...`
or the equivalent `base-image` config file.
