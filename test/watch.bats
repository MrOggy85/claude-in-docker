#!/usr/bin/env bats
#
# Unit tests for proxy/watch.sh — the host-side egress alert watcher. Two halves
# are driven independently, neither of which needs Docker:
#
#   watch.sh process   access-log lines in, alert lines out (the classifier)
#   watch.sh notify    alert lines in, notifications out (coalescing + the
#                      sanitiser in scripts/notify.sh)
#
# The classifier decides what the user is told about a possible compromise, so
# the suite covers the log-format quirks (auth challenges, Squid placeholders,
# interleaved diagnostics), the per-project isolation, and the two gates that
# keep an attacker-chosen hostname out of an AppleScript string.
#
# Run with: bats test/watch.bats

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
WATCH="${SCRIPT_DIR}/proxy/watch.sh"

setup() {
  export CLAUDE_DOCKER_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  export CLAUDE_PROJECTS_DIR="${BATS_TEST_TMPDIR}/cfg/projects"
  mkdir -p "${CLAUDE_PROJECTS_DIR}"

  # A notifier stub: appends one line per notification instead of talking to the
  # desktop. Unquoted heredoc so ${NOTIFY_LOG} expands now and $1..$3 do not.
  export NOTIFY_LOG="${BATS_TEST_TMPDIR}/notifications"
  export CLAUDE_NOTIFY_CMD="${BATS_TEST_TMPDIR}/fake-notify"
  cat > "${CLAUDE_NOTIFY_CMD}" <<EOF
#!/bin/sh
printf '[%s] %s | %s\n' "\$1" "\$2" "\$(printf '%s' "\$3" | tr '\n' ';')" \
  >> "${NOTIFY_LOG}"
EOF
  chmod +x "${CLAUDE_NOTIFY_CMD}"
}

# Append one access-log line, in Squid's built-in format, to $LOG: the ten
# whitespace-separated fields the parser reads by position. Appending here rather
# than returning the line, because $(...) would eat the newline that separates
# two of them.
add() {  # <epoch> <result/status> <url> <project-key>
  add_req "$1" "$2" CONNECT "$3" "$4"
}

# Same, for a request logged INSIDE an established tunnel — the decrypted kind,
# whose method is its own and whose URL carries a path.
add_req() {  # <epoch> <result/status> <method> <url> <project-key>
  LOG+="$(printf '%s      1 172.19.0.3 %s 100 %s %s %s HIER_DIRECT/1.2.3.4 -' \
    "$1" "$2" "$3" "$4" "$5")"$'\n'
}

# Classify $LOG (or the argument); alert lines land in $output.
proc() {  # [log text]
  run "${WATCH}" process <<< "${1-${LOG}}"
}

# Both halves, as the daemon pipes them. Takes COALESCE seconds to return.
pipe_all() {  # <log text>
  "${WATCH}" process <<< "$1" | "${WATCH}" notify
}

# Alert lines straight into the notify half, bypassing the classifier.
pipe_notify() {  # <alert lines>
  printf '%s\n' "$1" | "${WATCH}" notify
}

seen_file() {  # <project-key>
  printf '%s' "${CLAUDE_PROJECTS_DIR}/$1/seen-hosts.txt"
}

# How many lines of $output mention <pattern>.
hits() {  # <pattern>
  printf '%s\n' "$output" | grep -c "$1" || true
}

# ---------------------------------------------------------------------------
# First-time-seen hosts
# ---------------------------------------------------------------------------

@test "new allowed host: alerts as info and is recorded" {
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ "$status" -eq 0 ]
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host" ]]
  run grep -Fx 'api.anthropic.com' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "known allowed host: silent" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  add 1001.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  [ "$(hits 'a.example.com')" -eq 1 ]
}

@test "the recorded set persists across invocations" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  [ -n "$output" ]
  LOG=""; add 2000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  [ -z "$output" ]
}

@test "each project has its own set: the same host alerts for both" {
  add 1000.0 TCP_TUNNEL/200 shared.example.com:443 proj-aaa111
  add 1001.0 TCP_TUNNEL/200 shared.example.com:443 proj-bbb222
  proc
  [ "$(hits 'shared.example.com')" -eq 2 ]
  [ -f "$(seen_file proj-aaa111)" ]
  [ -f "$(seen_file proj-bbb222)" ]
}

@test "the record file gets its explanatory header exactly once" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  LOG=""; add 2000.0 TCP_TUNNEL/200 b.example.com:443 proj-aaa111
  proc
  run grep -c '^#' "$(seen_file proj-aaa111)"
  [ "$output" -eq 2 ]
}

@test "comments and blank lines in the record file are not hosts" {
  mkdir -p "$(dirname "$(seen_file proj-aaa111)")"
  printf '# a comment\n\n  a.example.com  \n' > "$(seen_file proj-aaa111)"
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  [ -z "$output" ]   # whitespace around a recorded host still counts as seen
  LOG=""; add 1001.0 TCP_TUNNEL/200 comment:443 proj-aaa111
  proc
  [[ "$output" == *"new-host"* ]]
}

