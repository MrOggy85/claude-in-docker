#!/usr/bin/env bash
#
# Report the shape of THIS session's sandbox as markdown on stdout: published
# host<->container ports, the repo path mapping, extra mounts, volume-backed
# paths, and the egress model. Read by the `sandbox` skill (SKILL.md next to
# this file); safe for a human to run too.
#
# Runs INSIDE the container, where scripts/colors.sh does not exist — so this
# file is deliberately self-contained and emits plain text (the same constraint
# init-firewall.sh carries). It only reads the environment: no docker, no network,
# no writes.
#
# Every input is optional. A missing group prints an explicit "none" line rather
# than being omitted, so absence is reported as a fact instead of a gap.
#
# Inputs (environment; all set by run.sh):
#   CLAUDE_HOST_PROJECT_DIR         host path bind-mounted at $REPO_IN_CONTAINER
#   CONTAINER_PUBLISHED_PORTS       "<host-endpoint>:<cport>/<proto>" list, comma-separated
#   CONTAINER_HOST_OUTBOUND_PORTS   host ports this container may dial, comma-separated
#   CONTAINER_HOST_PORT_LABELS      "<port>=<label>" list for the ports run.sh names
#                                   (also tells us whether the chrome bridge is open)
#   CONTAINER_EXTRA_MOUNTS          "<target>=<host-path>:<mode>" list (CLAUDE_MOUNTS)
#   CONTAINER_VOLUME_PATHS          container paths backed by named volumes
#   EGRESS_PROXY_HOST               Squid host when egress is locked to the proxy
#   DOCKER_BRIDGE_TOKEN             presence only — the value is never printed
set -euo pipefail

REPO_IN_CONTAINER="${REPO_IN_CONTAINER:-/home/dev/repo}"

# Split a comma-separated list into trimmed lines (empties dropped). read -a
# rather than a `for` over an unquoted expansion, so a value can never glob.
items() {  # <list>
  local item parts=()
  IFS=',' read -r -a parts <<< "${1:-}"
  for item in ${parts[@]+"${parts[@]}"}; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

# Label for a host-outbound port, from CONTAINER_HOST_PORT_LABELS ("" if none).
# Labels themselves must not contain a comma (the list separator). Always exits 0:
# an unlabelled port is normal, and the caller assigns this in a `local`/`x=$(...)`
# where a non-zero status would trip `set -e`.
port_label() {  # <port>
  local want="$1" pair
  while IFS= read -r pair; do
    [[ "${pair%%=*}" == "$want" ]] && { printf '%s' "${pair#*=}"; break; }
  done < <(items "${CONTAINER_HOST_PORT_LABELS:-}")
  return 0
}

echo "# This session's sandbox"
echo
echo "Claude Code is running in a Docker container. These are the facts of this"
echo "session; they differ per session, so prefer them over anything remembered."
echo

echo "## Files"
echo
if [[ -n "${CLAUDE_HOST_PROJECT_DIR:-}" ]]; then
  echo "- Repo: \`${REPO_IN_CONTAINER}\` (here) is a bind-mount of \`${CLAUDE_HOST_PROJECT_DIR}\` (host)."
  echo "  Same files, different path — use the container path in tools, the host path"
  echo "  when telling the user what to open."
else
  echo "- Repo: \`${REPO_IN_CONTAINER}\`; the host path was not passed in."
fi
_n=0
while IFS= read -r m; do
  # "<target>=<host-path>:<mode>"
  _target="${m%%=*}"; _rest="${m#*=}"
  _mode="${_rest##*:}"; _host="${_rest%:*}"
  [[ "$_n" == 0 ]] && echo "- Extra mounts (from \`CLAUDE_MOUNTS\`):"
  echo "    - \`${_target}\` <- host \`${_host}\` (${_mode})"
  _n=$((_n + 1))
done < <(items "${CONTAINER_EXTRA_MOUNTS:-}")
[[ "$_n" == 0 ]] && echo "- Extra mounts: none. Only the repo is mounted from the host."
_n=0
while IFS= read -r p; do
  [[ "$_n" == 0 ]] && {
    echo "- Backed by Docker volumes, NOT present on the host disk (installed packages"
    echo "  stay off the host, so the user cannot see or build from these directories):"
  }
  echo "    - \`${p}\`"
  _n=$((_n + 1))
done < <(items "${CONTAINER_VOLUME_PATHS:-}")
[[ "$_n" == 0 ]] && echo "- Volume-backed paths: none — writes land on the host disk."
echo

echo "## Ports published to the host (inbound)"
echo
_n=0
while IFS= read -r entry; do
  # "<host-endpoint>:<cport>/<proto>", host endpoint may itself be "<ip>:<port>"
  _rest="${entry%/*}"; _proto="${entry##*/}"
  _cport="${_rest##*:}"; _hostep="${_rest%:*}"
  # ip-bound entries already carry their address; a bare port is on every interface.
  case "$_hostep" in
    *:*) _hurl="${_hostep}" ;;
    *)   _hurl="localhost:${_hostep}" ;;
  esac
  echo "- container \`${_cport}/${_proto}\` is reachable from the host at \`${_hurl}\`"
  _n=$((_n + 1))
