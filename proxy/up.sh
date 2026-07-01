#!/usr/bin/env bash
#
# Bring up the centralized egress proxy: a user-defined bridge network plus one
# long-running Squid container that every Claude container egresses through.
# Idempotent — safe to re-run; it recreates the container so config edits to
# squid.conf / the helpers take effect. The per-project allowlists in projects/
# are bind-mounted read-only and read live by the helper, so editing those does
# NOT require re-running this.
#
# Run once on the host (Docker is not available inside the Claude container):
#   ./proxy/up.sh         # or: make proxy-up
#
# Override via env: CLAUDE_EGRESS_NETWORK, CLAUDE_EGRESS_PROXY_NAME,
# CLAUDE_EGRESS_IMAGE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
# Defaults to the :latest tag. For supply-chain safety, pin a digest here or via
# CLAUDE_EGRESS_IMAGE (docker manifest inspect ubuntu/squid:latest → @sha256:...).
IMAGE="${CLAUDE_EGRESS_IMAGE:-ubuntu/squid:latest}"

# The helper scripts run inside the container; mounting preserves host perms, so
# make sure they are executable before they are mounted.
chmod +x "${SCRIPT_DIR}/ext-allowlist.sh" "${SCRIPT_DIR}/auth-ok.sh"

# Baseline allowlist: the active, gitignored allowed-domains.txt, not the
# committed template. Fall back to the template if the root copy is absent
# (else Docker would create a directory at the missing mount source).
BASELINE_DOMAINS_FILE="${REPO_DIR}/allowed-domains.txt"
if [[ ! -f "${BASELINE_DOMAINS_FILE}" ]]; then
  BASELINE_DOMAINS_FILE="${REPO_DIR}/templates/allowed-domains.txt"
  echo ">> note: allowed-domains.txt not found — using template baseline (make allowed-domains.txt)"
fi

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
  --volume "${REPO_DIR}/projects:/etc/squid/projects:ro" \
  "${IMAGE}" >/dev/null

echo ">> ${PROXY_NAME} is up. Access log: docker exec ${PROXY_NAME} tail -f /var/log/squid/access.log"
echo ">> Claude containers join '${NETWORK}' and reach it as http://squid:3128"
