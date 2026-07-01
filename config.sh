#!/usr/bin/env bash
#
# config.sh — inspect the claude-in-docker configuration.
#
# All user config lives OUTSIDE this repo, in a dedicated dir
# (~/.config/claude-in-docker by default; see scripts/paths.sh). You edit those
# files by hand; this tool is a read-only viewer so you can find and check them.
#
# Usage:
#   config.sh [list]           Show the config dir and every global config file
#                              (present / missing), plus the projects dir.
#   config.sh show <file>      Print a global config file (e.g. settings.json,
#                              allowed-domains.txt). Credentials are never dumped.
#   config.sh project [dir]    Show the per-project key + config dir for a project
#                              (default: current dir) and which overrides exist.
#   config.sh domains [dir]    Show the effective egress allowlist for a project:
#                              the baseline plus any per-project additions.
#   config.sh help             This help.
#
# It never writes anything — to change config, edit the files it points you at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/paths.sh"

CONFIG_DIR="$(config_dir)"
PROJECTS_DIR="$(projects_dir)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Global config files run.sh mounts from the config dir, with a one-line note.
# (install_additional_packages.sh is deliberately absent: it is baked into the
#  image at build time, so it lives in the repo, not the config dir — see below.)
GLOBAL_FILES=(
  "settings.json|Claude Code settings mounted at ~/.claude/settings.json"
  "claude.json|Onboarding state + user-level config (mounted read-write)"
  "mcp-servers.json|MCP server definitions, injected via --mcp-config"
  "container-CLAUDE.md|Personal instructions mounted at ~/.claude/CLAUDE.md"
  ".gitconfig|git user.name / user.email"
  ".gitignore_global|Global gitignore mounted at ~/.config/git/ignore"
  ".credentials.json|Claude auth token (secret; not printed by 'show')"
  "allowed-domains.txt|Baseline egress allowlist enforced by the Squid proxy"
  ".env|Arbitrary KEY=VALUE env vars injected via --env-file"
)

err()  { printf '%s\n' "$*" >&2; }
head_() { printf '\n== %s ==\n' "$*"; }

