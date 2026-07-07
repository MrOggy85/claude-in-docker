#!/usr/bin/env bash
#
# Guard: refuse to run against an un-initialized config dir.
#
# `make init` seeds the config dir from templates/ (see Makefile). The baseline
# .env is the marker used here: `make init` always creates it, and run.sh relies
# on it existing so it can pass `docker --env-file` unconditionally. If it is
# absent we treat the setup as un-initialized (a first-time user, or a config dir
# predating the .env addition) and stop with a pointer to `make init`, rather
# than silently running with partial defaults.
#
# Sourced by run.sh (not run standalone): reads CONFIG_DIR from the caller and
# `exit`s the whole run before any build, volume, or container work.

if [[ ! -f "${CONFIG_DIR}/.env" ]]; then
  echo "ERROR: no baseline config found in ${CONFIG_DIR}" >&2
  echo "  (missing ${CONFIG_DIR}/.env)" >&2
  echo "  This looks like a first-time setup. Run \`make init\` to create the" >&2
  echo "  default config, then re-run." >&2
  exit 1
fi
