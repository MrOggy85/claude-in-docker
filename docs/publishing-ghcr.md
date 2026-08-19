# Publishing the Base Image to ghcr.io

The `Dockerfile` is split into two stages:

- **`base`** — apt packages, node (via nvm), Claude Code, the firewall script. Identical for every
  user; the expensive, slow-to-build layer.
- **`final`** — host UID/GID injection + `install_additional_packages.sh`. Always built locally,
  since it bakes in *your* UID/GID and *your* packages.

`final`'s `FROM` defaults to the local `base` stage, so a plain `docker build .` (what `run.sh` and
CI both run) is completely unchanged — nothing below requires opting in to anything.

## Reusing a published base image

Once a base image is published (see below), point a build at it instead of building `base` from
source:

```bash
docker build --build-arg BASE_IMAGE=ghcr.io/mroggy85/claude-in-docker:<tag>@sha256:<digest> .
```

`run.sh` wires this in automatically via either:

- `CLAUDE_DOCKER_BASE_IMAGE=ghcr.io/mroggy85/claude-in-docker:<tag>@sha256:<digest>` (env, takes
  precedence), or
- a `base-image` file in the config dir (`cid show base-image` / edit directly), containing just the
  ref.

Either way, BuildKit skips building `base` entirely — it's unreferenced in that build's dependency
graph — so the first run becomes a pull instead of a multi-minute build. `final`'s own layers (UID/GID,
`install_additional_packages.sh`) still build locally on top, same as always. Leave both unset to
build fully from source (the default, no change needed).

Pin by digest (`@sha256:...`), not just a tag, for supply-chain safety — the same reasoning as
`make pin-digest` for the upstream `debian:trixie-slim` base.

## Publishing workflow (manual step — needs a maintainer)

This project's GitHub App integration cannot create or edit files under `.github/workflows/`, so the
publish workflow itself has to be added by hand. Paste this as
`.github/workflows/publish-ghcr.yml`:

```yaml
name: Publish base image

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # Only the `base` stage — final's UID/GID/install_additional_packages.sh layers
      # are always built locally by the end user, never published.
      - name: Build and push base
        uses: docker/build-push-action@v6
        with:
          context: .
          target: base
          push: true
          tags: |
            ghcr.io/mroggy85/claude-in-docker:${{ github.ref_name }}
            ghcr.io/mroggy85/claude-in-docker:latest
```

After the first tag push, grab the published digest for users to pin:

```bash
docker buildx imagetools inspect ghcr.io/mroggy85/claude-in-docker:<tag>
```

## Building fully from source instead

No change needed — this is already the default. Just run `docker build .` (or `./run.sh`, which
does this for you); `BASE_IMAGE` is left unset, so `final` builds `FROM` the local `base` stage.