# ---------------------------------------------------------------------------
# Denied requests — the loudest compromise signal, so never squelched outright
# ---------------------------------------------------------------------------

@test "new denied host: alerts at the higher urgency" {
  add 1000.0 TCP_DENIED/403 169.254.169.254:443 proj-aaa111
  proc
  [[ "$output" == "alert"$'\t'"proj-aaa111"$'\t'"169.254.169.254"$'\t'"new-host-denied" ]]
}

@test "a denied host repeated inside the cooldown alerts once" {
  add 1000.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  add 1001.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  add 1002.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  proc
  [ "$(hits 'evil.test')" -eq 1 ]
}

@test "a denied host alerts again once the cooldown has passed" {
  add 1000.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  add 1301.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  proc
  [ "$(hits 'evil.test')" -eq 2 ]
  [[ "$output" == *$'\t'"denied" ]]   # the second is a repeat, not a new host
}

@test "the cooldown is configurable" {
  export CLAUDE_DENY_ALERT_COOLDOWN=1
  add 1000.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  add 1002.0 TCP_DENIED/403 evil.test:443 proj-aaa111
  proc
  [ "$(hits 'evil.test')" -eq 2 ]
}

@test "an allowed host stays silent even after being denied once" {
  add 1000.0 TCP_DENIED/403 x.example.com:443 proj-aaa111
  add 1001.0 TCP_TUNNEL/200 x.example.com:443 proj-aaa111
  proc
  [ "$(hits 'x.example.com')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Denied by a path/method rule — the host cleared the CONNECT and the request
# inside the tunnel did not, so the fix is the opposite of "allow this host".
# ---------------------------------------------------------------------------

@test "a 403 inside the tunnel is reported as a rule denial, not a host denial" {
  add     1000.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  add_req 1001.0 TCP_DENIED/403 POST https://api.example.com/admin proj-aaa111
  proc
  [ "$(hits 'denied-by-rule')" -eq 1 ]
  [ "$(hits '	denied$')" -eq 0 ]
}

@test "a rule denial on a host never seen before is still a rule denial" {
  # The CONNECT's log line is written when the tunnel closes, so the inner
  # request's 403 can arrive first — and must not read as an unlisted host.
  add_req 1000.0 TCP_DENIED/403 POST https://api.example.com/admin proj-aaa111
  proc
  [ "$(hits 'denied-by-rule')" -eq 1 ]
  [ "$(hits 'new-host-denied')" -eq 0 ]
}

@test "a denied CONNECT is still an unlisted host, not a rule denial" {
  add 1000.0 TCP_DENIED/403 evil.example.com:443 proj-aaa111
  proc
  [ "$(hits 'new-host-denied')" -eq 1 ]
  [ "$(hits 'denied-by-rule')" -eq 0 ]
}

@test "an allowed request inside the tunnel is silent, like any known host" {
  add     1000.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  add_req 1001.0 TCP_MISS/200 GET https://api.example.com/v1 proj-aaa111
  proc
  [ "$(hits 'api.example.com')" -eq 1 ]
}

@test "a rule denial does not suggest allowing the host" {
  pipe_notify "alert	proj-aaa111	api.example.com	denied-by-rule"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"DENIED by rule"* ]]
  [[ "$output" == *"path or method rule"* ]]
  [[ "$output" != *"domains add api.example.com"* ]]
}

@test "the two denial kinds in one burst become two notifications" {
  # One suggested command per notification, and theirs differ.
  pipe_notify "alert	proj-aaa111	a.example.com	denied
alert	proj-aaa111	b.example.com	denied-by-rule"
  run cat "${NOTIFY_LOG}"
  [ "$(hits 'DENIED')" -eq 2 ]
  [[ "$output" == *"domains add a.example.com"* ]]
  [[ "$output" != *"domains add b.example.com"* ]]
}

# ---------------------------------------------------------------------------
# Log-format quirks
# ---------------------------------------------------------------------------

@test "the 407 auth challenge is not a decision and is skipped" {
  add 1000.0 TCP_DENIED/407 a.example.com:443 -
  proc
  [ -z "$output" ]
}

@test "a line with no username is skipped" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 -
  proc
  [ -z "$output" ]
}

@test "Squid's own diagnostics on the same stream are skipped" {
  LOG='2026/08/26 12:00:00 kid1| Set Current Directory to /var/spool/squid'$'\n'
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  proc
  [ "$(hits .)" -eq 1 ]
}

@test "a bumped request logs a full URL: scheme and path are stripped" {
  add 1000.0 TCP_MISS/200 https://cdn.example.com/a/b.js?x proj-aaa111
  proc
  [[ "$output" == *$'\t'"cdn.example.com"$'\t'* ]]
}

@test "a non-default port is stripped from the host" {
  add 1000.0 TCP_MISS/200 https://cdn.example.com:8443/a proj-aaa111
  proc
  [[ "$output" == *$'\t'"cdn.example.com"$'\t'* ]]
}

