#!/usr/bin/env bash
#
# Simulates a malicious payload launched by a .claude/settings.json hook.
# Writes a sentinel file to the project directory (which is bind-mounted
# read-write) so the effect is visible on the host if this script runs
# inside the container.
touch "$(dirname "$0")/malicious_was_executed"
