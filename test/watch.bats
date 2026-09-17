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
# whose method is its own and whose URL carries a path. The hierarchy defaults to
# HIER_DIRECT (an upstream was contacted); pass NONE/- for a line Squid answered
# by itself, which is what its own denials look like.
add_req() {  # <epoch> <result/status> <method> <url> <project-key> [hierarchy]
  LOG+="$(printf '%s      1 172.19.0.3 %s 100 %s %s %s %s -' \
    "$1" "$2" "$3" "$4" "$5" "${6:-HIER_DIRECT/1.2.3.4}")"$'\n'
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
# The origin's own 403 — relayed, not imposed. Squid logs it with the result code
# of a normal fetch and a hierarchy naming the server it reached, so only those
# two fields tell it from a denial the allowlist made.
# ---------------------------------------------------------------------------

@test "an origin 403 relayed through the tunnel is not a rule denial" {
  add     1000.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  add_req 1001.0 TCP_MISS/403 POST https://api.example.com/v1/login proj-aaa111
  proc
  [ "$(hits 'upstream-403')" -eq 1 ]
  [ "$(hits 'denied-by-rule')" -eq 0 ]
  [ "$(hits '^alert')" -eq 0 ]
}

@test "an origin 403 on a first contact reports both the new host and the refusal" {
  add_req 1000.0 TCP_MISS/403 GET https://api.example.com/v1 proj-aaa111
  proc
  [ "$(hits 'new-host$')" -eq 1 ]
  [ "$(hits 'upstream-403')" -eq 1 ]
  [ "$(hits 'new-host-denied')" -eq 0 ]
}

@test "a Squid denial reaching no upstream is a denial whatever its result code" {
  # Belt and braces for the result-code test: a line that contacted nobody
  # cannot be relaying anyone's 403, so it must fall to the denial side.
  add_req 1000.0 TAG_NONE/403 POST https://api.example.com/admin proj-aaa111 NONE/-
  proc
  [ "$(hits 'denied-by-rule')" -eq 1 ]
  [ "$(hits 'upstream-403')" -eq 0 ]
}

@test "TCP_DENIED_ABORTED still reads as a denial" {
  add_req 1000.0 TCP_DENIED_ABORTED/403 POST https://api.example.com/admin proj-aaa111
  proc
  [ "$(hits 'denied-by-rule')" -eq 1 ]
  [ "$(hits 'upstream-403')" -eq 0 ]
}

@test "a repeated origin 403 is squelched by its own cooldown" {
  add     1000.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  add_req 1001.0 TCP_MISS/403 GET https://api.example.com/v1 proj-aaa111
  add_req 1002.0 TCP_MISS/403 GET https://api.example.com/v1 proj-aaa111
  add_req 1302.0 TCP_MISS/403 GET https://api.example.com/v1 proj-aaa111
  proc
  [ "$(hits 'upstream-403')" -eq 2 ]
}

@test "an origin 403 does not squelch a real denial for the same host" {
  # Separate cooldown maps: the security-relevant alert must survive a chatty
  # server 403ing inside the window.
  add     1000.0 TCP_TUNNEL/200 api.example.com:443 proj-aaa111
  add_req 1001.0 TCP_MISS/403 GET https://api.example.com/v1 proj-aaa111
  add_req 1002.0 TCP_DENIED/403 POST https://api.example.com/admin proj-aaa111
  proc
  [ "$(hits 'upstream-403')" -eq 1 ]
  [ "$(hits 'denied-by-rule')" -eq 1 ]
}

@test "an origin 403 notifies without the language of a block" {
  pipe_notify "info	proj-aaa111	api.example.com	upstream-403"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == "[info]"* ]]
  [[ "$output" == *"Upstream refused"* ]]
  [[ "$output" == *"api.example.com 403"* ]]
  [[ "$output" != *"DENIED"* ]]
  [[ "$output" != *"cid domains"* ]]
}

