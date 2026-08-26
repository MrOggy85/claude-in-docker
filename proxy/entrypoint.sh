#!/bin/sh
#
# Entrypoint for the egress proxy container (proxy/Dockerfile). Runs as root to
# set up what Squid cannot reach as its unprivileged 'proxy' user, then execs
# Squid in the foreground.
#
# 1. The CA. up.sh mounts <config-dir>/ca read-only at /etc/squid/ca-src, where
#    ca.key is mode 0600 owned by the HOST user — unreadable by 'proxy'. Root
#    copies the pair to a proxy-owned 0400 location instead of loosening the
#    host's permissions.
# 2. The generated-certificate DB. security_file_certgen signs one cert per
#    bumped host and caches it here; it must exist and be proxy-owned before
#    Squid starts, or every bumped connection fails.
#
# POSIX sh (same constraint as ext-allowlist.sh / auth-ok.sh): no bashisms.
set -eu

CA_SRC="${CA_SRC:-/etc/squid/ca-src}"
# up.sh mounts proxy/ whole at this path — squid.conf and both helpers are read
# from there, not from /etc/squid, so replacing a file on the host cannot leave
# the container with a dangling single-file mount.
SQUID_CONF="${SQUID_CONF:-/etc/squid/src/squid.conf}"
CA_DIR="${CA_DIR:-/var/lib/squid/ca}"
SSL_DB="${SSL_DB:-/var/lib/squid/ssl_db}"
CERTGEN="${CERTGEN:-/usr/lib/squid/security_file_certgen}"

if [ ! -f "${CA_SRC}/ca.crt" ] || [ ! -f "${CA_SRC}/ca.key" ]; then
  echo "proxy-entrypoint: no CA at ${CA_SRC} (expected ca.crt + ca.key)." >&2
  echo "proxy-entrypoint: run 'make ca' on the host, then 'make proxy-up'." >&2
  exit 1
fi

mkdir -p "${CA_DIR}"
cp "${CA_SRC}/ca.crt" "${CA_DIR}/ca.crt"
cp "${CA_SRC}/ca.key" "${CA_DIR}/ca.key"
chown -R proxy:proxy "${CA_DIR}"
chmod 700 "${CA_DIR}"
chmod 400 "${CA_DIR}/ca.crt" "${CA_DIR}/ca.key"

# -c creates the DB; it refuses to run against an existing one, so only
# initialize when absent (the DB survives container restarts only if volumed,
# which it is not — a fresh cert cache per start is fine).
if [ ! -d "${SSL_DB}" ]; then
  "${CERTGEN}" -c -s "${SSL_DB}" -M 8MB >/dev/null
fi
chown -R proxy:proxy "${SSL_DB}"

# Squid needs these to exist before it drops privileges (see the access_log note
# in squid.conf).
mkdir -p /var/log/squid /var/spool/squid
chown -R proxy:proxy /var/log/squid /var/spool/squid

# -N foreground, -d1 log level 1 to stderr so `docker logs` shows startup errors
# (a bad ssl_bump line, an unreadable key) instead of the container just dying.
exec /usr/sbin/squid -N -d1 -f "${SQUID_CONF}" "$@"