cmd_list() {
  head_ "Config directory"
  printf '  %s' "${CONFIG_DIR}"
  [[ -d "${CONFIG_DIR}" ]] || printf '   (does not exist yet — run: make init)'
  printf '\n'

  head_ "Global config files"
  local entry fname desc path status
  for entry in "${GLOBAL_FILES[@]}"; do
    fname="${entry%%|*}"; desc="${entry#*|}"
    path="${CONFIG_DIR}/${fname}"
    if [[ -f "${path}" ]]; then status="present"; else status="missing"; fi
    printf '  [%-7s] %-28s %s\n' "${status}" "${fname}" "${desc}"
  done

  head_ "Build-time config (stays in the repo)"
  local ipath="${SCRIPT_DIR}/install_additional_packages.sh"
  if [[ -f "${ipath}" ]]; then status="present"; else status="missing"; fi
  printf '  [%-7s] %-28s %s\n' "${status}" "install_additional_packages.sh" \
    "Baked into the base image; lives at ${ipath}"

  head_ "Per-project config"
  printf '  projects dir: %s\n' "${PROJECTS_DIR}"
  if [[ -d "${PROJECTS_DIR}" ]]; then
    local n; n="$(find "${PROJECTS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    printf '  %s project dir(s). Inspect one with: config.sh project [dir]\n' "${n}"
  else
    printf '  (none yet — created on first run in a project)\n'
  fi
  printf '\n'
}

cmd_show() {
  local fname="${1:-}"
  [[ -n "${fname}" ]] || { err "usage: config.sh show <file>"; return 2; }
  # Basename only — no path components, so 'show' can never read outside the
  # config dir (or the repo, for the one build-time file).
  if [[ "${fname}" == */* || "${fname}" == "." || "${fname}" == ".." ]]; then
    err "refusing: give a bare filename, e.g. 'config.sh show settings.json'"
    return 2
  fi
  if [[ "${fname}" == ".credentials.json" ]]; then
    local cpath="${CONFIG_DIR}/.credentials.json"
    if [[ -f "${cpath}" ]]; then
      err "Refusing to print credentials. ${cpath} exists (mode $(stat -c '%a' "${cpath}" 2>/dev/null || stat -f '%A' "${cpath}" 2>/dev/null))."
    else
      err "${cpath} does not exist. Run: make init"
    fi
    return 1
  fi
  local path
  if [[ "${fname}" == "install_additional_packages.sh" ]]; then
    path="${SCRIPT_DIR}/${fname}"   # build-time file, stays in the repo
  else
    path="${CONFIG_DIR}/${fname}"
  fi
  if [[ ! -f "${path}" ]]; then
    err "not found: ${path}"
    err "known files: $(printf '%s ' "${GLOBAL_FILES[@]%%|*}")install_additional_packages.sh"
    return 1
  fi
  printf '# %s\n' "${path}"
  cat "${path}"
}

cmd_project() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || { err "no such dir: ${1:-$PWD}"; return 1; }
  local key pdir
  key="$(project_key "${dir}")"
  pdir="${PROJECTS_DIR}/${key}"
  head_ "Project"
  printf '  path:  %s\n' "${dir}"
  printf '  key:   %s   (Squid proxy username / volume suffix)\n' "${key}"
  printf '  dir:   %s' "${pdir}"
  [[ -d "${pdir}" ]] || printf '   (not created yet — created on first run here)'
  printf '\n'

  head_ "Overrides (fall back to the global file when absent)"
  local f
  for f in allowed-domains.txt .env container-CLAUDE.md mcp-servers.json install_additional_packages.sh; do
    if [[ -f "${pdir}/${f}" ]]; then
      printf '  [override] %s\n' "${f}"
    else
      printf '  [global  ] %s\n' "${f}"
    fi
  done
  printf '\n'
}

# Print a file with a header, or a "using template" / "none" note.
_dump_domains() {  # <label> <path> [fallback-path]
  local label="$1" path="$2" fallback="${3:-}"
  if [[ -f "${path}" ]]; then
    printf '# %s: %s\n' "${label}" "${path}"
    cat "${path}"
  elif [[ -n "${fallback}" && -f "${fallback}" ]]; then
    printf '# %s: %s (config copy absent — this template is what the proxy uses)\n' "${label}" "${fallback}"
    cat "${fallback}"
  else
    printf '# %s: none\n' "${label}"
  fi
  printf '\n'
}

cmd_domains() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || { err "no such dir: ${1:-$PWD}"; return 1; }
  local key pdir
  key="$(project_key "${dir}")"
  pdir="${PROJECTS_DIR}/${key}"
  head_ "Effective egress allowlist for ${key}"
  printf 'The proxy allows a host if it matches EITHER list below.\n'
  _dump_domains "Baseline" "${CONFIG_DIR}/allowed-domains.txt" "${TEMPLATES_DIR}/allowed-domains.txt"
  _dump_domains "Per-project additions" "${pdir}/allowed-domains.txt"
}

cmd_help() {
  cat <<EOF
config.sh — read-only viewer for the claude-in-docker configuration.

Config lives in: ${CONFIG_DIR}
(edit those files by hand; this tool only shows them)

Commands:
  list                Config dir + every global file (present/missing) + projects dir
  show <file>         Print a global config file (credentials are never dumped)
  project [dir]       Per-project key, config dir, and which overrides exist
  domains [dir]       Effective egress allowlist (baseline + per-project) for a project
  help                This help

Seed the config dir with 'make init'; migrate an old repo-root config with 'make migrate'.
EOF
}

main() {
  local cmd="${1:-list}"; shift || true
  case "${cmd}" in
    list|"")     cmd_list ;;
    show)        cmd_show "$@" ;;
    project)     cmd_project "$@" ;;
    domains)     cmd_domains "$@" ;;
    help|-h|--help) cmd_help ;;
    *) err "unknown command: ${cmd}"; err "run: config.sh help"; return 2 ;;
  esac
}

main "$@"
