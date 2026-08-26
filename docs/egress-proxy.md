# Centralized Egress Proxy (Squid)

The project's network containment boundary. Every Claude container egresses through **one shared
Squid proxy**, which allows or denies each connection by its CONNECT target **hostname**. Nothing
inside a container can reach the network any other way: a thin in-container nftables rule
(`init-firewall.sh`) permits outbound traffic *only* to the proxy, so a process that ignores the
`HTTP(S)_PROXY` env vars doesn't leak — it fails to connect.

## Why a proxy (vs. an IP firewall)

An earlier design allowed outbound to the **IP addresses** the allowlisted hostnames resolved to.
That is coarse: CDN-fronted hosts share IPs, so allowing one host on a shared `140.82.x.x` block
implicitly allowed everything co-hosted there, and the list had to be re-resolved as those IPs
rotated. It also left port 53 open to anywhere — a DNS-exfiltration channel.

Filtering on the **hostname** removes all three: no shared-IP over-permission, no rotating-IP chase,
and DNS closed to everything but Docker's resolver (Squid resolves upstream names itself).

## How it works

```
┌──────────────────┐        ┌──────────────────┐        ┌──────────┐
│ claude container │        │ claude container │        │   ...    │
│  (project A)     │        │  (project B)     │        │          │
│  firewall: only  │        │  firewall: only  │        │          │
│  egress → squid  │        │  egress → squid  │        │          │
└────────┬─────────┘        └────────┬─────────┘        └────┬─────┘
         │ HTTPS_PROXY=http://<projA-key>:x@squid:3128       │
         └───────────────┬───────────────────────────────────┘
                         ▼   docker network: claude-egress
                 ┌───────────────────────┐
                 │  claude-egress-proxy   │  ── allow/deny per host ──▶ internet
                 │  (Squid, explicit fwd) │
                 └───────────────────────┘
```

1. **Caller identity rides in the proxy username.** `run.sh` sets
   `HTTPS_PROXY=http://<project-key>:x@squid:3128`, where `<project-key>` is the same
   `<safe-name>-<path-hash>` used for `projects/<key>/`. The password (`x`) is not checked.
2. **Squid selects that project's allowlist.** An [`external_acl`](../proxy/ext-allowlist.sh) helper
   receives `<project-key> <host>` and returns `OK` when `<host>` is in the baseline list **or** in
   `<config-dir>/projects/<project-key>/allowed-domains.txt`. Everything else is denied
   (`http_access deny all`).
3. **TLS is decrypted**, with a locally generated CA the containers trust, so Squid reads the full
   URL and validates the upstream certificate. Hosts on `skip-decryption.txt` are relayed
   undecrypted instead. See [TLS Inspection](tls-inspection.md).
4. **The container can't bypass it.** [`init-firewall.sh`](../init-firewall.sh) runs at container
   start (as root via a tightly-scoped `sudo` rule, before the entrypoint drops to your user). It
   permits egress **only** to the Squid host plus DNS to Docker's embedded resolver at
   `127.0.0.11`, closing the port-53-to-anywhere channel.

### Privilege model

`init-firewall.sh` is the *only* root action available to the runtime user: the image grants a single
`sudo` rule for `/usr/local/bin/init-firewall.sh` and nothing else. The entrypoint calls it, then
`exec`s `claude` as your unprivileged host UID. `NET_ADMIN` exists solely so that script can apply
the nftables rules.

## Setup

The proxy is mandatory infrastructure — `run.sh` auto-starts it if it isn't running, so there is
nothing to enable per session:

```bash
make ca                  # once: the CA the proxy signs decrypted TLS with

# Optional: start the shared proxy explicitly (Docker is not available inside the
# Claude container). Idempotent — re-run it to apply squid.conf/helper edits, and
# it builds proxy/Dockerfile when that changes.
make proxy-up            # or: ./proxy/up.sh

./run.sh
```

Tear down with `make proxy-down`. Rename the network and container via `CLAUDE_EGRESS_NETWORK`,
`CLAUDE_EGRESS_PROXY_NAME`, and `CLAUDE_EGRESS_IMAGE` (which also skips the build).

### Logs