@test "a new host and an origin 403 in one burst stay two notifications" {
  pipe_notify "info	proj-aaa111	api.example.com	new-host
info	proj-aaa111	api.example.com	upstream-403"
  run cat "${NOTIFY_LOG}"
  [ "$(hits '^\[info\]')" -eq 2 ]
  [[ "$output" == *"New egress host"* ]]
  [[ "$output" == *"Upstream refused"* ]]
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

# ---------------------------------------------------------------------------
# Why it was allowed — the provenance of a first-time host
#
# The classifier asks proxy/ext-allowlist.sh --explain which entry covers a new
# host, and carries the answer into the alert line and the record. Note what
# setup() does NOT do: seed an allowlist. Every test above therefore runs with
# nothing to explain, which is how "no reason" is pinned as byte-identical to a
# watcher without this feature — the property that makes the whole thing
# additive. Tests here opt in with seed_baseline / seed_project.
# ---------------------------------------------------------------------------

seed_baseline() {  # <entry>...
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf '%s\n' "$@" > "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
}

seed_project() {  # <project-key> <entry>...
  local key="$1"; shift
  mkdir -p "${CLAUDE_PROJECTS_DIR}/${key}"
  printf '%s\n' "$@" > "${CLAUDE_PROJECTS_DIR}/${key}/allowed-domains.txt"
}

@test "provenance: an exact baseline entry is named in the alert and the record" {
  seed_baseline api.anthropic.com
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host"$'\t'"api.anthropic.com (baseline exact)" ]]
  # Host column is padded to a fixed width, so match the two ends, not the gap.
  run grep -E '^api\.anthropic\.com +# allowed by: api\.anthropic\.com \(baseline exact\)$' \
    "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "provenance: a wildcard is called out as one" {
  # The case the feature exists for: nobody approved this exact host.
  seed_baseline .example.com
  add 1000.0 TCP_TUNNEL/200 cdn-metrics-7f3a.example.com:443 proj-aaa111
  proc
  [[ "$output" == *$'\t'".example.com (baseline wildcard)" ]]
}

@test "provenance: a project entry is distinguished from the baseline" {
  seed_baseline api.anthropic.com
  seed_project proj-aaa111 internal.aaa.test
  add 1000.0 TCP_TUNNEL/200 internal.aaa.test:443 proj-aaa111
  proc
  [[ "$output" == *$'\t'"internal.aaa.test (project exact)" ]]
}

@test "provenance: the browser identity gets its own lists and its own record" {
  seed_baseline api.anthropic.com
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf 'GET,HEAD fonts.gstatic.com\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/browser-domains.txt"
  add 1000.0 TCP_TUNNEL/200 fonts.gstatic.com:443 proj-aaa111-browser
  proc
  [[ "$output" == *$'\t'"fonts.gstatic.com (browser-baseline exact)" ]]
  run grep -F 'fonts.gstatic.com' "$(seen_file proj-aaa111-browser)"
  [ "$status" -eq 0 ]
}

@test "provenance: a method list in the entry never reaches the alert field" {
  # _flush joins hosts with commas, so "GET,HEAD host" in the alert would split
  # into two items. The alert gets the entry's HOST; the record gets it whole.
  seed_project proj-aaa111 'GET,HEAD scoped.aaa.test'
  add 1000.0 TCP_TUNNEL/200 scoped.aaa.test:443 proj-aaa111
  proc
  [[ "$output" == *$'\t'"scoped.aaa.test (project exact)" ]]
  [[ "$output" != *","* ]]
  run grep -F 'allowed by: GET,HEAD scoped.aaa.test (project exact)' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "provenance: an entry that has since expired reports nothing, not a guess" {
  # The watcher may replay a log days later. Naming a line that no longer grants
  # anything would be a wrong reason, which is worse than none.
  seed_baseline 'gone.test  # expires=100'
  add 1000.0 TCP_TUNNEL/200 gone.test:443 proj-aaa111
  proc
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"gone.test"$'\t'"new-host" ]]
  run grep -Fx 'gone.test' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "provenance: with no allowlist at all the output is exactly as before" {
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host" ]]
  run grep -Fx 'api.anthropic.com' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "provenance: a missing helper degrades to no reason, silently" {
  seed_baseline api.anthropic.com
  export CID_HELPER="${BATS_TEST_TMPDIR}/nope/ext-allowlist.sh"
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ "$status" -eq 0 ]
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host" ]]
}

@test "provenance: a helper answering garbage degrades to no reason" {
  seed_baseline api.anthropic.com
  export CID_HELPER="${BATS_TEST_TMPDIR}/junk.sh"
  printf '#!/bin/sh\necho hello\n' > "${CID_HELPER}"
  chmod +x "${CID_HELPER}"
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [[ "$output" == "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host" ]]
}

@test "provenance: a denial is never explained, even if the host is allowlisted" {
  # Contrived — the proxy would not deny an allowlisted host — but it pins that
  # the denial paths carry no 5th field for _emit to render.
  seed_baseline evil.test
  add 1000.0 TCP_DENIED/403 evil.test:443 proj-aaa111 NONE/-
  proc
  [[ "$output" == "alert"$'\t'"proj-aaa111"$'\t'"evil.test"$'\t'"new-host-denied" ]]
}

@test "provenance: a recorded host with a reason still dedupes on replay" {
  # The regression the comment-strip in loadseen exists for: without it the
  # trailing reason becomes part of the key and every host alerts forever.
  seed_baseline api.anthropic.com
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ -n "$output" ]
  LOG=''
  add 1001.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ -z "$output" ]
  [ "$(grep -c 'api.anthropic.com' "$(seen_file proj-aaa111)")" -eq 1 ]
}

