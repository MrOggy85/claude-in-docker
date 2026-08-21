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
  fail "no baseline config found in ${CONFIG_DIR}" \
       "(missing ${CONFIG_DIR}/.env)" \
       "This looks like a first-time setup. Run \`make init\` to create the" \
       "default config, then re-run."
  exit 1
fi

# skip-decryption.txt is newer than the .env marker, so a config dir seeded by an
# older version passes the check above and would then fail deeper in, inside
# proxy/up.sh (which bind-mounts exactly this path). Say it here instead.
if [[ ! -f "${CONFIG_DIR}/skip-decryption.txt" ]]; then
  fail "no ${CONFIG_DIR}/skip-decryption.txt" \
       "The proxy mounts it to decide which hosts it must not decrypt. Run" \
       "\`make init\` to add it (existing files are left untouched), then re-run." \
       "See docs/tls-inspection.md."
  exit 1
fi
