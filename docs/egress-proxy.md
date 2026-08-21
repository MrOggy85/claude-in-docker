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
3. **No TLS interception.** Filtering is on the CONNECT target host only — no `ssl_bump`, no MITM,
   no CA certificate anywhere, so certificate pinning in Claude/MCP clients is unaffected.
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
# Optional: start the shared proxy explicitly (Docker is not available inside the
# Claude container). Idempotent — re-run it to apply squid.conf/helper edits.
make proxy-up            # or: ./proxy/up.sh

./run.sh
```

Tear down with `make proxy-down`. Rename the network and container via `CLAUDE_EGRESS_NETWORK`,
`CLAUDE_EGRESS_PROXY_NAME`, and `CLAUDE_EGRESS_IMAGE`.

## Allowlists

| File                                       | Role                                                            |
| ------------------------------------------ | --------------------------------------------------------------- |
| `<config-dir>/allowed-domains.txt`         | **baseline** — always allowed, every project (falls back to `templates/allowed-domains.txt` if absent) |
| `<config-dir>/projects/<key>/allowed-domains.txt` | that project's full list (seeded by `run.sh` on first run) |

Both are bind-mounted read-only into the proxy and read live by the helper (2-second verdict cache),
so **editing a list needs no proxy restart** — the change applies within ~2s.

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

- **Host-level only — no path/URL filtering.** Claude's traffic is HTTPS, so Squid sees only
  `CONNECT <host>:443` and relays the encrypted tunnel; path, headers, and body are never visible.
  You can allow or deny a *host*, not "this host, only this path." Filtering on path would require
  TLS interception (`ssl_bump bump` + a Squid CA trusted in every container), which breaks
  certificate pinning and is a deliberate non-goal. Plain HTTP would expose the URL, but nothing in
  the allowlist uses it.
- **Cross-project borrowing.** The project key is a *self-asserted* proxy username — a process in
  project A's container can present project B's key and use B's allowlist. Accepted trade-off: every
  container belongs to the same user, and a borrowed list only names hosts that user already
  allowlisted. Closing it means binding the username to a per-project source IP (not implemented).
- **Domain fronting.** Filtering on the CONNECT host does not inspect the TLS SNI, so a host that
  permits fronting could in principle be reached under an allowed CONNECT name. Optional hardening:
  Squid `ssl_bump peek` + a `splice` rule asserting SNI matches the CONNECT host (no decryption).
  Not enabled by default.
- **Proxy-unaware traffic breaks rather than leaks.** Tools that don't honor `HTTP(S)_PROXY` (e.g.
  git over SSH) cannot reach the network. All currently allowlisted hosts are HTTPS and honor it.
- **Single point of failure.** One proxy serves all sessions; if it is down, containers have no
  egress (fail closed). The proxy also resolves upstream DNS on the container's behalf.

## Files

- [`proxy/squid.conf`](../proxy/squid.conf) — proxy config (auth + external ACL + default-deny)
- [`proxy/ext-allowlist.sh`](../proxy/ext-allowlist.sh) — per-project allowlist decision helper
- [`proxy/auth-ok.sh`](../proxy/auth-ok.sh) — basic-auth helper accepting any credentials (username = project key)
- [`proxy/up.sh`](../proxy/up.sh) — create the network and (re)start the proxy
