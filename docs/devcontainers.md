# Devcontainers Alternative

This page describes how to run Claude Code inside a
[Dev Container](https://containers.dev/) instead of (or alongside) `run.sh`.
It is intended for teams that want VS Code / GitHub Codespaces integration, or
who already have a devcontainer-based workflow.

> **Trade-off summary:** A devcontainer setup trades the terminal-first,
> any-project, iptables-enforced security model for IDE integration and
> Codespaces compatibility. Read the [comparison table](#comparison) before
> committing to this approach.

---

## Comparison

| Feature | `run.sh` (this project) | Devcontainer |
|---|---|---|
| Works from any project | Yes — one setup, used everywhere | Requires `.devcontainer/` in each project |
| Per-project session volumes | Auto-generated, stable names | Manually declared in each `devcontainer.json` |
| Auto-rebuild on context change | Hash-gated, transparent | Manual "Rebuild Container" in VS Code |
| Usage sync on exit | Automatic | No equivalent hook |
| `node_modules` volume isolation | Auto-discovered via `package.json` scan | Must be listed per project |
| Host UID mapping | Dynamic (`--user $(id -u):$(id -g)`) | Static `remoteUser` — must exist in image |
| Outbound firewall | iptables (`NET_ADMIN`) | Squid proxy sidecar (see below) |
| Terminal-first | Yes | IDE-first (VS Code / Codespaces) |
| `NET_ADMIN` in Codespaces | N/A | **Not available** — use squid sidecar instead |

---

## Architecture

### Network isolation with a squid sidecar

GitHub Codespaces does not grant `NET_ADMIN`, so iptables-based firewalling is
not available. The recommended replacement is a **Squid proxy sidecar** combined
with Docker's `internal: true` network.

The key insight is `internal: true` on the sandbox network: Docker removes the
default gateway for containers on that network, so raw TCP connections from the
`dev` container have no route to external IPs. The proxy container sits on *both*
the `sandbox` and `outside` networks, making it the only path out. Even tools
that ignore `HTTP_PROXY` are blocked — they will get `ENETUNREACH`.

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

**`proxy-allowlist.txt`** (per-project domain allowlist, mirrors
`allowed-domains.txt` from `run.sh`):

```
api.anthropic.com
api.github.com
registry.npmjs.org
```

#### Squid HTTPS mode

For HTTPS, configure Squid in "peek and splice" mode — it reads the hostname
from the `CONNECT` request without decrypting traffic. No CA cert injection
needed:

```
acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump splice allowed_domains
ssl_bump terminate all
```

#### Limitations vs iptables

- `HTTP_PROXY`/`HTTPS_PROXY` only intercepts proxy-aware traffic. The
  `internal: true` network is the real enforcement layer; even tools that ignore
  proxy env vars can't reach the internet due to no route.
- DNS is not filtered — a tool can resolve an allowed domain's IP and attempt a
  direct connection, but that connection will fail (`ENETUNREACH`) because there
  is no route on the `sandbox` network.
- In practice, Claude Code's actual traffic (Anthropic API, npm, git over HTTPS)
  is fully covered.

---

## Which programs respect HTTP_PROXY

`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` are read by most HTTP clients, but
not all. The enforcement comes from the `internal: true` network, not from
relying on every tool to honour the env var.

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

**Does not respect proxy env vars:**

| Tool / library | Notes |
|---|---|
| Node.js built-in `http`/`https` | Known intentional design decision |
| Java `HttpURLConnection` / `HttpClient` | Needs JVM flags (`-Dhttp.proxyHost=...`) |
| Raw socket code | Bypasses all proxy logic |

**Claude Code** uses the Anthropic SDK, which routes API calls through the proxy
correctly. Internal Node.js IPC and file-watching do not use the proxy — but
they also don't need external access.

### Verifying proxy traffic

Watch Squid's access log to see exactly what is going through the proxy:

```bash
docker compose exec proxy tail -f /var/log/squid/access.log
```

Test from inside the dev container:

```bash
# Should succeed (routed through proxy)
curl https://api.anthropic.com

# Should fail with ENETUNREACH (no proxy, no route)
curl --noproxy '*' https://api.anthropic.com
```

---

## Personal mounts

The equivalent of `CLAUDE_MOUNTS` is handled via Docker Compose override files,
which are gitignored by convention:

**`.devcontainer/.gitignore`** (committed):

```
docker-compose.override.yml
```

**`.devcontainer/docker-compose.override.yml`** (personal, never committed):

```yaml
services:
  dev:
    volumes:
      - /my/personal/notes:/home/dev/notes:ro
      - ~/.ssh:/home/dev/.ssh:ro
```

Docker Compose merges this file with `docker-compose.yml` automatically.

---

## Personal packages

Two approaches, depending on preference:

### Gitignored personal Dockerfile

**`.devcontainer/.gitignore`** (committed):

```
Dockerfile
docker-compose.override.yml
```

**`.devcontainer/Dockerfile`** (personal, gitignored — extends the team image):

```dockerfile
FROM ghcr.io/your-org/claude-devcontainer:latest
RUN apt-get update && apt-get install -y ripgrep fd-find htop \
    && rm -rf /var/lib/apt/lists/*
```

**`.devcontainer/docker-compose.override.yml`** (personal, switches from `image:` to `build:`):

```yaml
services:
  dev:
    build: .
```

Teammates without the personal `Dockerfile` use the published image directly.

### devcontainer Features

The devcontainer spec supports composable [Features](https://containers.dev/features)
for standard toolchains. Add them to a gitignored `devcontainer.local.json`:

```json
{
  "features": {
    "ghcr.io/devcontainers/features/rust:1": {},
    "ghcr.io/devcontainers/features/node:1": { "version": "20" }
  }
}
```

VS Code merges `devcontainer.local.json` with `devcontainer.json` locally.

**When to use which:**

| Scenario | Approach |
|---|---|
| A few extra `apt` packages | Gitignored personal `Dockerfile` |
| Standard toolchains (Rust, Go, Node, Python) | devcontainer Features |
| Both | Gitignored `Dockerfile` + Features in `devcontainer.local.json` |

---

## Host UID mapping

The `user: dev` in the compose file is static — if your host UID does not match
the `dev` user's UID baked into the image, files created on the bind-mounted
workspace will be owned by the wrong user on the host.

Options:

- Build the image with your organisation's standard UID (e.g., `1000`)
- Use a `postStartCommand` that adjusts the UID dynamically:
  ```bash
  sudo usermod -u $(stat -c %u /workspace) dev
  ```

---

## When devcontainers make sense

- You want colleagues to open a repo in Codespaces and have `claude` ready to go
- You don't need (or accept) a weaker network boundary than iptables
- You're comfortable adding `.devcontainer/` to every repo
- You primarily work in VS Code rather than a standalone terminal

The `Dockerfile` from this project is directly reusable as the devcontainer
image — only `devcontainer.json` and the compose file need to be written.
