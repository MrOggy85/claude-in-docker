#!/usr/bin/env bats
#
# Unit tests for scripts/colors.sh — the shared palette and the emitters every
# run-time message goes through.
#
# Two properties matter more than the escape codes themselves:
#   1. WHICH STREAM. say/kv/ok follow the fd declared by color_init; warn/fail
#      are always stderr. The scripts whose stdout carries `docker run` tokens
#      (extra-mounts, extra-ports, path-volumes) break silently if that slips.
#   2. NO ABORT. Every caller runs under `set -euo pipefail`, so an emitter that
#      ends on a false test would kill the run it was only meant to describe.
#
# Run with: bats test/colors.bats

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
COLORS="${SCRIPT_DIR}/scripts/colors.sh"

# Pin the three deciding vars per case: inheriting any of them would make the
# result depend on where the suite runs (CI runners export TERM=dumb).
_env() { env -u NO_COLOR -u CLICOLOR_FORCE -u TERM "$@"; }

# Source colors.sh and run <body> under the callers' shell options.
_sh() {  # <body>
  _env "$@" bash -c "set -euo pipefail; source '${COLORS}'; ${BODY}"
}

# ---------------------------------------------------------------------------
# Colour precedence
# ---------------------------------------------------------------------------

@test "colors: no colour when the stream is not a terminal" {
  BODY='color_init 1; kv label value' run _sh TERM=xterm
  [[ "$output" != *$'\033['* ]]
}

@test "colors: CLICOLOR_FORCE colours the value, even where TERM claims dumb" {
  BODY='color_init 1; kv label value' run _sh TERM=dumb CLICOLOR_FORCE=1
  [[ "$output" == *$'\033[36mvalue\033[0m'* ]]
}

@test "colors: NO_COLOR beats an explicit CLICOLOR_FORCE" {
  BODY='color_init 1; kv label value' run _sh CLICOLOR_FORCE=1 NO_COLOR=1
  [[ "$output" != *$'\033['* ]]
}

@test "colors: TERM=dumb suppresses colour when nothing is forced" {
  BODY='color_init 1; kv label value' run _sh TERM=dumb
  [[ "$output" != *$'\033['* ]]
}

# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

@test "colors: say/kv/ok go to stdout by default" {
  BODY='color_init 1; say s; kv k v; ok o' run --separate-stderr _sh TERM=dumb
  [ "$output" = ">> s
>> k: v
>> o" ]
  [ -z "$stderr" ]
}

@test "colors: color_init 2 moves say/kv/ok to stderr, leaving stdout clean" {
  BODY='color_init 2; kv k v; printf "token\n"' run --separate-stderr _sh TERM=dumb
  [ "$output" = "token" ]
  [ "$stderr" = ">> k: v" ]
}

@test "colors: warn/fail stay on stderr whichever fd the info stream uses" {
  BODY='color_init 1; warn w; fail f' run --separate-stderr _sh TERM=dumb
  [ -z "$output" ]
  [ "$stderr" = "WARNING: w
ERROR: f" ]
}

@test "colors: an fd-2 info stream is coloured from fd 2, not the piped stdout" {
  # What the three token-emitting scripts rely on: stdout captured, stderr a
  # terminal. No pty here, so CLICOLOR_FORCE stands in for the tty — the point
  # is that the decision is not read off the (piped) fd 1.
  BODY='color_init 2; kv k v; printf "token\n"' run --separate-stderr _sh TERM=dumb CLICOLOR_FORCE=1
  [ "$output" = "token" ]
  [[ "$stderr" == *$'\033[36mv\033[0m'* ]]
}

# ---------------------------------------------------------------------------
# Message shapes
# ---------------------------------------------------------------------------

@test "colors: kv renders label, value and an optional parenthesised hint" {
  BODY='color_init 1; kv "session volume" vol; kv "session volume" vol "docker volume inspect vol"' \
    run _sh TERM=dumb
  [ "${lines[0]}" = ">> session volume: vol" ]
  [ "${lines[1]}" = ">> session volume: vol  (docker volume inspect vol)" ]
}

@test "colors: fail prints a headline plus two-space-indented continuations" {
  BODY='color_init 1; fail "headline" "first" "second"' run _sh TERM=dumb
  [ "${lines[0]}" = "ERROR: headline" ]
  [ "${lines[1]}" = "  first" ]
  [ "${lines[2]}" = "  second" ]
}

@test "colors: a bare warn emits exactly one line" {
  BODY='color_init 1; warn "solo"' run _sh TERM=dumb
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "WARNING: solo" ]
}

@test "colors: cont with no argument emits a blank separator line" {
  BODY='color_init 1; warn "headline"; cont; cont "after"' run _sh TERM=dumb
  [ "${lines[0]}" = "WARNING: headline" ]
  [ "${lines[1]}" = "  after" ]   # bats drops the blank line from $lines
  [ "$output" = "WARNING: headline

  after" ]
}

# ---------------------------------------------------------------------------
# Not booby-trapped
# ---------------------------------------------------------------------------

@test "colors: no emitter aborts the caller under set -e" {
  BODY='color_init 1; kv k v; say s; ok o; warn w; fail f; cont c; printf "reached\n"' \
    run _sh TERM=dumb
  [ "$status" -eq 0 ]
  [[ "$output" == *reached* ]]
}

@test "colors: a % in a value is printed, not interpreted as a format" {
  BODY='color_init 1; kv label "100%s"; fail "%d%%"' run _sh TERM=dumb
  [[ "$output" == *">> label: 100%s"* ]]
  [[ "$output" == *"ERROR: %d%%"* ]]
}

@test "colors: sourcing alone leaves the palette empty, so set -u is safe" {
  BODY='printf "[%s][%s][%s]\n" "${C_DIM}" "${C_VALUE}" "${C_FAIL}"' \
    run _sh TERM=xterm CLICOLOR_FORCE=1
  [ "$output" = "[][][]" ]
}
