#!/usr/bin/env bash
#
# Guard: refuse to run from the user's home directory to prevent accidental
# exposure of home directory contents to the container.
#
# Sourced by run.sh (not run standalone): reads PROJECT_DIR and HOME from the
# caller and `exit`s the whole run on violation.

if [[ "${PROJECT_DIR}" == "${HOME}" ]]; then
  echo "ERROR: Running claude-in-docker from your home directory is not allowed." >&2
  echo "  This would mount your entire home directory into the container," >&2
  echo "  defeating the purpose of the sandboxed environment." >&2
  echo "  Please cd into a project subdirectory first." >&2
  exit 1
fi