@test "provenance: a host recorded bare by an older watcher still dedupes" {
  mkdir -p "${CLAUDE_PROJECTS_DIR}/proj-aaa111"
  printf '# Hosts this project has contacted, recorded by proxy/watch.sh.\napi.anthropic.com\n' \
    > "$(seen_file proj-aaa111)"
  seed_baseline api.anthropic.com
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ -z "$output" ]
}

@test "provenance: the notification says what allowed the host" {
  pipe_notify "info"$'\t'"proj-aaa111"$'\t'"cdn.x.test"$'\t'"new-host"$'\t'".x.test (baseline wildcard)"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"New egress host: proj-aaa111"* ]]
  [[ "$output" == *"cdn.x.test via .x.test (baseline wildcard)"* ]]
  [[ "$output" == *"Review: cid hosts"* ]]
}

@test "provenance: a burst stays one notification, each host with its own reason" {
  # Provenance must not enter the grouping key, or a first session's dozen hosts
  # would become a dozen banners.
  pipe_notify "info"$'\t'"proj-aaa111"$'\t'"a.x.test"$'\t'"new-host"$'\t'".x.test (baseline wildcard)"$'\n'"info"$'\t'"proj-aaa111"$'\t'"b.y.test"$'\t'"new-host"$'\t'"b.y.test (project exact)"
  [ "$(grep -c . "${NOTIFY_LOG}")" -eq 1 ]
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"2 new egress hosts: proj-aaa111"* ]]
  [[ "$output" == *"a.x.test via .x.test (baseline wildcard)"* ]]
  [[ "$output" == *"b.y.test via b.y.test (project exact)"* ]]
}

@test "provenance: a notification without a reason reads exactly as before" {
  pipe_notify "info"$'\t'"proj-aaa111"$'\t'"cdn.x.test"$'\t'"new-host"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"cdn.x.test"* ]]
  [[ "$output" != *"via"* ]]
}

@test "provenance: end to end, classifier into notifier" {
  seed_baseline .example.com
  add 1000.0 TCP_TUNNEL/200 cdn-metrics-7f3a.example.com:443 proj-aaa111
  pipe_all "${LOG}"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"cdn-metrics-7f3a.example.com via .example.com (baseline wildcard)"* ]]
}

# ---------------------------------------------------------------------------
# Muting — a host the user has told the watcher to stop notifying about
#
# The answer to telemetry that cannot be turned off at the source and should
# stay denied. Nothing about the classification changes: the same line is still
# a denial, still recorded in seen-hosts.txt, only silent. Muting is asked of
# proxy/ext-allowlist.sh --muted, so the matching itself is covered in
# test/ext-allowlist.bats; what is pinned here is WHICH lines go quiet and what
# still gets written.
# ---------------------------------------------------------------------------

mute_baseline() {  # <entry>...
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf '%s\n' "$@" > "${CLAUDE_DOCKER_CONFIG_DIR}/muted-hosts.txt"
}

mute_project() {  # <project-key> <entry>...
  local key="$1"; shift
  mkdir -p "${CLAUDE_PROJECTS_DIR}/${key}"
  printf '%s\n' "$@" > "${CLAUDE_PROJECTS_DIR}/${key}/muted-hosts.txt"
}

denied_file() {  # <project-key>
  printf '%s' "${CLAUDE_PROJECTS_DIR}/$1/denied-hosts.txt"
}

@test "mute: a denial inside the tunnel goes quiet — the case this exists for" {
  # http-intake.logs.us5.datadoghq.com: the host is allowlisted, a path rule
  # refuses the POST, and nothing can turn the telemetry off at the source.
  mute_project proj-aaa111 http-intake.logs.us5.datadoghq.com
  add_req 1000.0 TCP_DENIED/403 POST \
    http://http-intake.logs.us5.datadoghq.com/api/v2/logs proj-aaa111 NONE/-
  proc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mute: a new allowed host goes quiet too" {
  mute_project proj-aaa111 telemetry.example.net
  add 1000.0 TCP_TUNNEL/200 telemetry.example.net:443 proj-aaa111
  proc
  [ -z "$output" ]
}

