# Squid for the shared egress proxy, built locally rather than pulled: Debian's
# plain `squid` package is compiled WITHOUT OpenSSL, so `ssl_bump` fails config
# parse outright. `squid-openssl` is the same Squid with TLS interception
# support. See docs/tls-inspection.md.
#
# Pin the base image digest for supply-chain security (blank = dev only).
# Run `make pin-digest` after an upstream patch to append @sha256:... here.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
  squid-openssl \
  ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Prepares the CA and the generated-certificate DB, then execs squid; see the
# script. Runs as root so it can hand both to squid's unprivileged 'proxy' user.
COPY entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
RUN chmod +x /usr/local/bin/proxy-entrypoint.sh

# Exec the allowlist helper the way Squid does and demand a well-formed verdict.
# Squid survives a helper that cannot start — it just respawns it forever — so
# `docker ps` would read "Up" while every egress lookup fails. Docker acts on
# none of this; run.sh reads the status and recreates the proxy (step 3f).
# .invalid is reserved (RFC 2606), so ERR is the only correct answer.
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD printf 'healthcheck GET healthcheck.invalid / -\n' \
      | /etc/squid/src/ext-allowlist.sh | grep -q '^ERR$'

ENTRYPOINT ["/usr/local/bin/proxy-entrypoint.sh"]
