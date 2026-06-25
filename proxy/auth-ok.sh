#!/bin/sh
# Squid basic-auth helper that accepts ANY credentials.
#
# We don't authenticate users — we only need Squid to populate %LOGIN with the
# proxy username (the project key) so ext-allowlist.sh can select that project's
# allowlist. Squid sends one "<user> <password>" line per request on stdin and
# expects "OK" or "ERR" per line. We always answer OK.
#
# `read -r` keeps backslashes literal; the loop exits when Squid closes stdin.
while read -r _line; do
  echo "OK"
done