@test "mute: an upstream 403 goes quiet too" {
  mute_project proj-aaa111 api.example.com
  add_req 1000.0 TCP_MISS/403 GET http://api.example.com/v1 proj-aaa111
  proc
  [ -z "$output" ]
}

@test "mute: a repeated denial stays quiet past the cooldown" {
  # The cooldown is what makes a muted host cheap to keep muted: it is stamped
  # whether or not an alert follows, so the helper is asked once per window.
  mute_project proj-aaa111 noisy.aaa.test
  add 1000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  add 2000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  add 3000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  proc
  [ -z "$output" ]
}

@test "mute: the host is still recorded as contacted" {
  # Muting silences the alert; it does not edit the history. `cid hosts` must
  # still show what the project reached.
  mute_project proj-aaa111 noisy.aaa.test
  add 1000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  proc
  run grep -Fx 'noisy.aaa.test' "$(seen_file proj-aaa111)"
  [ "$status" -eq 0 ]
}

@test "mute: a muted denial is kept out of denied-hosts.txt" {
  # That file is what `cid domains add --denied` reads. Muting a host is the
  # statement that it should NOT be allowed, so offering it there would be wrong.
  mute_project proj-aaa111 noisy.aaa.test
  add 1000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  add 1001.0 TCP_DENIED/403 other.aaa.test:443 proj-aaa111 NONE/-
  proc
  run cat "$(denied_file proj-aaa111)"
  [ "$output" = "other.aaa.test" ]
}

@test "mute: everything else still alerts" {
  mute_project proj-aaa111 noisy.aaa.test
  add 1000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  add 1001.0 TCP_DENIED/403 evil.test:443 proj-aaa111 NONE/-
  proc
  [ "$output" = "alert"$'\t'"proj-aaa111"$'\t'"evil.test"$'\t'"new-host-denied" ]
}

@test "mute: a baseline entry mutes every project, a wildcard its subdomains" {
  mute_baseline .datadoghq.com
  add 1000.0 TCP_DENIED/403 http-intake.logs.us5.datadoghq.com:443 proj-aaa111 NONE/-
  add 1001.0 TCP_DENIED/403 http-intake.logs.us5.datadoghq.com:443 proj-bbb222 NONE/-
  proc
  [ -z "$output" ]
}

@test "mute: another project is not muted by this one's list" {
  mute_project proj-aaa111 noisy.test
  add 1000.0 TCP_DENIED/403 noisy.test:443 proj-bbb222 NONE/-
  proc
  [[ "$output" == "alert"$'\t'"proj-bbb222"$'\t'"noisy.test"$'\t'"new-host-denied" ]]
}

@test "mute: an empty or absent list changes nothing" {
  # The property that makes this additive: with no mute list, byte-identical
  # output to a watcher without the feature.
  mute_baseline '# nothing muted'
  add 1000.0 TCP_TUNNEL/200 api.anthropic.com:443 proj-aaa111
  proc
  [ "$output" = "info"$'\t'"proj-aaa111"$'\t'"api.anthropic.com"$'\t'"new-host" ]
}

@test "mute: a broken helper alerts rather than silently muting" {
  # Fail toward the alert. A missing or wrong helper must never be able to
  # silence the watcher.
  mute_project proj-aaa111 noisy.aaa.test
  export CID_HELPER="${BATS_TEST_TMPDIR}/nope/ext-allowlist.sh"
  add 1000.0 TCP_DENIED/403 noisy.aaa.test:443 proj-aaa111 NONE/-
  proc
  [ "$output" = "alert"$'\t'"proj-aaa111"$'\t'"noisy.aaa.test"$'\t'"new-host-denied" ]
}

@test "mute: an alert names the command that silences it" {
  pipe_notify "alert"$'\t'"proj-aaa111"$'\t'"noisy.test"$'\t'"denied"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"cid mute add noisy.test"* ]]
}

@test "mute: a rule denial offers muting alongside the review command" {
  pipe_notify "alert"$'\t'"proj-aaa111"$'\t'"noisy.test"$'\t'"denied-by-rule"
  run cat "${NOTIFY_LOG}"
  [[ "$output" == *"cid domains"* ]]
  [[ "$output" == *"cid mute add noisy.test"* ]]
}

@test "mute: a multi-host burst suggests no single host to mute" {
  # The hint names a host only when there is exactly one — otherwise it would be
  # a command that mutes the wrong thing.
  pipe_notify "alert"$'\t'"proj-aaa111"$'\t'"a.test"$'\t'"denied"$'\n'"alert"$'\t'"proj-aaa111"$'\t'"b.test"$'\t'"denied"
  run cat "${NOTIFY_LOG}"
  [[ "$output" != *"cid mute add"* ]]
}