@test "an uppercase host and a trailing dot normalise to one entry" {
  add 1000.0 TCP_TUNNEL/200 API.Example.COM.:443 proj-aaa111
  add 1001.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  proc
  [ "$(hits 'api.example.com')" -eq 1 ]   # already lowercased by the classifier
  run grep -Fx 'api.example.com' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "a Squid placeholder in place of a URL is not a host" {
  add 1000.0 NONE/503 error:transaction-end-before-headers proj-aaa111
  proc
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Untrusted input — the project key names a directory, the host reaches a
# notifier, and a container chooses both
# ---------------------------------------------------------------------------

@test "a traversal-shaped project key is ignored and writes nothing" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 ../../etc
  proc
  [ -z "$output" ]
  run find "${BATS_TEST_TMPDIR}" -name 'seen-hosts.txt'
  [ -z "$output" ]
}

@test "a key outside the run.sh charset is ignored" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 'Proj_AAA/x'
  proc
  [ -z "$output" ]
}

@test "a hostile hostname never reaches the notifier" {
  # Straight into the notify half, bypassing the classifier's host pattern, so
  # this exercises scripts/notify.sh's own stripping — the second of the two
  # gates, and the only one left if the first ever loosens.
  run pipe_notify 'alert	proj-aaa111	evil"$(id)`whoami`.test	denied'
  run cat "${NOTIFY_LOG}"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"'* ]]
  [[ "$output" != *'$'* ]]
  [[ "$output" != *'`'* ]]
  [[ "$output" == *"evil"* && "$output" == *".test"* ]]
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

@test "a burst becomes one notification per project and urgency" {
  add 1000.0 TCP_TUNNEL/200 a.example.com:443 proj-aaa111
  add 1000.1 TCP_TUNNEL/200 b.example.com:443 proj-aaa111
  add 1000.2 TCP_DENIED/403 evil.test:443 proj-aaa111
  add 1000.3 TCP_TUNNEL/200 c.example.com:443 proj-bbb222
  run pipe_all "${LOG}"
  [ "$status" -eq 0 ]
  run cat "${NOTIFY_LOG}"
  [ "$(hits .)" -eq 3 ]
  [[ "$output" == *"2 new egress hosts: proj-aaa111"* ]]
  [[ "$output" == *"a.example.com;b.example.com"* ]]
  [[ "$output" == *"[alert] Egress DENIED: proj-aaa111"* ]]
  [[ "$output" == *"New egress host: proj-bbb222"* ]]
}

@test "a single denied host is named in the fix hint" {
  run pipe_notify 'alert	proj-aaa111	169.254.169.254	denied'
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"cid domains add 169.254.169.254"* ]]
}

@test "every alert is written to the audit log whatever the notifier" {
  run pipe_notify 'info	proj-aaa111	a.example.com	new-host'
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/egress-alerts.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"info"$'\t'* ]]
  [[ "$output" == *"a.example.com"* ]]
}

@test "more than five hosts in one burst are summarised, not listed" {
  local ts=1000 h
  for h in a b c d e f g; do
    add "${ts}.0" TCP_TUNNEL/200 "${h}.example.com:443" proj-aaa111
    ts=$((ts + 1))
  done
  run pipe_all "${LOG}"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"7 new egress hosts"* ]]
  [[ "$output" == *"...and 2 more"* ]]
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

@test "status reports a watcher that is not running, and exits 0" {
  run "${WATCH}" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT running"* ]]
}

@test "status names the notifier and this project's record" {
  run "${WATCH}" status
  [[ "$output" == *"notifier"* ]]
  [[ "$output" == *"hosts recorded for"* ]]
}

@test "stop with nothing running is not an error" {
  run "${WATCH}" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"no egress alert watcher running"* ]]
}

@test "a recycled pid does not read as a running watcher" {
  # $$ is bats, which is alive but is not watch.sh — the trap commit 6026478
  # fixed for Chrome.
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf '%s\n' "$$" > "${CLAUDE_DOCKER_CONFIG_DIR}/watcher.pid"
  run "${WATCH}" status
  [[ "$output" == *"NOT running"* ]]
}

@test "the daemon refuses to run without docker instead of retrying" {
  # A PATH with everything the script needs before the docker check, and nothing
  # else. `dirname` (for SCRIPT_DIR) is the whole of that set — if this test
  # starts failing on a missing command, something new runs before the check.
  # Absolute bash, since the replaced PATH also decides where bash comes from.
  local bin="${BATS_TEST_TMPDIR}/nodocker"
  mkdir -p "${bin}"
  ln -s "$(command -v dirname)" "${bin}/dirname"
  run env PATH="${bin}" "$(command -v bash)" "${WATCH}" _daemon
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker not found"* ]]
}

@test "an unknown verb is a usage error" {
  run "${WATCH}" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown verb"* ]]
}
