#!/usr/bin/env bash
#
# Guard: verify that MCP_GH_BEARER, if set, cannot push code.
# Code push (Contents:write) is a known attack vector, so the token must not
# hold it. Issues and Pull Requests write access IS permitted — only
# Contents:write is rejected. Use a fine-grained PAT whose Contents permission
# is Read-only. See docs/mcp-servers.md.
#
# Sourced by run.sh (not run standalone): reads MCP_GH_BEARER from the caller
# and `exit`s the whole run when the token is invalid or can push code. Network
# or tooling failures fail open (warn and continue).

if [[ -n "${MCP_GH_BEARER:-}" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo ">> WARNING: curl not found; skipping GitHub token write-access check." >&2
  else
    _gh_headers=$(curl -sI \
      -H "Authorization: Bearer ${MCP_GH_BEARER}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/user 2>/dev/null) || true
    _gh_status=$(printf '%s' "$_gh_headers" | grep -m1 -i '^HTTP/' | awk '{print $2}' | tr -d '\r') || true
    case "${_gh_status}" in
      401)
        echo "ERROR: GitHub token (MCP_GH_BEARER) is invalid (401 Unauthorized)." >&2
        echo "  Check your token and try again." >&2
        exit 1
        ;;
      2*)
        # Classic OAuth tokens expose their scopes in X-OAuth-Scopes.
        _gh_scopes=$(printf '%s' "$_gh_headers" | grep -im1 '^x-oauth-scopes:' \
          | cut -d: -f2- | tr -d ' \r\n') || true
        if [[ -n "$_gh_scopes" ]]; then
          # Classic token: reject any write-capable scope. Classic scopes cannot
          # grant Issues/PR write without `repo` (which bundles code push), so
          # there is no safe classic write scope — use a fine-grained PAT instead.
          _bad_scope=""
          for _s in repo public_repo workflow delete_repo \
                    write:org admin:org \
                    write:packages delete:packages \
                    admin:repo_hook write:repo_hook; do
            if echo ",$_gh_scopes," | grep -qF ",${_s},"; then
              _bad_scope="$_s"; break
            fi
          done
          if [[ -n "$_bad_scope" ]]; then
            echo "ERROR: GitHub token (MCP_GH_BEARER) has write scope '${_bad_scope}'." >&2
            echo "  The container forbids code-push access. Replace it with a" >&2
            echo "  fine-grained PAT whose Contents permission is Read-only" >&2
            echo "  (Issues / Pull requests write is fine)." >&2
            echo "  See docs/mcp-servers.md for details." >&2
            exit 1
          fi
        else
          # Fine-grained PAT (X-OAuth-Scopes is empty): check push permission
          # in the repo list — permissions.push maps to Contents:write (code
          # push). Issues/PR write do not set it, so they pass unaffected.
          _gh_repos=$(curl -s \
            -H "Authorization: Bearer ${MCP_GH_BEARER}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/user/repos?type=all&per_page=100&affiliation=owner,collaborator,organization_member" \
            2>/dev/null) || true
          if printf '%s' "$_gh_repos" | grep -q '"push": true'; then
            echo "ERROR: GitHub token (MCP_GH_BEARER) has code-push (Contents:write) access to one or more repositories." >&2
            echo "  The container forbids code-push access. Set the token's" >&2
            echo "  Contents permission to Read-only (Issues / Pull requests" >&2
            echo "  write is fine)." >&2
            echo "  See docs/mcp-servers.md for details." >&2
            exit 1
          fi
        fi
        echo ">> GitHub token (MCP_GH_BEARER) verified: no code-push (Contents:write) access."
        ;;
      "")
        echo ">> WARNING: Could not reach GitHub API — skipping token read-only check." >&2
        ;;
      *)
        echo ">> WARNING: GitHub API returned HTTP ${_gh_status} — skipping token read-only check." >&2
        ;;
    esac
  fi
fi
