#!/bin/sh
# Installed into the image as /usr/local/claude-bin/playwright-cli, ahead of npm's
# global bin on PATH, so every call picks up the generated config without the
# session having to remember a flag. run.sh writes that config (step 3c-e) with
# the Squid credentials this container needs; see docs/browser-vnc.md.
#
# POSIX sh, no bashisms: same reason as init-firewall.sh and proxy/auth-ok.sh —
# this runs in the image, where nothing guarantees which shell is /bin/sh.
#
# Why inject on only two subcommands: `--config` is NOT a global option. Only
# `open` and `attach` accept it, and every other subcommand hard-errors with
# "Unknown option: --config". Those two are also the ONLY ones that launch a
# browser (`goto` on a closed session answers "please run open first"), so
# config cannot be missed by narrowing to them.
#
# Why not PLAYWRIGHT_MCP_CONFIG instead: the CLI honours it, but a project's own
# .playwright/cli.config.json in the working directory WINS over it, which would
# silently drop the proxy settings and leave the browser unable to reach anything
# (direct egress is dropped by init-firewall.sh). An explicit --config outranks
# that file, so the flag is the only mechanism that cannot be overridden by the
# repo being worked on.
#
# The flag is APPENDED, not prepended: `open <url> --config <path>` is the form
# that parses, and appending also means our config wins if the caller passed one
# of their own — deliberate, since theirs would not carry the proxy credentials.
set -u

CFG="${CLAUDE_PLAYWRIGHT_CONFIG:-/etc/claude/playwright-cli.config.json}"
REAL="${NVM_DIR:-/home/dev/.nvm}/default/bin/playwright-cli"

if [ ! -x "$REAL" ]; then
  echo "playwright-cli is not installed — re-run the session with CLAUDE_BROWSER=1" >&2
  exit 127
fi

# The subcommand is the first argument that is not an option: `-s=<session>` and
# other global flags may precede it.
verb=''
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) verb="$a"; break ;;
  esac
done

if [ -f "$CFG" ]; then
  case "$verb" in
    open|attach) exec "$REAL" "$@" --config "$CFG" ;;
  esac
fi

exec "$REAL" "$@"
