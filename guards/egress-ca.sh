#!/usr/bin/env bash
#
# Guard: TLS inspection is mandatory, so the egress CA must exist and be valid
# before anything is built or started. Squid signs every bumped connection with
# it and the image bakes its public half into the container trust store — a
# missing or expired CA means every HTTPS request in-session fails with a
# certificate error that looks like an attack rather than a setup gap.
#
# Only the public certificate is read here; run.sh never touches ca.key (see
# docs/tls-inspection.md).
#
# Sourced by run.sh (not run standalone): sets EGRESS_CA_CRT for the caller, and
# `exit`s the whole run before any build/container work.

EGRESS_CA_DIR="$(config_dir)/ca"
EGRESS_CA_CRT="${EGRESS_CA_DIR}/ca.crt"
_ca_key="${EGRESS_CA_DIR}/ca.key"

if [[ ! -f "${EGRESS_CA_CRT}" || ! -f "${_ca_key}" ]]; then
  fail "no egress CA in ${EGRESS_CA_DIR}" \
       "The proxy decrypts TLS, so it needs a CA to sign with and the container" \
       "needs its public half in the trust store. Create it once with:" \
       "  make ca" \
       "Then apply it: make proxy-up. See docs/tls-inspection.md."
  exit 1
fi

# Expiry is a hard failure too: an expired CA fails every TLS handshake in the
# container. Skipped when openssl is absent (the cert is still mounted and baked;
# we just cannot judge it here).
if command -v openssl >/dev/null 2>&1; then
  if ! openssl x509 -in "${EGRESS_CA_CRT}" -noout -checkend 0 >/dev/null 2>&1; then
    fail "the egress CA at ${EGRESS_CA_CRT} is expired or unreadable" \
         "Rotate it:" \
         "  rm -rf ${EGRESS_CA_DIR} && make ca && make proxy-up" \
         "The next run rebuilds the image against the new CA."
    exit 1
  fi
  # 30 days out, warn but continue — rotation is a scheduled chore, not an abort.
  if ! openssl x509 -in "${EGRESS_CA_CRT}" -noout -checkend 2592000 >/dev/null 2>&1; then
    warn "the egress CA expires within 30 days ($(openssl x509 -in "${EGRESS_CA_CRT}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'))." \
         "Rotate with: rm -rf ${EGRESS_CA_DIR} && make ca && make proxy-up"
  fi
fi

unset _ca_key
