# TLS Inspection (ssl_bump)

The egress proxy decrypts HTTPS. What that means for one request to an allowlisted `github.com`:

1. The container sends `CONNECT github.com:443` to Squid. Squid checks
   [`allowed-domains.txt`](egress-proxy.md#allowlists) — that file's only job — and allows it.
2. Squid then **impersonates github.com**: it mints a certificate naming that host, signs it with a
   CA on your machine, and presents it to the container.
3. The container trusts that CA (the image installs it), so its client accepts and sends
   `GET /repos/x HTTP/1.1` — encrypted to *Squid*, not to GitHub.
4. Squid decrypts it, logs `GET https://github.com/repos/x`, then opens its **own** TLS session to
   the real github.com and forwards the request.

Two TLS sessions instead of one, plaintext in the middle. Before, steps 2-4 were a blind byte relay
logged as that one `CONNECT github.com:443` line.

Mandatory, not a mode: `run.sh` aborts on a missing or invalid CA, because a session that quietly
fell back to relaying would look identical while inspecting nothing.

## Setup

```bash
make ca          # also run by `make init`
make proxy-up    # Squid picks up the CA
./run.sh         # image rebuilds once to trust it
```

`make ca` writes two files and never overwrites them:

| File                         | Mode | Who sees it                                                   |
| ---------------------------- | ---- | ------------------------------------------------------------- |
| `<config-dir>/ca/ca.key`     | 0600 | the Squid container only (copied in by `proxy/entrypoint.sh`)  |
| `<config-dir>/ca/ca.crt`     | 0644 | the Squid container **and** every Claude image's trust store   |

`cid ca` prints the fingerprint, the expiry, and whether the image's copy still matches.

### Key custody

The private key signs for *any* host, so it lives only on the host (mode 0600) and in the proxy
container: never in a Claude container, never in the build context, never printed by `cid`. Why that
bounds it, and what it does not:
[Known Attack Vectors](attack-vectors.md#the-egress-cas-private-key).

### Rotation

```bash
rm -rf ~/.config/claude-in-docker/ca && make ca && make proxy-up
```

The next `run.sh` rebuilds the image: `egress-ca.crt` is part of its `context_hash`. Sessions older
than the rotation trust the old CA and the proxy signing with it is gone — restart them.

## How the container trusts it

`run.sh` copies `ca.crt` to `egress-ca.crt` in the repo — gitignored and derived, there because
Docker's build context is the repo dir (same reason as `install_additional_packages.sh`). The image
installs it into the system store with `update-ca-certificates`, covering OpenSSL, GnuTLS, curl and
git at once.

Runtimes that carry their own CA bundle need pointing at the merged system bundle instead:

| Runtime                | Variable                                    | Set by       |
| ---------------------- | ------------------------------------------- | ------------ |
| Node (incl. `claude`)  | `NODE_EXTRA_CA_CERTS`                       | `run.sh`     |
| `uv`, httpx, requests  | `SSL_CERT_FILE`                             | `Dockerfile` |
| `pip`                  | `REQUESTS_CA_BUNDLE`                        | `Dockerfile` |
| Deno                   | `DENO_CERT=$SSL_CERT_FILE`                  | you          |
| Cargo                  | `CARGO_HTTP_CAINFO=$SSL_CERT_FILE`          | you          |

Node is the trap: it reads neither the system store nor `SSL_CERT_FILE`, so miss that variable and
the Anthropic API and npm fail while curl and git work. A Java keystore is not covered — add the
certificate with `keytool` in your install script.

## Not decrypting a host

`skip-decryption.txt` stops step 2 per host: Squid reads the handshake far enough to see the
hostname, then relays the bytes untouched, so the container gets the origin's **real** certificate
and one end-to-end session. (Squid's word for this is *splicing* — hence `ssl_bump splice` in
`squid.conf`.)

Two lists, two questions — they layer rather than repeat:

| File | Question | Default |
| ---------------------- | ----------------------------------------------- | ------------ |
| `allowed-domains.txt`  | may the container reach this host at all?        | no           |
| `skip-decryption.txt`  | for a host it may reach, does Squid decrypt it?  | yes, decrypt |

Note the combination the table does not spell out: a host in `skip-decryption.txt` **only** is still
blocked. Not decrypting is a treatment, not a grant, so the entry does nothing alone.

One reason to use it, with a specific symptom: a tool fails with a certificate error while
`curl https://thathost/` in the same container succeeds. That tool **pins certificates** — it
compares what it got against a key compiled into it, ignores the trust store, and cannot be fixed
from inside the container.

```bash
cid skip-decryption add api.example.com     # this project
cid skip-decryption add -g .example.com     # every project (baseline)
cid skip-decryption rm  api.example.com     # decrypt it again
```

Same grammar and ~2s propagation as the egress allowlist: baseline
`<config-dir>/skip-decryption.txt` plus `projects/<key>/skip-decryption.txt`, one host per line, a
leading `.` matching the apex and every subdomain.

Keep the list short: a listed host loses its URL log lines and its inner-host check, so domain
fronting is open again there. It buys a working client at the price of visibility — not speed.
Decrypting costs one cached certificate per host plus a second handshake: noise next to network
latency.

## What this buys, and what it does not

- **Full URLs in the log**, one line per request:
  `docker exec claude-egress-proxy tail -f /var/log/squid/access.log`. Query strings are dropped
  (`strip_query_terms` defaults to on), so tokens in URLs stay out. The log lives in the container
  and dies with it.
- **Upstream certificates are validated by the proxy** (`sslproxy_cert_error deny all`), so a bad
  one on an allowlisted host fails there rather than in each client.
- **Domain fronting is closed.** Squid now sees the inner request's host, not just the CONNECT name.
- **Path-level rules are possible but not implemented.** The allowlist still matches hostnames only;
  "`api.github.com`, `GET /repos/*` only" is a follow-up.

## Troubleshooting

| Symptom                                                             | Cause and fix                                                              |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, `SELF_SIGNED_CERT_IN_CHAIN` in Node | `NODE_EXTRA_CA_CERTS` missing — the image predates the CA; re-run `run.sh` to rebuild |
| `SSL: CERTIFICATE_VERIFY_FAILED` in a Python tool                   | it ignores `SSL_CERT_FILE`; pass its own CA option, pointed at `$SSL_CERT_FILE` |
| A client reports a pinning failure                                  | `cid skip-decryption add <host>`                                                    |
| Every HTTPS request fails at once, in every project                 | expired or mismatched CA — `cid ca`, then rotate                           |
| The proxy will not start after an edit                              | `proxy/up.sh` says so and prints the log; parse the config alone with `docker run --rm --entrypoint squid --volume "$PWD/proxy:/etc/squid/src:ro" claude-egress-squid:local -f /etc/squid/src/squid.conf -k parse` |

Never work around a certificate error with `--insecure`, `NODE_TLS_REJECT_UNAUTHORIZED=0` or
`verify=False`: that also disables verification of the *upstream* certificate, the check this moved
to the proxy.

## Files

- [`scripts/gen-ca.sh`](../scripts/gen-ca.sh) — `make ca`
- [`guards/egress-ca.sh`](../guards/egress-ca.sh) — refuses to launch without a valid CA
- [`proxy/Dockerfile`](../proxy/Dockerfile), [`proxy/entrypoint.sh`](../proxy/entrypoint.sh) — the
  `squid-openssl` image (Debian's plain `squid` rejects `ssl_bump`) and its CA/cert-DB setup
- [`proxy/squid.conf`](../proxy/squid.conf) — `ssl_bump` policy
- [`proxy/ext-allowlist.sh`](../proxy/ext-allowlist.sh) — `--skip-decryption` mode answers "do not
  decrypt this"
- [Centralized Egress Proxy](egress-proxy.md) — the allowlist this sits on top of
