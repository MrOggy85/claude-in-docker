# Centralized Egress Proxy (Squid)

> **Status: opt-in.** The default network boundary is still the per-container
> IP allowlist documented in [Outbound Firewall](firewall.md). This proxy is an
> alternative egress model you enable with `CLAUDE_EGRESS_PROXY=1`. The two
> modes are mutually exclusive per container.

## Why

The default firewall allows outbound to the **IP addresses** the allowlisted
hostnames currently resolve to. That is coarse: CDN-fronted hosts share IPs, so
allowing one host on a shared `140.82.x.x` block implicitly allows everything
else co-hosted there, and the allowlist must be re-resolved continuously as
those IPs rotate.

A single shared Squid proxy moves the boundary to the **hostname**. Every Claude
container egresses through one proxy, which allows or denies each connection by
the CONNECT target host — no rotating IPs, and one place to reason about policy.

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
   `HTTPS_PROXY=http://<project-key>:x@squid:3128`, where `<project-key>` is the
   same `<safe-name>-<path-hash>` used for `projects/<key>/`. The password is a
   throwaway (`x`) — it is not checked.
2. **Squid selects that project's allowlist.** An
   [`external_acl`](../proxy/ext-allowlist.sh) helper receives
   `<project-key> <host>` and returns `OK` when `<host>` is in the baseline list
   (the active gitignored `allowed-domains.txt`) **or** in
   `projects/<project-key>/allowed-domains.txt`. Everything else is denied
   (`http_access deny all`).
3. **No TLS interception.** Filtering is on the CONNECT target host only. There
   is no `ssl_bump`, no MITM, and no CA certificate installed anywhere, so
   certificate pinning in Claude/MCP clients is unaffected.
4. **The container can't bypass it.** With `CLAUDE_EGRESS_PROXY=1`,
   [`init-firewall.sh`](../init-firewall.sh) runs in *proxy mode*: it permits
   egress **only** to the Squid host (plus DNS to Docker's embedded resolver at
   `127.0.0.11`) and rejects everything else. A process that ignores the proxy
   env var doesn't leak — it simply fails to connect. This also closes the
   port-53-to-anywhere DNS exfiltration channel that exists in IP-allowlist mode.

## Setup

```bash
# 1. Start the shared proxy once on the host (Docker is not available inside the
#    Claude container). Idempotent — re-run it to apply squid.conf/helper edits.
make proxy-up            # or: ./proxy/up.sh

# 2. Launch Claude through it (per session, or export it in your shell).
CLAUDE_EGRESS_PROXY=1 ./run.sh
```

`run.sh` auto-starts the proxy if it isn't already running, so step 1 is
optional for the first run — but running it explicitly is clearer for a
long-lived shared service. Tear down with `make proxy-down`.

## Allowlists

| File                                       | Role                                                            |
| ------------------------------------------ | --------------------------------------------------------------- |
| `allowed-domains.txt` (gitignored root)    | **baseline** — always allowed, every project (falls back to `templates/allowed-domains.txt` if absent) |
| `projects/<key>/allowed-domains.txt`       | that project's full list (already seeded by `run.sh` first run) |

Both are bind-mounted read-only into the proxy and read live by the helper
(30-second verdict cache), so **editing a list needs no proxy restart** — the
change applies within ~30s.

### Entry syntax

One entry per line; `#` comments and blank lines are ignored. Matching is on the
**hostname only** (see the limitation below):

| Entry                 | Matches                                                              |
| --------------------- | ------------------------------------------------------------------- |
| `api.example.com`     | that exact host only                                                |
| `.example.com`        | the apex `example.com` **and** any subdomain (`a.example.com`, …)   |

That is the full grammar — there is no path, URL, or port syntax. An entry like
`example.com/some/path` will not work; it would be compared against the
hostname and never match. To allow a site, list its host (e.g.
`developer.mozilla.org`) and every path on that host is reachable.

## Trust model / limitations

- **Host-level only — no path/URL filtering.** Claude's traffic is HTTPS, so
  Squid sees only `CONNECT <host>:443` and relays the encrypted tunnel; the URL
  path, headers, and body are never visible to it. You can allow or deny a
  *host*, but not "this host, only this path." The sole way to filter on path
  would be TLS interception (`ssl_bump bump` + a Squid CA cert trusted inside
  every container), which breaks certificate pinning and is a deliberate
  non-goal here. Plain HTTP would expose the URL, but nothing in the allowlist
  uses it.
- **Cross-project borrowing.** The project key is a *self-asserted* proxy
  username — a process in project A's container can present project B's key and
  use B's allowlist. This was an accepted trade-off: every container belongs to
  the same user, and even a borrowed list only names hosts the user already
  allowlisted. To close it, bind the username to a per-project source IP (not
  implemented). See the design discussion in the repo history.
- **Domain fronting.** Filtering on the CONNECT host does not inspect the TLS
  SNI, so a host that permits fronting could in principle be reached under an
  allowed CONNECT name. Optional hardening: enable Squid `ssl_bump peek` + a
  `splice` rule asserting the SNI matches the CONNECT host (no decryption). Not
  enabled by default.
- **Proxy-unaware traffic breaks rather than leaks.** Tools that don't honor
  `HTTP(S)_PROXY` (e.g. git over SSH) cannot reach the network in proxy mode.
  All current allowlisted hosts are HTTPS and honor the proxy env.
- **Single point of failure / scope.** One proxy serves all sessions; if it is
  down, proxy-mode containers have no egress (fail closed). The proxy resolves
  upstream DNS on the container's behalf.

## Files

- [`proxy/squid.conf`](../proxy/squid.conf) — proxy config (auth + external ACL + default-deny)
- [`proxy/ext-allowlist.sh`](../proxy/ext-allowlist.sh) — per-project allowlist decision helper
- [`proxy/auth-ok.sh`](../proxy/auth-ok.sh) — basic-auth helper that accepts any credentials (username = project key)
- [`proxy/up.sh`](../proxy/up.sh) — create the network and (re)start the proxy
