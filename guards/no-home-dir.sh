#!/usr/bin/env bash
#
# Guard: refuse to run from the user's home directory to prevent accidental
# exposure of home directory contents to the container.
#
# Sourced by run.sh (not run standalone): reads PROJECT_DIR and HOME from the
# caller and `exit`s the whole run on violation.

if [[ "${PROJECT_DIR}" == "${HOME}" ]]; then
  fail "Running claude-in-docker from your home directory is not allowed." \
       "This would mount your entire home directory into the container," \
       "defeating the purpose of the sandboxed environment." \
       "Please cd into a project subdirectory first."
  exit 1
fi
