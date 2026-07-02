#!/usr/bin/env bash
#
# migrate-config.sh — one-time move of a pre-existing repo-root config into the
# dedicated config dir (~/.config/claude-in-docker by default).
#
# Older versions of this tool kept user config (settings.json, credentials,
# allowed-domains.txt, per-project dirs, ...) gitignored in the repo root. Config
# now lives outside the repo so a checkout stays clean. This moves anything left
# behind. It is NON-DESTRUCTIVE: a file already present in the config dir is left
# as-is and the repo copy is reported, never overwritten.
#
# install_additional_packages.sh is intentionally NOT moved: it is baked into the
# base image at build time and must stay in the repo (the build context).
#
# Run on the host:  ./scripts/migrate-config.sh   (or: make migrate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/paths.sh"

CONFIG_DIR="$(config_dir)"
PROJECTS_DIR="$(projects_dir)"

if [[ "${REPO_DIR}" == "${CONFIG_DIR}" ]]; then
  echo ">> repo dir and config dir are the same (${CONFIG_DIR}); nothing to migrate."
  exit 0
fi

# Files that used to live at the repo root and now belong in the config dir.
FILES=(
  settings.json claude.json mcp-servers.json container-CLAUDE.md
  .gitconfig .gitignore_global .credentials.json allowed-domains.txt .env
)

mkdir -p "${CONFIG_DIR}"

moved=0 skipped=0
echo ">> config dir: ${CONFIG_DIR}"
for f in "${FILES[@]}"; do
  src="${REPO_DIR}/${f}"
  dst="${CONFIG_DIR}/${f}"
  [[ -e "${src}" ]] || continue
  if [[ -e "${dst}" ]]; then
    echo "   skip  ${f}  (already in config dir; repo copy left at ${src})"
    skipped=$((skipped + 1))
  else
    mv "${src}" "${dst}"
    echo "   move  ${f}"
    moved=$((moved + 1))
  fi
done

# Per-project config dirs: repo/projects/<key>/ -> <projects-dir>/<key>/.
repo_projects="${REPO_DIR}/projects"
if [[ -d "${repo_projects}" && "${repo_projects}" != "${PROJECTS_DIR}" ]]; then
  mkdir -p "${PROJECTS_DIR}"
  while IFS= read -r d; do
    name="$(basename "${d}")"
    dst="${PROJECTS_DIR}/${name}"
    if [[ -e "${dst}" ]]; then
      echo "   skip  projects/${name}  (already present at ${dst})"
      skipped=$((skipped + 1))
    else
      mv "${d}" "${dst}"
      echo "   move  projects/${name}"
      moved=$((moved + 1))
    fi
  done < <(find "${repo_projects}" -mindepth 1 -maxdepth 1 -type d)
fi

echo ">> done: ${moved} moved, ${skipped} skipped."
[[ "${skipped}" -gt 0 ]] && echo ">> skipped items were NOT overwritten — reconcile them by hand if needed."
echo ">> view the result with: ./config.sh list"
