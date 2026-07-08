#!/usr/bin/env bash
#
# Bring up the shared egress proxy: a bridge network plus one long-running Squid
# container that every Claude container egresses through. See docs/egress-proxy.md.
#
# Idempotent — recreates the container so squid.conf / helper edits take effect.
# Per-project allowlists are read live, so editing those needs no re-run.
#
# Run on the host (no Docker inside the container):  ./proxy/up.sh  (make proxy-up)
# Env overrides: CLAUDE_EGRESS_NETWORK, CLAUDE_EGRESS_PROXY_NAME, CLAUDE_EGRESS_IMAGE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Config (baseline allowlist + per-project dirs) lives outside the repo;
# paths.sh resolves the same locations run.sh uses and forwards.
source "${REPO_DIR}/scripts/paths.sh"
CONFIG_DIR="$(config_dir)"
PROJECTS_DIR="$(projects_dir)"

NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
# For supply-chain safety, pin a digest via CLAUDE_EGRESS_IMAGE
# (docker manifest inspect ubuntu/squid:latest → @sha256:...).
IMAGE="${CLAUDE_EGRESS_IMAGE:-ubuntu/squid:latest}"

# Mounting preserves host perms, so make the helpers executable first.
chmod +x "${SCRIPT_DIR}/ext-allowlist.sh" "${SCRIPT_DIR}/auth-ok.sh"

# Baseline allowlist: the active config-dir copy only. Bail if absent (else
# Docker would mount a dir at the missing source); run `make init` to seed it.
BASELINE_DOMAINS_FILE="${CONFIG_DIR}/allowed-domains.txt"
if [[ ! -f "${BASELINE_DOMAINS_FILE}" ]]; then
  echo ">> error: ${BASELINE_DOMAINS_FILE} not found — run: make init" >&2
  exit 1
fi

# Ensure the base dir exists so the read-only mount below is a directory, not a
# root-owned placeholder Docker would create.
mkdir -p "${PROJECTS_DIR}"

if ! docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo ">> creating network ${NETWORK}"
  docker network create "${NETWORK}" >/dev/null
fi

# Recreate so squid.conf / helper edits are picked up.
docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true

echo ">> starting ${PROXY_NAME} on ${NETWORK} (${IMAGE})"
docker run -d \
  --name "${PROXY_NAME}" \
  --network "${NETWORK}" \
  --network-alias squid \
  --restart unless-stopped \
  --volume "${SCRIPT_DIR}/squid.conf:/etc/squid/squid.conf:ro" \
  --volume "${SCRIPT_DIR}/ext-allowlist.sh:/etc/squid/ext-allowlist.sh:ro" \
  --volume "${SCRIPT_DIR}/auth-ok.sh:/etc/squid/auth-ok.sh:ro" \
  --volume "${BASELINE_DOMAINS_FILE}:/etc/squid/baseline-domains.txt:ro" \
  --volume "${PROJECTS_DIR}:/etc/squid/projects:ro" \
  "${IMAGE}" >/dev/null

echo ">> ${PROXY_NAME} is up. Access log: docker exec ${PROXY_NAME} tail -f /var/log/squid/access.log"
echo ">> Claude containers join '${NETWORK}' and reach it as http://squid:3128"
