#!/usr/bin/env bash
#
# Guard: the host docker bridge (docker-bridge/, see docs/docker-bridge.md) gives
# the container read-only `docker ps` / `logs` / `stats` over an MCP endpoint that
# bypasses Squid entirely. The container allowlist is therefore the ONLY thing
# limiting what the agent can see, so refuse to launch with an allowlist that is
# missing (a silent misconfiguration) or dangerously broad — a bare "*", or
# anything matching the other Claude containers or the egress proxy, would hand
# the agent other sessions' logs.
#
# No-op unless CLAUDE_DOCKER_BRIDGE is on.
#
# Sourced by run.sh (not run standalone): reads PROJECT_DIR,
# CLAUDE_DOCKER_BRIDGE, DOCKER_BRIDGE_PORT and CLAUDE_EGRESS_PROXY_NAME from the
# caller and `exit`s the whole run on violation. Derives the config paths itself
# via scripts/paths.sh (already sourced by run.sh) so it can stay in the guards
# block, which runs before PROJECT_CONFIG_DIR is set.

case "${CLAUDE_DOCKER_BRIDGE:-}" in
  1|true|yes|on|TRUE|YES|ON)
    _dbg_baseline="$(config_dir)/docker-containers.txt"
    _dbg_project="$(projects_dir)/$(project_key "${PROJECT_DIR}")/docker-containers.txt"

    # Effective entries = baseline + per-project, comments and blanks stripped
    # (the same union the bridge applies).
    _dbg_entries=()
    for _dbg_f in "${_dbg_baseline}" "${_dbg_project}"; do
      [[ -f "${_dbg_f}" ]] || continue
      while IFS= read -r _dbg_line || [[ -n "${_dbg_line}" ]]; do
        _dbg_line="${_dbg_line%%#*}"
        _dbg_line="${_dbg_line#"${_dbg_line%%[![:space:]]*}"}"   # trim
        _dbg_line="${_dbg_line%"${_dbg_line##*[![:space:]]}"}"
        [[ -n "${_dbg_line}" ]] && _dbg_entries+=("${_dbg_line}")
      done < "${_dbg_f}"
    done

    if (( ${#_dbg_entries[@]} == 0 )); then
      echo "ERROR: CLAUDE_DOCKER_BRIDGE is on but no containers are allowlisted." >&2
      echo "  The allowlist is the only limit on what the agent can inspect, so it" >&2
      echo "  must be declared explicitly. Add this project's containers with:" >&2
      echo "    cid containers add <name>            # or a 'prefix-*' glob" >&2
      echo "  Files consulted:" >&2
      echo "    ${_dbg_project}" >&2
      echo "    ${_dbg_baseline}  (shared baseline)" >&2
      echo "  See docs/docker-bridge.md." >&2
      exit 1
    fi

    # Entries that would expose the other Claude sessions or the egress proxy: a
    # bare "*", or a prefix glob whose prefix also matches "claude-<...>" (the
    # session container naming) or the proxy container's name.
    _dbg_proxy="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"
    _dbg_bad=()
    for _dbg_e in "${_dbg_entries[@]}"; do
      if [[ "${_dbg_e}" == "*" ]]; then
        _dbg_bad+=("${_dbg_e} — matches every container on the host")
      elif [[ "${_dbg_e}" == claude-* ]]; then
        _dbg_bad+=("${_dbg_e} — matches Claude session containers")
      elif [[ "${_dbg_e}" == "${_dbg_proxy}" ]]; then
        _dbg_bad+=("${_dbg_e} — the egress proxy")
      elif [[ "${_dbg_e}" == *'*' ]] \
        && { [[ "claude-x" == "${_dbg_e%\*}"* ]] || [[ "${_dbg_proxy}" == "${_dbg_e%\*}"* ]]; }; then
        _dbg_bad+=("${_dbg_e} — matches Claude session containers or the egress proxy")
      fi
    done

    if (( ${#_dbg_bad[@]} > 0 )); then
      echo "ERROR: unsafe entries in the docker container allowlist:" >&2
      for _dbg_e in "${_dbg_bad[@]}"; do echo "  - ${_dbg_e}" >&2; done
      echo "  These would let the agent read other Claude sessions' logs (which carry" >&2
      echo "  their env, including MCP_GH_BEARER) or the proxy's access log." >&2
      echo "  Remove them with: cid containers rm <entry>" >&2
      echo "  See docs/docker-bridge.md." >&2
      exit 1
    fi

    # A dead bridge surfaces as a confusing mid-session MCP failure; say so now.
    _dbg_port="${DOCKER_BRIDGE_PORT:-9334}"
    if command -v curl >/dev/null 2>&1 \
       && ! curl -s -o /dev/null --max-time 2 "http://localhost:${_dbg_port}/mcp"; then
      echo "WARNING: nothing is listening on localhost:${_dbg_port} — the docker bridge" >&2
      echo "  looks down, so its MCP tools will fail in-session. Start it with" >&2
      echo "  ./docker-bridge/host-docker-bridge.sh (or load the launchd agent)." >&2
    fi

    unset _dbg_baseline _dbg_project _dbg_entries _dbg_f _dbg_line \
          _dbg_proxy _dbg_bad _dbg_e _dbg_port
    ;;
  *) ;;  # bridge off: nothing to check
esac
