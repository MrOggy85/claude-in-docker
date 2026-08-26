#!/usr/bin/env bash
#
# Bring up the shared egress proxy: a bridge network plus one long-running Squid
# container that every Claude container egresses through. See docs/egress-proxy.md.
#
# Idempotent — builds the proxy image on context change and recreates the
# container so squid.conf / helper edits take effect. Per-project allowlists are
# read live, so editing those needs no re-run.
#
# Run on the host (no Docker inside the container):  ./proxy/up.sh  (make proxy-up)
# Env overrides: CLAUDE_EGRESS_NETWORK, CLAUDE_EGRESS_PROXY_NAME, CLAUDE_EGRESS_IMAGE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Config (baseline allowlist + per-project dirs) lives outside the repo;
# paths.sh resolves the same locations run.sh uses and forwards.
source "${REPO_DIR}/scripts/paths.sh"
# say/kv/ok/fail and the palette; see scripts/colors.sh.
# shellcheck source=../scripts/colors.sh disable=SC1091
source "${REPO_DIR}/scripts/colors.sh"
color_init 1

CONFIG_DIR="$(config_dir)"
PROJECTS_DIR="$(projects_dir)"

NETWORK="${CLAUDE_EGRESS_NETWORK:-claude-egress}"
PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
# Built here rather than pulled: TLS interception needs the squid-openssl build
# (see proxy/Dockerfile). Override with CLAUDE_EGRESS_IMAGE to run your own.
IMAGE="${CLAUDE_EGRESS_IMAGE:-claude-egress-squid:local}"

# Mounting preserves host perms, so make the helpers executable first.
chmod +x "${SCRIPT_DIR}/ext-allowlist.sh" "${SCRIPT_DIR}/auth-ok.sh"

# This directory is mounted whole (see the docker run below), so a commit that
# rewrites squid.conf or a helper is picked up by the next proxy-up rather than
# dangling the mount. Nothing secret lives here; the Dockerfile and up.sh ride
# along into the container harmlessly.
SRC_MOUNT=/etc/squid/src

# Baseline allowlist: the active config-dir copy only. Bail if absent (else
# Docker would mount a dir at the missing source); run `make init` to seed it.
BASELINE_DOMAINS_FILE="${CONFIG_DIR}/allowed-domains.txt"
if [[ ! -f "${BASELINE_DOMAINS_FILE}" ]]; then
  fail "${BASELINE_DOMAINS_FILE} not found — run: make init"
  exit 1
fi
# Same for the skip-decryption list (hosts to relay undecrypted). Comment-only
# when seeded.
BASELINE_SKIP_DECRYPTION_FILE="${CONFIG_DIR}/skip-decryption.txt"
if [[ ! -f "${BASELINE_SKIP_DECRYPTION_FILE}" ]]; then
  fail "${BASELINE_SKIP_DECRYPTION_FILE} not found — run: make init"
  exit 1
fi
# The CA Squid signs bumped connections with. Only this container ever sees the
# private key. See docs/tls-inspection.md.
CA_DIR="${CONFIG_DIR}/ca"
if [[ ! -f "${CA_DIR}/ca.crt" || ! -f "${CA_DIR}/ca.key" ]]; then
  fail "no egress CA in ${CA_DIR}" \
       "Squid decrypts TLS and needs a CA to sign with. Create it once with:" \
       "  make ca" \
       "See docs/tls-inspection.md."
  exit 1
fi

# Ensure the base dir exists so the read-only mount below is a directory, not a
# root-owned placeholder Docker would create.
mkdir -p "${PROJECTS_DIR}"