done < <(items "${CONTAINER_PUBLISHED_PORTS:-}")
if [[ "$_n" == 0 ]]; then
  echo "- None. Nothing you listen on is reachable from the host: the container"
  echo "  publishes no ports and the firewall's INPUT policy is DROP."
  echo "- To change that the user must relaunch: \`CLAUDE_PORTS=\"<hostport>:<cport>\" run.sh\`,"
  echo "  or put \`CLAUDE_PORTS\` in the project's \`.claude-env\`. You cannot do it from here."
else
  echo "- No other container port is reachable from the host (firewall INPUT policy is DROP)."
fi
echo

echo "## Host services reachable from here (outbound)"
echo
_n=0
_chrome=""  # set below if the chrome-devtools bridge port is open; read by "Using this"
while IFS= read -r p; do
  _proto="tcp"; case "$p" in */*) _proto="${p##*/}"; p="${p%%/*}" ;; esac
  _label="$(port_label "$p")"
  case "$_label" in chrome-devtools*) _chrome="$p" ;; esac
  echo "- \`host.docker.internal:${p}\` (${_proto})${_label:+ — ${_label}}"
  _n=$((_n + 1))
done < <(items "${CONTAINER_HOST_OUTBOUND_PORTS:-}")
[[ "$_n" == 0 ]] && echo "- None: no direct connection to the host is permitted."
if [[ -n "${DOCKER_BRIDGE_TOKEN:-}" ]]; then
  echo "- The read-only docker bridge is enabled (\`docker_ps\` / \`docker_logs\` /"
  echo "  \`docker_stats\` via MCP), limited to the containers the user allowlisted."
else
  echo "- The read-only docker bridge is off, so no host container is inspectable."
fi
echo

echo "## Everything else on the network"
echo
if [[ -n "${EGRESS_PROXY_HOST:-}" ]]; then
  echo "- All other outbound traffic goes through a filtering proxy that allows only"
  echo "  this project's allowlisted domains. A refused or hanging request is policy,"
  echo "  not a broken network or a bad URL."
  echo "- Never route around it (no alternate host, port, mirror, or proxy). Report the"
  echo "  blocked hostname and tell the user to run \`cid domains add <host>\` on the host."
else
  echo "- No egress proxy is configured for this session."
fi
echo

echo "## Using this"
echo
echo "- Inside the container, reach your own server on its container port"
echo "  (\`curl http://localhost:<cport>\`)."
echo "- Anything running on the HOST must use the host endpoint above: the user's"
# Name the chrome bridge only where it exists — run.sh labels its port solely when
# the user opened it, so an unlabelled session has no such server to warn about.
if [[ -n "$_chrome" ]]; then
  echo "  browser, and the chrome-devtools MCP server — it drives a browser on the host,"
  echo "  so navigating it to the container port hits the host's own port, not yours."
else
  echo "  browser, and any other host-side tool — over there \`localhost:<cport>\` is the"
  echo "  host's own port, not yours."
fi
echo "- Ports, mounts and volumes are fixed when the container starts. Changing them"
echo "  means the user relaunching \`run.sh\`; nothing here can change them mid-session."
