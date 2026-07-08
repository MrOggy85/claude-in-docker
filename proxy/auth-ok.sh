#!/bin/sh
# Squid basic-auth helper that accepts ANY credentials.
#
# We don't authenticate; we only need Squid to populate %LOGIN with the username
# (the project key) for ext-allowlist.sh. Squid sends one "<user> <password>"
# line per request and expects "OK"/"ERR" — we always answer OK.
#
# `read -r` keeps backslashes literal; the loop exits when Squid closes stdin.
while read -r _line; do
  echo "OK"
done
