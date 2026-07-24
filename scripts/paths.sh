#!/usr/bin/env bash
#
# Shared path & identifier helpers, sourced (not executed) by run.sh, the egress
# proxy (proxy/up.sh), and the config CLI (cid). Keeping the derivations in
# one place guarantees that the config directory the CLI shows, the files run.sh
# mounts, and the per-project allowlist the proxy enforces all agree.
#
# No side effects: only function definitions and no `set` changes, so it is safe
# to source from a script that manages its own shell options.

# Dedicated, XDG-style config directory for this tool. All user-managed config
# lives here (outside the repo), so a fresh checkout stays clean. Precedence:
#   1. CLAUDE_DOCKER_CONFIG_DIR  — explicit override (used by the test suite)
#   2. $XDG_CONFIG_HOME/claude-in-docker  — honours a custom XDG base
#   3. ~/.config/claude-in-docker  — the default
config_dir() {
  printf '%s' "${CLAUDE_DOCKER_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/claude-in-docker}"
}

# Base directory holding every per-project config dir. Defaults to projects/
# under the config dir; CLAUDE_PROJECTS_DIR overrides it (the test suite points
# this at a throwaway dir so test runs never touch the real config).
projects_dir() {
  printf '%s' "${CLAUDE_PROJECTS_DIR:-$(config_dir)/projects}"
}

# First 10 hex chars of the SHA-256 of the argument. Portable across coreutils
# `sha256sum` and macOS `shasum`.
path_hash() {  # <string>
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-10
  else printf '%s' "$1" | shasum -a 256 | cut -c1-10; fi
}

# Sanitized, lowercase basename of a directory: characters outside [a-z0-9]
# collapse to a single '-', with leading/trailing '-' trimmed. May be empty when
# the basename has no alphanumerics (callers apply a ":-repo" fallback).
safe_name() {  # <dir>
  local s
  s="$(printf '%s' "$(basename "$1")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  printf '%s' "$s" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# The stable per-project key: "<safe-name-or-repo>-<path-hash>". Doubles as the
# directory name under <projects-dir>/ and as the Squid proxy username that
# selects this project's allowlist.
project_key() {  # <dir>
  local sn; sn="$(safe_name "$1")"
  printf '%s-%s' "${sn:-repo}" "$(path_hash "$1")"
}
