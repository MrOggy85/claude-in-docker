#!/usr/bin/env bash
#
# Generate the local egress CA the Squid proxy signs with (`make ca`).
#
# Two files land in <config-dir>/ca/:
#   ca.key  the private key, mode 0600 — mounted ONLY into the Squid container
#   ca.crt  the public certificate — baked into the Claude image's trust store
# The key never enters a Claude container, so the agent-controlled side of the
# system holds no signing material. See docs/tls-inspection.md.
#
# Idempotent: an existing CA is reported and left alone (rotating is a deliberate
# act — delete the dir, re-run, then `make proxy-up`). Every dependent step keys
# off the file contents, so regenerating rebuilds the image on the next run.sh.
#
# Env: CA_DAYS (3650), CA_KEY_BITS (4096), CA_CN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/paths.sh"
# shellcheck source=colors.sh disable=SC1091
source "${REPO_DIR}/scripts/colors.sh"
color_init 1

CA_DIR="$(config_dir)/ca"
CA_KEY="${CA_DIR}/ca.key"
CA_CRT="${CA_DIR}/ca.crt"
CA_DAYS="${CA_DAYS:-3650}"
CA_KEY_BITS="${CA_KEY_BITS:-4096}"
CA_CN="${CA_CN:-claude-in-docker egress CA}"

if ! command -v openssl >/dev/null 2>&1; then
  fail "openssl not found" \
       "It generates the egress CA. Install it (brew install openssl / apt install openssl)."
  exit 1
fi

# SHA-256 fingerprint of a cert, in openssl's colon-separated form.
ca_fingerprint() {  # <cert>
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

if [[ -f "${CA_KEY}" && -f "${CA_CRT}" ]]; then
  kv "egress CA already exists" "${CA_DIR}" "delete the dir and re-run to rotate"
  kv "fingerprint" "$(ca_fingerprint "${CA_CRT}")"
  exit 0
fi
if [[ -f "${CA_KEY}" || -f "${CA_CRT}" ]]; then
  fail "half a CA in ${CA_DIR} (one of ca.key / ca.crt is missing)" \
       "Delete the directory and re-run so the pair is generated together."
  exit 1
fi

# 0700 before the key exists, so it is never briefly world-readable.
mkdir -p "${CA_DIR}"
chmod 700 "${CA_DIR}"

# Extensions via a temp config, NOT `-addext`: macOS ships LibreSSL as
# /usr/bin/openssl and cannot be relied on to accept that flag.
CONF="$(mktemp "${TMPDIR:-/tmp}/claude-ca-conf.XXXXXX")"
trap 'rm -f "${CONF}"' EXIT
cat > "${CONF}" <<CONF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[dn]
CN = ${CA_CN}

[v3_ca]
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
CONF

kv "generating egress CA" "${CA_DIR}" "${CA_KEY_BITS}-bit RSA, ${CA_DAYS} days"
umask 077   # ca.key is created 0600 by openssl itself
openssl req -x509 -new -nodes \
  -newkey "rsa:${CA_KEY_BITS}" \
  -sha256 \
  -days "${CA_DAYS}" \
  -keyout "${CA_KEY}" \
  -out "${CA_CRT}" \
  -config "${CONF}" \
  -extensions v3_ca >/dev/null 2>&1
chmod 600 "${CA_KEY}"
chmod 644 "${CA_CRT}"

ok "egress CA created" "$(ca_fingerprint "${CA_CRT}")"
say "Apply it: 'make proxy-up' (Squid signs with it), then run.sh (the image trusts it)."