`docker logs -f claude-egress-proxy` carries both streams: Squid's own errors on stderr, and one
allow/deny line per request relayed from `/var/log/squid/access.log` by `entrypoint.sh` (Squid
cannot write PID 1's root-owned stdout itself — it drops to the `proxy` user first). The file lives
in the container's writable layer, so `make proxy-up` starts it empty. Treat it as sensitive: on
decrypted hosts it is the full URL of every request every session made — which is why
[`guards/docker-bridge.sh`](../guards/docker-bridge.sh) refuses to expose this container to the
read-only docker bridge.

### Health

Squid outlives a helper that cannot start — it respawns it forever while every allowlist lookup
fails, so "container is running" does not mean "egress works". Two checks close that gap: `up.sh`
execs the helper once before declaring success, and the image's `HEALTHCHECK` repeats that probe
every 60s. Docker acts on neither, so `run.sh` reads the status and recreates an `unhealthy` proxy
at startup. To look yourself:

```bash
docker inspect -f '{{.State.Health.Status}}' claude-egress-proxy
printf 'k example.com -\n' | docker exec -i claude-egress-proxy /etc/squid/src/ext-allowlist.sh
```

`proxy/` is mounted whole at `/etc/squid/src` rather than file by file: a single-file bind mount
follows the inode, so a commit that rewrites `squid.conf` or a helper would otherwise leave the
running container pointed at a deleted file.

## Allowlists

| File                                       | Role                                                            |
| ------------------------------------------ | --------------------------------------------------------------- |
| `<config-dir>/allowed-domains.txt`         | **baseline** — always allowed, every project (falls back to `templates/allowed-domains.txt` if absent) |
| `<config-dir>/projects/<key>/allowed-domains.txt` | that project's full list (seeded by `run.sh` on first run) |
| `<config-dir>/skip-decryption.txt`, `projects/<key>/skip-decryption.txt` | same grammar, different question: hosts **not** to decrypt ([TLS Inspection](tls-inspection.md)) |

All are bind-mounted read-only into the proxy and read live by the helper (2-second verdict cache),
so **editing a list needs no proxy restart** — the change applies within ~2s. The two baseline
files are mounted individually, so `cid` rewrites them in place (`_rewrite_in_place`) rather than
renaming a temp file over them: a new inode would strand the proxy's mount and silently drop the
baseline from every verdict.

### Entry syntax

One entry per line; `#` comments and blank lines ignored. Matching is on the **hostname only**:

| Entry                 | Matches                                                              |
| --------------------- | ------------------------------------------------------------------- |
| `api.example.com`     | that exact host only                                                |
| `.example.com`        | the apex `example.com` **and** any subdomain (`a.example.com`, …)   |
| `api.example.com  # expires=1719999999` | that exact host, but only until the epoch timestamp passes |

That is the full grammar — no path, URL, or port syntax. An entry like `example.com/some/path` is
compared against the hostname and never matches. List the host and every path on it is reachable.

### Temporary entries

`cid domains add --for <duration> <host>` (`15m`, `2h`, `1d`, …) appends the host with an
`# expires=<epoch>` annotation instead of a bare line. [`ext-allowlist.sh`](../proxy/ext-allowlist.sh)
checks that timestamp on every lookup — past it, the line stops matching, on the same ~2s
propagation window as any other allowlist edit. No daemon sweeps it; enforcement is just "is this
still in the future" at read time. `cid domains prune` drops stale expired lines for hygiene only —
an unpruned expired line is already ignored. Re-running `add --for` on the same host replaces its
expiry; a later plain `add` (no `--for`) promotes it to permanent. See [The `cid` config
CLI](config-cli.md#domains-add--domains-rm).

## Trust model / limitations

- **Host-level rules, though the plaintext is now visible.** The request URL *is* available to the
  proxy, but the allowlist grammar still matches hostnames only: you can allow or deny a *host*, not
  "this host, only this path". Path-level rules are a follow-up on top of
  [TLS Inspection](tls-inspection.md).
- **The CA private key is a new secret.** It signs for any host and lives on the host plus the Squid
  container, never in a Claude container. See
  [Known Attack Vectors](attack-vectors.md#the-egress-cas-private-key).
- **A host on `skip-decryption.txt` is filtered by hostname only** — the pre-interception
  treatment: CONNECT target in, encrypted tunnel out.
- **Cross-project borrowing.** The project key is a *self-asserted* proxy username — a process in
  project A's container can present project B's key and use B's allowlist. Accepted trade-off: every
  container belongs to the same user, and a borrowed list only names hosts that user already
  allowlisted. Closing it means binding the username to a per-project source IP (not implemented).
- **Proxy-unaware traffic breaks rather than leaks.** Tools that don't honor `HTTP(S)_PROXY` (e.g.
  git over SSH) cannot reach the network. All currently allowlisted hosts are HTTPS and honor it.
- **Single point of failure.** One proxy serves all sessions; if it is down, containers have no
  egress (fail closed). The proxy also resolves upstream DNS on the container's behalf.

## Files

- [`proxy/squid.conf`](../proxy/squid.conf) — proxy config (auth + external ACL + default-deny + `ssl_bump`)
- [`proxy/ext-allowlist.sh`](../proxy/ext-allowlist.sh) — per-project allowlist decision helper; `--skip-decryption` answers the decrypt-or-not question
- [`proxy/auth-ok.sh`](../proxy/auth-ok.sh) — basic-auth helper accepting any credentials (username = project key)
- [`proxy/Dockerfile`](../proxy/Dockerfile), [`proxy/entrypoint.sh`](../proxy/entrypoint.sh) — the `squid-openssl` image and its CA / cert-DB setup
- [`proxy/up.sh`](../proxy/up.sh) — build the image, create the network, (re)start the proxy
- [TLS Inspection](tls-inspection.md) — the CA, the trust stores, the skip-decryption list
