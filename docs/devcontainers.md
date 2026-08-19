# Devcontainers Alternative

How to run Claude Code inside a [Dev Container](https://containers.dev/) instead of (or alongside)
`run.sh` — for teams that want VS Code / GitHub Codespaces integration, or who already have a
devcontainer workflow.

> **Trade-off:** a devcontainer trades the terminal-first, any-project, nftables-enforced security
> model for IDE integration and Codespaces compatibility.

## Comparison

| Feature | `run.sh` (this project) | Devcontainer |
|---|---|---|
| Works from any project | Yes — one setup, used everywhere | Requires `.devcontainer/` in each project |
| Per-project session volumes | Auto-generated, stable names | Manually declared in each `devcontainer.json` |
| Auto-rebuild on context change | Hash-gated, transparent | Manual "Rebuild Container" in VS Code |
| Usage sync on exit | Automatic | No equivalent hook |
| `node_modules` volume isolation | Auto-discovered via `package.json` scan | Must be listed per project |
| Host UID mapping | Dynamic (`--user $(id -u):$(id -g)`) | Static `remoteUser` — must exist in image |
| Outbound egress | Shared Squid proxy + thin nftables egress-lock (`NET_ADMIN`) | Squid proxy sidecar (see below) |
| Terminal-first | Yes | IDE-first (VS Code / Codespaces) |
| `NET_ADMIN` in Codespaces | N/A | **Not available** — use squid sidecar instead |

## Network isolation with a squid sidecar

Codespaces does not grant `NET_ADMIN`, so iptables-based firewalling is unavailable. The replacement
is a **Squid sidecar** plus Docker's `internal: true` network.

`internal: true` is the key: Docker removes the default gateway for containers on that network, so
raw TCP from the `dev` container has no route to external IPs. The proxy sits on *both* `sandbox` and
`outside`, making it the only path out — even tools that ignore `HTTP_PROXY` just get `ENETUNREACH`.

```yaml
# .devcontainer/docker-compose.yml
name: claude-${PROFILE_NAME}-${DEP_POLICY}

services:
  dev:
    image: ${REGISTRY_PREFIX}/${PROFILE_NAME}:${TOOLCHAIN_VERSION}-${DEP_POLICY}-${DATE_TAG}
    command: ["sleep", "infinity"]
    user: dev
    working_dir: /workspace
    volumes:
      - ..:/workspace:cached
      - ${PROFILE_NAME}-${DEP_POLICY}:/home/dev
      - claude-history:/commandhistory
    environment:
      HTTP_PROXY: http://proxy:3128
      HTTPS_PROXY: http://proxy:3128
      ALL_PROXY: http://proxy:3128
      NO_PROXY: ${NO_PROXY_LIST}
      ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL}
      ANTHROPIC_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN}
      CLAUDE_CONFIG_DIR: /home/dev/.claude
    depends_on:
      - proxy
    networks:
      - sandbox

  proxy:
    image: ${REGISTRY_PREFIX}/claude-container-squid:${DATE_TAG}
    environment:
      SQUID_CONFIG_NAME: ${PROFILE_NAME}-${DEP_POLICY}
    volumes:
      - ./proxy-allowlist.txt:/opt/claude-container-squid/allowlists/project.txt:ro
    networks:
      sandbox: {}
      outside: {}

networks:
  sandbox:
    internal: true   # removes default gateway — no direct route to internet
  outside: {}
```

`proxy-allowlist.txt` is the per-project domain allowlist, mirroring `allowed-domains.txt`:

```
api.anthropic.com
api.github.com
registry.npmjs.org
```

### Squid HTTPS mode

Configure Squid in "peek and splice" mode — it reads the hostname from the `CONNECT` request without
decrypting, so no CA cert injection is needed:

```
acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump splice allowed_domains
ssl_bump terminate all
```

### Limitations vs iptables

- `HTTP_PROXY`/`HTTPS_PROXY` only intercepts proxy-aware traffic. The `internal: true` network is the
  real enforcement layer.
- DNS is not filtered — a tool can resolve an allowed domain's IP and attempt a direct connection,
  but it fails with `ENETUNREACH` for lack of a route on `sandbox`.
- In practice Claude Code's actual traffic (Anthropic API, npm, git over HTTPS) is fully covered.

## Which programs respect HTTP_PROXY

Most HTTP clients read `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`, but not all — which is why
enforcement comes from the `internal: true` network rather than from every tool honouring the var.

**Respects proxy env vars:**

| Tool / library | Notes |
|---|---|
| `curl`, `wget` | Case-insensitive `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` |
| Python `requests`, `httpx` | Automatic |
| Go `net/http` | `http.ProxyFromEnvironment()` — on by default |
| Rust `reqwest` | Yes |
| `git` (HTTPS) | Yes |
| `npm`, `yarn`, `pnpm` | Yes, for package downloads |
| `apt`, `apt-get` | Reads lowercase `http_proxy`/`https_proxy` |

**Does not:**

| Tool / library | Notes |
|---|---|
| Node.js built-in `http`/`https` | Known intentional design decision |
| Java `HttpURLConnection` / `HttpClient` | Needs JVM flags (`-Dhttp.proxyHost=...`) |
| Raw socket code | Bypasses all proxy logic |

**Claude Code** uses the Anthropic SDK, which routes API calls through the proxy correctly. Its
internal Node IPC and file-watching don't use the proxy, and don't need external access.

### Verifying proxy traffic

```bash
docker compose exec proxy tail -f /var/log/squid/access.log
```

From inside the dev container:

```bash
# Should succeed (routed through proxy)
curl https://api.anthropic.com

# Should fail with ENETUNREACH (no proxy, no route)
curl --noproxy '*' https://api.anthropic.com
```

## Personal mounts

The equivalent of `CLAUDE_MOUNTS` is a Docker Compose override file, gitignored by convention.
Commit `.devcontainer/.gitignore` containing `docker-compose.override.yml`, then keep your personal
copy out of git:

```yaml
# .devcontainer/docker-compose.override.yml
services:
  dev:
    volumes:
      - /my/personal/notes:/home/dev/notes:ro
      - ~/.ssh:/home/dev/.ssh:ro
```

Compose merges it with `docker-compose.yml` automatically.

## Personal packages

### Gitignored personal Dockerfile

Add `Dockerfile` to the committed `.devcontainer/.gitignore` alongside
`docker-compose.override.yml`, then extend the team image locally:

```dockerfile
# .devcontainer/Dockerfile — personal, gitignored
FROM ghcr.io/your-org/claude-devcontainer:latest
RUN apt-get update && apt-get install -y ripgrep fd-find htop \
    && rm -rf /var/lib/apt/lists/*
```

and switch from `image:` to `build:` in your override:

```yaml
services:
  dev:
    build: .
```

Teammates without the personal `Dockerfile` use the published image directly.

### devcontainer Features

The spec supports composable [Features](https://containers.dev/features) for standard toolchains.
Put them in a gitignored `devcontainer.local.json`, which VS Code merges with `devcontainer.json`:

```json
{
  "features": {
    "ghcr.io/devcontainers/features/rust:1": {},
    "ghcr.io/devcontainers/features/node:1": { "version": "20" }
  }
}
```

| Scenario | Approach |
|---|---|
| A few extra `apt` packages | Gitignored personal `Dockerfile` |
| Standard toolchains (Rust, Go, Node, Python) | devcontainer Features |
| Both | Gitignored `Dockerfile` + Features in `devcontainer.local.json` |

## Host UID mapping

`user: dev` is static — if your host UID doesn't match the `dev` user baked into the image, files
created on the bind-mounted workspace end up owned by the wrong user on the host. Either build the
image with your organisation's standard UID (e.g. `1000`), or adjust it dynamically in a
`postStartCommand`:

```bash
sudo usermod -u $(stat -c %u /workspace) dev
```

## When devcontainers make sense

- You want colleagues to open a repo in Codespaces with `claude` ready to go.
- You accept a weaker network boundary than iptables.
- You're comfortable adding `.devcontainer/` to every repo.
- You primarily work in VS Code rather than a standalone terminal.

This project's `Dockerfile` is directly reusable as the devcontainer image — only
`devcontainer.json` and the compose file need writing.
