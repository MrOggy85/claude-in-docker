#!/usr/bin/env bats
#
# Unit tests for scripts/gen-ca.sh — the egress CA `make ca` generates. The CA is
# what the proxy signs intercepted TLS with and what the image trusts, so the
# properties that matter are: it is a real CA certificate, the private key is not
# readable by anyone else, and re-running never silently replaces it (that would
# break every running session's trust).
#
# Run with: bats test/gen-ca.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GEN_CA="${SCRIPT_DIR}/scripts/gen-ca.sh"

setup() {
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  # 2048-bit throughout: these are fixtures, and 4096 costs seconds per test.
  export CLAUDE_DOCKER_CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  export CA_KEY_BITS=2048
  CA_DIR="${CLAUDE_DOCKER_CONFIG_DIR}/ca"
}

# Mode bits, GNU stat then BSD/macOS stat (the fallback pattern cid uses).
mode_of() {  # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1" 2>/dev/null
}

@test "creates a certificate and a key" {
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  [ -f "${CA_DIR}/ca.crt" ]
  [ -f "${CA_DIR}/ca.key" ]
}

@test "the certificate is a CA (basicConstraints CA:TRUE) that can sign certs" {
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  run openssl x509 -in "${CA_DIR}/ca.crt" -noout -text
  [[ "$output" == *"CA:TRUE"* ]]
  [[ "$output" == *"Certificate Sign"* ]]
}

@test "the private key is not group- or world-readable" {
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  [ "$(mode_of "${CA_DIR}/ca.key")" = "600" ]
}

@test "the certificate is readable (the image and the proxy both need it)" {
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  [ "$(mode_of "${CA_DIR}/ca.crt")" = "644" ]
}

@test "the key and the certificate are a matching pair" {
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  local from_key from_crt
  from_key="$(openssl rsa -in "${CA_DIR}/ca.key" -pubout 2>/dev/null)"
  from_crt="$(openssl x509 -in "${CA_DIR}/ca.crt" -noout -pubkey 2>/dev/null)"
  [ "${from_key}" = "${from_crt}" ]
}

@test "re-running leaves an existing CA untouched" {
  "${GEN_CA}" >/dev/null
  local before; before="$(openssl x509 -in "${CA_DIR}/ca.crt" -noout -fingerprint -sha256)"
  run "${GEN_CA}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(openssl x509 -in "${CA_DIR}/ca.crt" -noout -fingerprint -sha256)" = "${before}" ]
}

@test "half a CA is refused rather than completed with a mismatched half" {
  "${GEN_CA}" >/dev/null
  rm -f "${CA_DIR}/ca.key"
  run "${GEN_CA}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"half a CA"* ]]
  # The surviving certificate is left alone for the user to inspect.
  [ -f "${CA_DIR}/ca.crt" ]
}

@test "CA_DAYS is honoured (so rotation windows are testable)" {
  CA_DAYS=1 run "${GEN_CA}"
  [ "$status" -eq 0 ]
  # Valid now, but not two days out.
  run openssl x509 -in "${CA_DIR}/ca.crt" -noout -checkend 0
  [ "$status" -eq 0 ]
  run openssl x509 -in "${CA_DIR}/ca.crt" -noout -checkend 172800
  [ "$status" -ne 0 ]
}