# Build on context change, the same label-hash gate run.sh uses for the base
# image: the hash of the build context is stored as an image label and compared
# on every run. Skipped when CLAUDE_EGRESS_IMAGE names someone else's image.
if [[ -z "${CLAUDE_EGRESS_IMAGE:-}" ]]; then
  proxy_context_hash() {
    { sha256_ "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/entrypoint.sh"; } \
      | sha256_ - | cut -c1-16
  }
  CURRENT_HASH="$(proxy_context_hash)"
  IMAGE_HASH="$(docker image inspect "${IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"
  if [[ "${IMAGE_HASH}" != "${CURRENT_HASH}" ]]; then
    if [[ -n "${IMAGE_HASH}" ]]; then kv "rebuilding proxy image — context changed" "${IMAGE}"
    else                              kv "building proxy image" "${IMAGE}"
    fi
    docker build \
      --tag "${IMAGE}" \
      --label "build.context-hash=${CURRENT_HASH}" \
      "${SCRIPT_DIR}"
  fi
fi

if ! docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  kv "creating network" "${NETWORK}"
  docker network create "${NETWORK}" >/dev/null
fi

# Recreate so squid.conf / helper edits are picked up.
docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true

kv "starting ${PROXY_NAME} on ${NETWORK}" "${IMAGE}"
docker run -d \
  --name "${PROXY_NAME}" \
  --network "${NETWORK}" \
  --network-alias squid \
  --restart unless-stopped \
  --volume "${SCRIPT_DIR}:${SRC_MOUNT}:ro" \
  --volume "${BASELINE_DOMAINS_FILE}:/etc/squid/baseline-domains.txt:ro" \
  --volume "${BASELINE_SKIP_DECRYPTION_FILE}:/etc/squid/baseline-skip-decryption.txt:ro" \
  --volume "${CA_DIR}:/etc/squid/ca-src:ro" \
  --volume "${PROJECTS_DIR}:/etc/squid/projects:ro" \
  "${IMAGE}" >/dev/null

# Confirm it stayed up. A rejected squid.conf directive (or an unreadable CA)
# exits Squid within a second, and `--restart unless-stopped` would otherwise
# hide that as a silent crash-loop with every container's egress dead. Three
# one-second looks, leaving early on the first dead reading.
RUNNING=""
for _ in 1 2 3; do
  sleep 1
  RUNNING="$(docker container inspect -f '{{.State.Running}}' "${PROXY_NAME}" 2>/dev/null || true)"
  [[ "${RUNNING}" == "true" ]] || break
done
if [[ "${RUNNING}" != "true" ]]; then
  fail "${PROXY_NAME} did not stay up — Squid rejected its config or the CA."
  cont "Last log lines:"
  docker logs --tail 20 "${PROXY_NAME}" 2>&1 | while IFS= read -r l; do cont "  ${l}"; done
  # Stop it so `--restart unless-stopped` gives up; the container (and its logs)
  # stay around for inspection.
  docker stop "${PROXY_NAME}" >/dev/null 2>&1 || true
  cont "Full log: docker logs ${PROXY_NAME}" \
       "Re-check the config alone:" \
       "  docker run --rm --entrypoint squid \\" \
       "    --volume ${SCRIPT_DIR}:${SRC_MOUNT}:ro ${IMAGE} -f ${SRC_MOUNT}/squid.conf -k parse"
  exit 1
fi

# Squid being alive is not the same as egress working: a helper that cannot exec
# leaves Squid up, respawning it forever, with every allowlist lookup failing.
# Probe it directly rather than waiting for the HEALTHCHECK's first interval.
if ! printf 'healthcheck healthcheck.invalid -\n' \
     | docker exec -i "${PROXY_NAME}" "${SRC_MOUNT}/ext-allowlist.sh" 2>/dev/null \
     | grep -q '^ERR$'; then
  fail "${PROXY_NAME} is up but its allowlist helper is not answering." \
       "Egress would be denied for every project. Check:" \
       "  docker logs --tail 50 ${PROXY_NAME}"
  exit 1
fi

ok "${PROXY_NAME} is up" "access log: docker exec ${PROXY_NAME} tail -f /var/log/squid/access.log"
say "Claude containers join '${NETWORK}' and reach it as http://squid:3128"
say "TLS is intercepted; hosts in skip-decryption.txt are relayed undecrypted."
