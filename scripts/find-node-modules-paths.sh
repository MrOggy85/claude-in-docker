#!/usr/bin/env bash
#
# Print repo-relative node_modules paths for every package.json in a project,
# one per line — the expansion behind run.sh's `CLAUDE_VOLUME_PATHS=auto`. For
# each directory containing a package.json, emit "<reldir>/node_modules" (or
# "node_modules" at the project root).
#
# A node_modules is always created as a sibling of the package.json that
# declares the deps (the root package, and each workspace package in a
# monorepo), so package.json locations are the set of POTENTIAL node_modules
# locations. Directories named node_modules or .git are pruned, so package.json
# files vendored inside dependencies are ignored.
#
# Usage: find-node-modules-paths.sh <project-dir>
set -euo pipefail

ROOT="${1:?usage: find-node-modules-paths.sh <project-dir>}"
ROOT="${ROOT%/}"

# Process substitution (not a pipe) feeds the loop so find's exit status — it
# returns non-zero on unreadable subdirs even with stderr silenced — can't trip
# pipefail. sort -u gives deterministic, de-duplicated output.
while IFS= read -r pkg; do
  dir="$(dirname "$pkg")"
  rel="${dir#"$ROOT"}"; rel="${rel#/}"
  if [ -n "$rel" ]; then printf '%s/node_modules\n' "$rel"
  else                   printf 'node_modules\n'; fi
done < <(
  find "$ROOT" -type d \( -name node_modules -o -name .git \) -prune \
       -o -type f -name package.json -print 2>/dev/null
) | sort -u
