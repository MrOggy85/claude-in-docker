#!/usr/bin/env bash
#
# Guard: verify that MCP_GH_BEARER, if set, is a read-only GitHub token.
# A write-capable token could allow Claude to mutate repositories, defeating
# the container's security model. Use a fine-grained PAT with read-only scopes.
# See docs/mcp-servers.md.
#
# Sourced by run.sh (not run standalone): reads MCP_GH_BEARER from the caller
# and `exit`s the whole run when the token is invalid or write-capable. Network
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
          # Classic token: reject if any write-capable scope is present.
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
            echo "  The container requires a read-only token. Replace it with a" >&2
            echo "  fine-grained PAT scoped to read-only repository access." >&2
            echo "  See docs/mcp-servers.md for details." >&2
            exit 1
          fi
        else
          # Fine-grained PAT (X-OAuth-Scopes is empty): check push permission
          # in the repo list — each entry's permissions.push shows whether the
          # token can write to that repo.
          _gh_repos=$(curl -s \
            -H "Authorization: Bearer ${MCP_GH_BEARER}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/user/repos?type=all&per_page=100&affiliation=owner,collaborator,organization_member" \
            2>/dev/null) || true
          if printf '%s' "$_gh_repos" | grep -q '"push": true'; then
            echo "ERROR: GitHub token (MCP_GH_BEARER) has write (push) access to one or more repositories." >&2
            echo "  The container requires a read-only token. Replace it with a" >&2
            echo "  fine-grained PAT scoped to read-only repository access." >&2
            echo "  See docs/mcp-servers.md for details." >&2
            exit 1
          fi
        fi
        echo ">> GitHub token (MCP_GH_BEARER) verified read-only."
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
