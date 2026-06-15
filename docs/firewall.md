# Outbound Firewall

The container runs a default-deny outbound firewall. Nothing inside it can reach
the network except the hosts you explicitly allow. This is the project's primary
network containment boundary: even if Claude (or a package it installs) tries to
exfiltrate data or pull from an untrusted host, the connection is rejected unless
the destination is on the allowlist.

The firewall is configured by [`init-firewall.sh`](../init-firewall.sh), which
runs once at container start — as root, via a tightly-scoped `sudo` rule, before
the entrypoint drops to your user.

## The allowlist

Allowed destinations are listed by **hostname**, one per line, in
`allowed-domains.txt` (`#` comments and blank lines are ignored):

```
# Claude Code API
api.anthropic.com

# GitHub MCP
api.githubcopilot.com
```

There are three copies of this file, and the distinction matters:

| File                          | Tracked? | Role                                                            |
| ----------------------------- | -------- | --------------------------------------------------------------- |
| `allowed-domains.txt.example` | yes      | committed template / default set — edit this to change defaults |
| `allowed-domains.txt`         | no       | your gitignored local copy (`make init` seeds it from the template) |
| `/etc/allowed-domains.txt`    | —        | baked into the image from your local copy at build time         |

The firewall reads only the **baked** `/etc/allowed-domains.txt`. The file is
copied into the image at build time, so **changes take effect on the next image
rebuild, not at runtime.** `run.sh` rebuilds automatically when the build context
(including `allowed-domains.txt` and `init-firewall.sh`) changes.

## How it works

At container start `init-firewall.sh`:

1. Creates an ipset (`allowed-ips`, type `hash:net`).
2. Allows loopback, established/related connections, and DNS (UDP/TCP 53) —
   DNS must work so hostnames can be resolved.
3. Resolves every hostname in `/etc/allowed-domains.txt` and adds the resulting
   IPs to the ipset.
4. Adds one `OUTPUT ... --match-set allowed-ips dst -j ACCEPT` rule.
5. REJECTs everything else, then sets the `INPUT`/`FORWARD`/`OUTPUT` policies to
   `DROP`.

Blocked connections are **rejected, not silently dropped** — an explicit TCP
reset (`ECONNREFUSED`) or ICMP unreachable, so a blocked process fails instantly
instead of hanging until its own timeout. (The DX/disclosure tradeoff of this is
noted in [Known Attack Vectors](attack-vectors.md#firewall-boundary-disclosure-via-fast-fail).)

Inbound published ports (`CLAUDE_PORTS`) interact with the `INPUT` policy; see
[Publishing Ports](publishing-ports.md#why-this-needs-two-steps).

### Privilege model

The image grants a single `sudo` rule for `/usr/local/bin/init-firewall.sh` and
nothing else, so applying firewall rules is the only root action available to the
runtime user. The entrypoint calls it, then `exec`s `claude` as your unprivileged
host UID.

## IP rotation and the background refresher

The allowlist names **hostnames**, but iptables/ipset match on **IPs**. The
allowed hosts are CDN-fronted and rotate their IPs *within* a single session —
`api.githubcopilot.com` in particular moves around GitHub's `140.82.112.0/20`
block. A one-shot resolution at startup therefore goes stale: a later connection
hits a freshly-rotated IP that was never added to the ipset, and the REJECT rule
drops it. Symptom: GitHub MCP (or another allowed host) works for a while, then
starts failing with `ECONNREFUSED` mid-session.

To handle this, `init-firewall.sh` starts a **background refresher** (a detached
re-invocation of itself in `--refresh-loop` mode). Every `REFRESH_SECS` (default
**30s**) it re-resolves the hostnames in the allowlist and adds any new IPs to
the ipset. It is detached with `setsid`, logs to `/tmp/firewall-refresh.log`, and
dies with the container. Set `REFRESH_SECS=0` at the top of the script to disable
it (startup resolution only).

Two properties worth understanding:

- **It only ever adds the DNS answers for hostnames already in the allowlist.**
  It never adds a CIDR or a broader range, so it cannot widen the policy beyond
  what you've named. A host on `140.82.112.x` does not grant access to anything
  else in that block.
- **The ipset is add-only (monotonic).** After a rotation, *both* the old and the
  new IP stay allowed; nothing is evicted for the container's lifetime. In
  practice this is a handful of IPs per host. The tradeoff is that an IP a host
  has rotated *away* from remains allowed until the container is destroyed —
  acceptable for ephemeral, per-session containers, since these are addresses
  within the allowed host's own provider range.

> **Why not just allow GitHub's whole IP range?** That is what the upstream
> `anthropics/claude-code` devcontainer firewall does — it pulls GitHub's
> published CIDR blocks from `api.github.com/meta`. It's robust to rotation
> without a refresher, but it allows GitHub's *entire* ranges (`github.com`,
> clone/codeload, …). This project deliberately keeps the allowlist scoped to the
> single `api.githubcopilot.com` host, so it re-resolves that one name instead of
> trusting the whole block.

## Verifying and debugging

Inside the container:

```bash
# Current allowed IPs (grows as hosts rotate):
sudo ipset list allowed-ips

# Refresher activity — one line per newly-added IP:
cat /tmp/firewall-refresh.log

# Startup log (resolution + "refresher started"):
#   appears on stderr during container start
```

A connection failing with `ECONNREFUSED` means the destination is not on the
allowlist (or its IP hadn't been resolved yet). If an *allowed* host fails, check
that it's spelled correctly in `allowed-domains.txt` and that the image was
rebuilt after the edit.

## Changing the allowlist

1. Edit `allowed-domains.txt` (your local copy) — or
   `allowed-domains.txt.example` to change the committed default.
2. Re-run `run.sh`; it rebuilds the image because the build context changed.

See also: [Known Attack Vectors → Update of Allowed Domains](attack-vectors.md#update-of-allowed-domains).
