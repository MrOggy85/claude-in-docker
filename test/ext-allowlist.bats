#!/usr/bin/env bats
#
# Unit tests for proxy/ext-allowlist.sh — the Squid external_acl helper that
# decides, per project, whether a host may be reached. This is the security
# decision point, so the suite covers exact/wildcard matching, project
# isolation, the suffix-boundary traps, and the quirks of Squid's wire format.
#
# Run with: bats test/ext-allowlist.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
HELPER="${SCRIPT_DIR}/proxy/ext-allowlist.sh"

# Build allowlist fixtures in this test's private temp dir (auto-removed by
# bats), and point the helper at them via the BASELINE / PROJECTS_DIR overrides.
# BATS_TEST_TMPDIR is unique per test, so tests never share state.
setup() {
  export BASELINE="${BATS_TEST_TMPDIR}/baseline-domains.txt"
  export SKIP_DECRYPTION_BASELINE="${BATS_TEST_TMPDIR}/baseline-skip-decryption.txt"
  export PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"

  cat > "${BASELINE}" <<'EOF'
# Baseline — always allowed for every project
api.anthropic.com
statsig.com

# A wildcard covering the apex and any subdomain
.example.com
EOF

  mkdir -p "${PROJECTS_DIR}/proj-aaa111" "${PROJECTS_DIR}/proj-bbb222"
  cat > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt" <<'EOF'
# proj-aaa111's own extras
internal.aaa.test
.cdn.aaa.test
EOF
  cat > "${PROJECTS_DIR}/proj-bbb222/allowed-domains.txt" <<'EOF'
internal.bbb.test
EOF

  # skip-decryption lists (--skip-decryption mode): hosts the proxy must NOT decrypt.
  # Deliberately
  # disjoint from the allowlists above, so a mode reading the wrong file shows up.
  cat > "${SKIP_DECRYPTION_BASELINE}" <<'EOF'
# Baseline — never decrypted, for every project
pinned.example.org
.pinnedwild.example.org
EOF
  cat > "${PROJECTS_DIR}/proj-aaa111/skip-decryption.txt" <<'EOF'
pinned.aaa.test
EOF

  # Mute lists (--muted mode): hosts the alert watcher must not notify about.
  # Disjoint from every list above, so a mode reading the wrong file shows up —
  # and deliberately NOT in the allowlists, since muting must not allow anything.
  export MUTED_BASELINE="${BATS_TEST_TMPDIR}/baseline-muted-hosts.txt"
  cat > "${MUTED_BASELINE}" <<'XEOFX'
# Baseline — never alerted about, for every project
noisy.example.net
.telemetry.example.net
XEOFX
  cat > "${PROJECTS_DIR}/proj-aaa111/muted-hosts.txt" <<'XEOFX'
muted.aaa.test
XEOFX

  # The in-container browser's extra lists, reached only by a "-browser" login.
  # Disjoint from everything above, so a leak in either direction is visible.
  export BROWSER_BASELINE="${BATS_TEST_TMPDIR}/baseline-browser-domains.txt"
  cat > "${BROWSER_BASELINE}" <<'EOF'
# Browser baseline — every project's browser, no project's agent
GET,HEAD fonts.gstatic.com
EOF
  cat > "${PROJECTS_DIR}/proj-aaa111/browser-domains.txt" <<'EOF'
GET,HEAD cdn.aaa-browser.test
unrestricted.aaa-browser.test
EOF
}

# Feed the helper one Squid-format request line and capture status/output.
# Squid sends "%LOGIN %METHOD %DST %PATH" plus a trailing "-" placeholder, so
# every line here mirrors that exactly. ask() asks the question a CONNECT asks
# ("may this project open a tunnel to this host?"); ask_req() asks it of a
# decrypted inner request, which is where a method/path rule bites.
ask() {  # <project-key> <host>
  # Run under /bin/sh (not bash): the helper ships as POSIX sh and Squid execs
  # it with whatever /bin/sh the base image provides. This guards the shebang
  # contract — a stray bashism would fail here.
  run sh "${HELPER}" <<< "$1 CONNECT $2 - -"
}

ask_req() {  # <project-key> <method> <host> <path>
  run sh "${HELPER}" <<< "$1 $2 $3 $4 -"
}

# Same, in --skip-decryption mode: "should this host be tunnelled without decryption?"
# Only ever asked of a CONNECT — there is no inner request to ask it of.
ask_skip_decryption() {  # <project-key> <host>
  run sh "${HELPER}" --skip-decryption <<< "$1 CONNECT $2 - -"
}

# Same, in --explain mode: "which entry covers this host, from which list?".
# Host-level, so always asked as a CONNECT. Answers with four tab-separated
# fields; exp() spells the expectation so the tabs stay visible in the diff.
ask_explain() {  # <project-key> <host>
  run sh "${HELPER}" --explain <<< "$1 CONNECT $2 - -"
}

exp() {  # <source> <kind> <entry-host> <entry>
  printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
}

# Same, in --muted mode: "has the user told the watcher to stay quiet about this
# host?". Host-level like --explain, and answers in the same four fields, led by
# a positive verdict token.
ask_muted() {  # <project-key> <host>
  run sh "${HELPER}" --muted <<< "$1 CONNECT $2 - -"
}

mexp() {  # <source> <kind> <entry>
  printf 'muted\t%s\t%s\t%s' "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Baseline matching (applies to every project)
# ---------------------------------------------------------------------------

@test "baseline: exact host is allowed" {
  ask proj-aaa111 api.anthropic.com
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "baseline: applies regardless of project key" {
  ask proj-bbb222 statsig.com
  [ "$output" = "OK" ]
}

@test "baseline: host not in any list is denied" {
  ask proj-aaa111 evil.example.org
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# Per-project lists + isolation between projects
# ---------------------------------------------------------------------------

@test "project: own list entry is allowed" {
  ask proj-aaa111 internal.aaa.test
  [ "$output" = "OK" ]
}

@test "project isolation: A cannot reach B's host" {
  ask proj-aaa111 internal.bbb.test
  [ "$output" = "ERR" ]
}

@test "project isolation: B cannot reach A's host" {
  ask proj-bbb222 internal.aaa.test
  [ "$output" = "ERR" ]
}

@test "unknown project key: only the baseline applies" {
  ask proj-zzz999 api.anthropic.com
  [ "$output" = "OK" ]
}

@test "unknown project key: non-baseline host is denied" {
  ask proj-zzz999 internal.aaa.test
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# Wildcard (.apex) matching
# ---------------------------------------------------------------------------

@test "wildcard: matches a subdomain" {
  ask proj-bbb222 www.example.com
  [ "$output" = "OK" ]
}

@test "wildcard: matches a deep subdomain" {
  ask proj-bbb222 a.b.c.example.com
  [ "$output" = "OK" ]
}

@test "wildcard: matches the bare apex" {
  ask proj-bbb222 example.com
  [ "$output" = "OK" ]
}

@test "wildcard works in a project list too" {
  ask proj-aaa111 img.cdn.aaa.test
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Suffix-boundary traps — the security-critical cases the wildcard MUST reject
# ---------------------------------------------------------------------------

@test "wildcard does NOT match a look-alike apex (notexample.com)" {
  ask proj-bbb222 notexample.com
  [ "$output" = "ERR" ]
}

@test "wildcard does NOT match an attacker suffix (example.com.evil.com)" {
  ask proj-bbb222 example.com.evil.com
  [ "$output" = "ERR" ]
}

@test "exact entry does NOT match a subdomain of itself" {
  # api.anthropic.com is an EXACT baseline entry, not a wildcard.
  ask proj-aaa111 evil.api.anthropic.com
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# Squid wire-format quirks: trailing "-" field, :port, trailing dot
# ---------------------------------------------------------------------------

@test "trailing '-' placeholder does not leak into the host" {
  # Regression test for the original bug: parsing "the rest of the line" as the
  # host captured the trailing "-" and never matched.
  ask proj-aaa111 api.anthropic.com
  [ "$output" = "OK" ]
}

@test "host with :port is matched on the host portion" {
  run sh "${HELPER}" <<< "proj-aaa111 CONNECT api.anthropic.com:443 - -"
  [ "$output" = "OK" ]
}

@test "trailing dot (FQDN root) is tolerated" {
  ask proj-aaa111 api.anthropic.com.
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Malformed / hostile input — must fail closed (no traversal, no allow)
# ---------------------------------------------------------------------------

@test "empty host ('-', Squid's placeholder for an unset value) is denied" {
  run sh "${HELPER}" <<< "proj-aaa111 CONNECT - - -"
  [ "$output" = "ERR" ]
}

@test "path-traversal key cannot escape the projects dir (still gets baseline)" {
  ask "../../etc" api.anthropic.com
  [ "$output" = "OK" ]
}

@test "path-traversal key cannot reach a project's list" {
  ask "../proj-aaa111" internal.aaa.test
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# Batch behaviour: Squid reuses one long-lived process for many requests
# ---------------------------------------------------------------------------

@test "multiple request lines yield verdicts in order" {
  run sh "${HELPER}" <<EOF
proj-aaa111 CONNECT api.anthropic.com - -
proj-aaa111 CONNECT evil.test - -
proj-aaa111 CONNECT internal.aaa.test - -
EOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "OK" ]
  [ "${lines[1]}" = "ERR" ]
  [ "${lines[2]}" = "OK" ]
}

# ---------------------------------------------------------------------------
# Temporary entries ("# expires=<epoch>", written by `cid domains add --for`)
# ---------------------------------------------------------------------------

@test "temp entry: not yet expired is allowed" {
  local future=$(( $(date +%s) + 3600 ))
  printf 'temp.aaa.test  # expires=%s\n' "${future}" >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask proj-aaa111 temp.aaa.test
  [ "$output" = "OK" ]
}

@test "temp entry: expired in the past is denied" {
  printf 'temp.aaa.test  # expires=1\n' >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask proj-aaa111 temp.aaa.test
  [ "$output" = "ERR" ]
}

@test "temp entry: expiry does not leak to other projects" {
  local future=$(( $(date +%s) + 3600 ))
  printf 'temp.aaa.test  # expires=%s\n' "${future}" >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask proj-bbb222 temp.aaa.test
  [ "$output" = "ERR" ]
}

@test "temp entry: malformed expires= value fails closed (denied)" {
  printf 'temp.aaa.test  # expires=notanumber\n' >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask proj-aaa111 temp.aaa.test
  [ "$output" = "ERR" ]
}

@test "temp entry: wildcard with a future expiry still matches subdomains" {
  local future=$(( $(date +%s) + 3600 ))
  printf '.temp.aaa.test  # expires=%s\n' "${future}" >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask proj-aaa111 sub.temp.aaa.test
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Missing baseline file must not crash or fail open
# ---------------------------------------------------------------------------

@test "missing baseline file: project list still works, others denied" {
  rm -f "${BASELINE}"
  ask proj-aaa111 internal.aaa.test
  [ "$output" = "OK" ]
}

@test "missing baseline file: baseline-only host is denied (no crash)" {
  rm -f "${BASELINE}"
  ask proj-aaa111 api.anthropic.com
  [ "$status" -eq 0 ]
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# --skip-decryption mode: the same grammar answering "do NOT decrypt this host"
# ---------------------------------------------------------------------------

@test "skip-decryption: baseline entry matches" {
  ask_skip_decryption proj-aaa111 pinned.example.org
  [ "$output" = "OK" ]
}

@test "skip-decryption: wildcard entry matches a subdomain" {
  ask_skip_decryption proj-bbb222 api.pinnedwild.example.org
  [ "$output" = "OK" ]
}

@test "skip-decryption: project entry matches only in that project" {
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "OK" ]
  ask_skip_decryption proj-bbb222 pinned.aaa.test
  [ "$output" = "ERR" ]
}

@test "skip-decryption: an unlisted host is decrypted (bumped)" {
  ask_skip_decryption proj-aaa111 api.anthropic.com
  [ "$output" = "ERR" ]
}

@test "skip-decryption mode does not read the egress allowlist (and vice versa)" {
  # internal.aaa.test is allowed but decrypted; pinned.aaa.test the reverse.
  ask_skip_decryption proj-aaa111 internal.aaa.test
  [ "$output" = "ERR" ]
  ask proj-aaa111 pinned.aaa.test
  [ "$output" = "ERR" ]
}

@test "skip-decryption: missing lists mean everything is decrypted" {
  rm -f "${SKIP_DECRYPTION_BASELINE}" "${PROJECTS_DIR}/proj-aaa111/skip-decryption.txt"
  ask_skip_decryption proj-aaa111 pinned.example.org
  [ "$status" -eq 0 ]
  [ "$output" = "ERR" ]
}

@test "skip-decryption: expiry annotations work here too (same grammar)" {
  local past=$(( $(date +%s) - 60 ))
  printf 'temp.pinned.test  # expires=%s\n' "${past}" >> "${SKIP_DECRYPTION_BASELINE}"
  ask_skip_decryption proj-aaa111 temp.pinned.test
  [ "$output" = "ERR" ]
}

@test "unknown mode argument is refused instead of guessed" {
  run sh "${HELPER}" --bogus <<< "proj-aaa111 CONNECT api.anthropic.com - -"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown mode"* ]]
}

# ---------------------------------------------------------------------------
# Method / path rules — the axes an entry may narrow beyond the hostname.
#
# The CONNECT only names a host, so it is always host-level; the rule bites on
# the decrypted inner request. Every test below therefore checks BOTH: the
# tunnel opens, and the request inside it is judged on its own.
# ---------------------------------------------------------------------------

setup_scoped() {
  cat > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt" <<'EOF'
api.aaa.test/repos
GET,HEAD readonly.aaa.test
GET mixed.aaa.test/v1
prefix.aaa.test/repos*
root.aaa.test/
plain.aaa.test
EOF
}

@test "unscoped entry still grants every method and path (backward compatible)" {
  ask_req proj-aaa111 POST api.anthropic.com /v1/messages
  [ "$output" = "OK" ]
}

@test "path rule: the CONNECT is allowed on the host alone" {
  setup_scoped
  ask proj-aaa111 api.aaa.test
  [ "$output" = "OK" ]
}

@test "path rule: the entry's own path matches" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /repos
  [ "$output" = "OK" ]
}

@test "path rule: anything below the entry matches" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /repos/octocat/hello
  [ "$output" = "OK" ]
}

@test "path rule: any method matches when the entry names none" {
  setup_scoped
  ask_req proj-aaa111 DELETE api.aaa.test /repos/x
  [ "$output" = "OK" ]
}

@test "path rule: a sibling path on the same host is denied" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /admin
  [ "$output" = "ERR" ]
}

@test "path rule: the query string is ignored, not matched" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test '/repos?per_page=100'
  [ "$output" = "OK" ]
}

@test "path rule: trailing slash in the entry is equivalent" {
  cat > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt" <<'EOF'
api.aaa.test/repos/
EOF
  ask_req proj-aaa111 GET api.aaa.test /repos/x
  [ "$output" = "OK" ]
  ask_req proj-aaa111 GET api.aaa.test /repos
  [ "$output" = "OK" ]
}

@test "path rule: 'host/' grants every path on that host" {
  setup_scoped
  ask_req proj-aaa111 GET root.aaa.test /anything/at/all
  [ "$output" = "OK" ]
}

# --- the segment-boundary traps: the path analogue of the .apex label boundary

@test "path boundary: /repos does NOT match /repository" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /repository
  [ "$output" = "ERR" ]
}

@test "path boundary: /repos does NOT match /reposx/y" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /reposx/y
  [ "$output" = "ERR" ]
}

@test "path boundary: a trailing '*' opts into a raw prefix" {
  setup_scoped
  ask_req proj-aaa111 GET prefix.aaa.test /repository
  [ "$output" = "OK" ]
}

@test "path boundary: a double slash does not match (fails closed)" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test //repos/x
  [ "$output" = "ERR" ]
}

# --- traversal, encoded and plain: must never reach past the rule

@test "traversal: a literal '..' segment is denied" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test /repos/../admin
  [ "$output" = "ERR" ]
}

@test "traversal: a percent-encoded '..' segment is denied" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test '/repos/%2e%2e/admin'
  [ "$output" = "ERR" ]
}

@test "traversal: an encoded slash cannot forge a segment boundary" {
  # "/reposx%2f.." decodes to "/reposx/..", which is neither under /repos nor safe.
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test '/reposx%2f../admin'
  [ "$output" = "ERR" ]
}

@test "traversal: a backslash is denied" {
  setup_scoped
  ask_req proj-aaa111 GET api.aaa.test '/repos/..\admin'
  [ "$output" = "ERR" ]
}

@test "traversal: a path rule never matches an unusable path" {
  # Not rooted at '/' — no origin path looks like this, so it matches nothing.
  setup_scoped
  ask_req proj-aaa111 GET root.aaa.test 'repos'
  [ "$output" = "ERR" ]
}

@test "traversal: an unscoped entry is unaffected by all of the above" {
  setup_scoped
  ask_req proj-aaa111 GET plain.aaa.test /repos/../admin
  [ "$output" = "OK" ]
}

# --- method rules

@test "method rule: a listed method is allowed" {
  setup_scoped
  ask_req proj-aaa111 GET readonly.aaa.test /anything
  [ "$output" = "OK" ]
  ask_req proj-aaa111 HEAD readonly.aaa.test /anything
  [ "$output" = "OK" ]
}

@test "method rule: an unlisted method is denied" {
  setup_scoped
  ask_req proj-aaa111 POST readonly.aaa.test /anything
  [ "$output" = "ERR" ]
}

@test "method rule: the CONNECT is not judged by it" {
  setup_scoped
  ask proj-aaa111 readonly.aaa.test
  [ "$output" = "OK" ]
}

@test "method rule: matching is case-insensitive on both sides" {
  printf 'get lower.aaa.test\n' >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_req proj-aaa111 get lower.aaa.test /x
  [ "$output" = "OK" ]
}

@test "method + path: both must match" {
  setup_scoped
  ask_req proj-aaa111 GET mixed.aaa.test /v1/thing
  [ "$output" = "OK" ]
  ask_req proj-aaa111 POST mixed.aaa.test /v1/thing
  [ "$output" = "ERR" ]
  ask_req proj-aaa111 GET mixed.aaa.test /v2/thing
  [ "$output" = "ERR" ]
}

@test "scoped entries union: a broader entry on the same host wins" {
  setup_scoped
  printf 'api.aaa.test\n' >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_req proj-aaa111 POST api.aaa.test /admin
  [ "$output" = "OK" ]
}

@test "scoped entries: a wildcard host may carry a path rule" {
  printf '.cdn.aaa.test/assets\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_req proj-aaa111 GET img.cdn.aaa.test /assets/logo.png
  [ "$output" = "OK" ]
  ask_req proj-aaa111 GET img.cdn.aaa.test /secrets
  [ "$output" = "ERR" ]
}

@test "scoped entries: expiry annotations work here too" {
  local past=$(( $(date +%s) - 60 ))
  printf 'GET temp.aaa.test/v1  # expires=%s\n' "${past}" > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_req proj-aaa111 GET temp.aaa.test /v1
  [ "$output" = "ERR" ]
}

@test "malformed entry with a third field is skipped, not guessed" {
  printf 'GET junk.aaa.test /v1 extra\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_req proj-aaa111 GET junk.aaa.test /v1
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# Splicing vs. scoped entries: a spliced tunnel has no inner request, so the
# helper refuses to splice a host that is ONLY reachable through a method/path
# rule — otherwise the rule would silently degrade to host-level.
# ---------------------------------------------------------------------------

@test "splice: refused when the host is granted only by a path rule" {
  printf 'pinned.aaa.test/v1\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "ERR" ]
}

@test "splice: refused when the host is granted only by a method rule" {
  printf 'GET pinned.aaa.test\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "ERR" ]
}

@test "splice: still allowed when a plain entry grants the host as well" {
  printf 'pinned.aaa.test/v1\npinned.aaa.test\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "OK" ]
}

@test "splice: still allowed for a host the allowlist does not mention" {
  # Its CONNECT is denied by http_access anyway, so nothing changes here.
  printf '' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "OK" ]
}

@test "splice: a scoped entry in ANOTHER project does not force decryption" {
  printf 'pinned.aaa.test/v1\n' > "${PROJECTS_DIR}/proj-bbb222/allowed-domains.txt"
  printf 'pinned.aaa.test\n' > "${PROJECTS_DIR}/proj-aaa111/skip-decryption.txt"
  printf 'pinned.aaa.test\n' > "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_skip_decryption proj-aaa111 pinned.aaa.test
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# The browser identity: "<key>-browser" gets two extra lists, additively.
# This is the whole point of the split, so both directions are asserted.
# ---------------------------------------------------------------------------

@test "browser: reaches a host only its own project list grants" {
  ask proj-aaa111-browser cdn.aaa-browser.test
  [ "$output" = "OK" ]
}

@test "browser: the AGENT cannot reach that host — the split is one-way" {
  ask proj-aaa111 cdn.aaa-browser.test
  [ "$output" = "ERR" ]
}

@test "browser: reaches the browser baseline" {
  ask proj-aaa111-browser fonts.gstatic.com
  [ "$output" = "OK" ]
}

@test "browser: the agent cannot reach the browser baseline" {
  ask proj-aaa111 fonts.gstatic.com
  [ "$output" = "ERR" ]
}

@test "browser: additive — still gets everything the agent gets" {
  ask proj-aaa111-browser api.anthropic.com      # shared baseline
  [ "$output" = "OK" ]
  ask proj-aaa111-browser internal.aaa.test      # the project's own list
  [ "$output" = "OK" ]
}

@test "browser: another project's browser list does not leak" {
  ask proj-bbb222-browser cdn.aaa-browser.test
  [ "$output" = "ERR" ]
}

@test "browser: a method rule on a browser entry is enforced" {
  ask_req proj-aaa111-browser GET cdn.aaa-browser.test /x.js
  [ "$output" = "OK" ]
  ask_req proj-aaa111-browser POST cdn.aaa-browser.test /x.js
  [ "$output" = "ERR" ]
}

@test "browser: an unlisted host is still denied" {
  ask proj-aaa111-browser evil.example.org
  [ "$output" = "ERR" ]
}

@test "browser: a missing browser list is not an error, just no extras" {
  rm -f "${PROJECTS_DIR}/proj-aaa111/browser-domains.txt"
  ask proj-aaa111-browser cdn.aaa-browser.test
  [ "$output" = "ERR" ]
  ask proj-aaa111-browser api.anthropic.com
  [ "$output" = "OK" ]
}

@test "browser: the suffix is stripped before the key guard, not after" {
  # A traversal in the stripped key must still be refused, not resolved.
  ask ../../etc-browser api.anthropic.com
  [ "$output" = "OK" ]     # baseline only
  ask ../../etc-browser cdn.aaa-browser.test
  [ "$output" = "ERR" ]
}

@test "browser: splice decision sees the browser lists too" {
  # unrestricted.aaa-browser.test is granted with no method/path rule, so
  # splicing it cannot silently degrade a rule. It must stay spliceable.
  printf 'unrestricted.aaa-browser.test\n' > "${PROJECTS_DIR}/proj-aaa111/skip-decryption.txt"
  ask_skip_decryption proj-aaa111-browser unrestricted.aaa-browser.test
  [ "$output" = "OK" ]
}

@test "browser: splice is refused when only a scoped browser entry grants the host" {
  # cdn.aaa-browser.test is GET,HEAD-only. Splicing hides the inner request, so
  # the method rule would degrade to host-level — refuse, as for the agent.
  printf 'cdn.aaa-browser.test\n' > "${PROJECTS_DIR}/proj-aaa111/skip-decryption.txt"
  ask_skip_decryption proj-aaa111-browser cdn.aaa-browser.test
  [ "$output" = "ERR" ]
}

# ---------------------------------------------------------------------------
# --explain — WHICH entry covers a host, for the first-time-host alert
#
# Not a decision: proxy/watch.sh calls this on the host to say why a new host was
# allowed. It reuses match_in_file, so the matching itself is already covered
# above; what needs pinning here is the reporting — the source label, the
# exact/wildcard split, the two halves of the entry, and that "no idea" is
# reported as such rather than guessed. The OK/ERR modes are asserted unchanged
# throughout the rest of this file; nothing here should be able to move them.
# ---------------------------------------------------------------------------

@test "explain: a baseline exact entry names itself" {
  ask_explain proj-aaa111 api.anthropic.com
  [ "$status" -eq 0 ]
  [ "$output" = "$(exp baseline exact api.anthropic.com api.anthropic.com)" ]
}

@test "explain: a subdomain reached through a wildcard says wildcard" {
  # The case the whole feature exists for: nobody approved THIS host.
  ask_explain proj-aaa111 cdn-metrics-7f3a.example.com
  [ "$output" = "$(exp baseline wildcard .example.com .example.com)" ]
}

@test "explain: the apex of a wildcard still reads as wildcard" {
  # .example.com covers the apex too (host_matches), so example.com is reported
  # wildcard even though that exact host is spelled in the file. Two piles, not
  # three — documented in docs/egress-alerts.md rather than special-cased.
  ask_explain proj-aaa111 example.com
  [ "$output" = "$(exp baseline wildcard .example.com .example.com)" ]
}

@test "explain: a project entry is labelled project, not baseline" {
  ask_explain proj-aaa111 internal.aaa.test
  [ "$output" = "$(exp project exact internal.aaa.test internal.aaa.test)" ]
}

@test "explain: a project wildcard is labelled on both axes" {
  ask_explain proj-aaa111 img.cdn.aaa.test
  [ "$output" = "$(exp project wildcard .cdn.aaa.test .cdn.aaa.test)" ]
}

@test "explain: another project's entry explains nothing" {
  ask_explain proj-bbb222 internal.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: an unlisted host explains nothing" {
  ask_explain proj-aaa111 nope.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: the baseline wins when both lists cover the host" {
  # Pins the file order to the real decision's four-way OR. Reporting the
  # project entry here would understate the reach: the baseline grants it to
  # EVERY project.
  printf 'api.anthropic.com\n' >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_explain proj-aaa111 api.anthropic.com
  [ "$output" = "$(exp baseline exact api.anthropic.com api.anthropic.com)" ]
}

@test "explain: a scoped entry reports the bare host and the whole entry" {
  # Field 3 is what an alert shows (comma-free, so it survives the watcher's
  # CSV); field 4 is what seen-hosts.txt records.
  setup_scoped
  ask_explain proj-aaa111 readonly.aaa.test
  [ "$output" = "$(exp project exact readonly.aaa.test "GET,HEAD readonly.aaa.test")" ]
}

@test "explain: a path rule is carried whole into the entry field" {
  setup_scoped
  ask_explain proj-aaa111 api.aaa.test
  [ "$output" = "$(exp project exact api.aaa.test api.aaa.test/repos)" ]
}

@test "explain: an unexpired entry explains, without its annotation" {
  printf 'temp.aaa.test  # expires=%s\n' "$(( $(date +%s) + 3600 ))" \
    >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_explain proj-aaa111 temp.aaa.test
  [ "$output" = "$(exp project exact temp.aaa.test temp.aaa.test)" ]
}

@test "explain: an expired entry explains nothing" {
  # The TOCTOU case: the watcher may ask long after the request. Saying nothing
  # beats naming a line that no longer grants anything.
  printf 'temp.aaa.test  # expires=100\n' \
    >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_explain proj-aaa111 temp.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: a malformed expiry fails closed here too" {
  printf 'temp.aaa.test  # expires=soon\n' \
    >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_explain proj-aaa111 temp.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: an expired line does not shadow a valid one below it" {
  printf 'temp.aaa.test  # expires=100\ntemp.aaa.test\n' \
    >> "${PROJECTS_DIR}/proj-aaa111/allowed-domains.txt"
  ask_explain proj-aaa111 temp.aaa.test
  [ "$output" = "$(exp project exact temp.aaa.test temp.aaa.test)" ]
}

@test "explain: the browser baseline is labelled as its own source" {
  ask_explain proj-aaa111-browser fonts.gstatic.com
  [ "$output" = "$(exp browser-baseline exact fonts.gstatic.com "GET,HEAD fonts.gstatic.com")" ]
}

@test "explain: the browser project list is labelled as its own source" {
  ask_explain proj-aaa111-browser unrestricted.aaa-browser.test
  [ "$output" = \
    "$(exp browser-project exact unrestricted.aaa-browser.test unrestricted.aaa-browser.test)" ]
}

@test "explain: the agent is told nothing about the browser's lists" {
  # Mirrors the one-way split the allow mode enforces: the agent never reached
  # this host, so no entry explains it for the agent.
  ask_explain proj-aaa111 fonts.gstatic.com
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: a key the guard rejects still gets the baseline answer" {
  ask_explain ../../etc api.anthropic.com
  [ "$output" = "$(exp baseline exact api.anthropic.com api.anthropic.com)" ]
}

@test "explain: a key the guard rejects reaches no project list" {
  ask_explain ../../etc internal.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "explain: answers every line, in order" {
  run sh "${HELPER}" --explain <<EOF
proj-aaa111 CONNECT api.anthropic.com - -
proj-bbb222 CONNECT internal.aaa.test - -
proj-aaa111 CONNECT internal.aaa.test - -
EOF
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(exp baseline exact api.anthropic.com api.anthropic.com)" ]
  [ "${lines[1]}" = "$(exp none none - -)" ]
  [ "${lines[2]}" = "$(exp project exact internal.aaa.test internal.aaa.test)" ]
}

@test "explain: never answers OK, so a squid.conf typo naming it would deny" {
  ask_explain proj-aaa111 api.anthropic.com
  [[ "$output" != OK* ]]
}

# ---------------------------------------------------------------------------
# --muted — should the watcher stay quiet about this host?
#
# Not a decision either: proxy/watch.sh asks before it raises an alert, and a
# muted host is allowed or denied exactly as it was. The matching is match_in_file
# again, already covered above; what needs pinning here is that this reads its own
# file, that the verdict token is POSITIVE (so anything unexpected fails toward
# alerting), and that muting neither grants nor is granted by the allowlist.
# ---------------------------------------------------------------------------

@test "muted: a baseline entry mutes the host for every project" {
  ask_muted proj-bbb222 noisy.example.net
  [ "$status" -eq 0 ]
  [ "$output" = "$(mexp baseline exact noisy.example.net)" ]
}

@test "muted: a wildcard covers the subdomain the telemetry actually uses" {
  ask_muted proj-aaa111 http-intake.logs.telemetry.example.net
  [ "$output" = "$(mexp baseline wildcard .telemetry.example.net)" ]
}

@test "muted: a project entry mutes only that project" {
  ask_muted proj-aaa111 muted.aaa.test
  [ "$output" = "$(mexp project exact muted.aaa.test)" ]
  ask_muted proj-bbb222 muted.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "muted: an unlisted host is not muted" {
  ask_muted proj-aaa111 api.anthropic.com
  [ "$output" = "$(exp none none - -)" ]
}

@test "muted: the browser shares the project mute list" {
  # The "-browser" suffix is stripped before the project dir is resolved, so one
  # mute covers both identities. There is no browser mute list to widen.
  ask_muted proj-aaa111-browser muted.aaa.test
  [ "$output" = "$(mexp project exact muted.aaa.test)" ]
}

@test "muted: an expired entry stops muting" {
  printf 'temporarily.aaa.test  # expires=100\n' >> "${PROJECTS_DIR}/proj-aaa111/muted-hosts.txt"
  ask_muted proj-aaa111 temporarily.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "muted: with no baseline set at all, nothing is muted" {
  # Unset, the default is a path that does not exist: the failure mode is a
  # spurious alert, never a silent one.
  unset MUTED_BASELINE
  ask_muted proj-bbb222 noisy.example.net
  [ "$output" = "$(exp none none - -)" ]
}

@test "muted: muting a host does not allow it" {
  ask proj-bbb222 noisy.example.net
  [ "$output" = "ERR" ]
}

@test "muted: allowing a host does not mute it" {
  ask_muted proj-aaa111 internal.aaa.test
  [ "$output" = "$(exp none none - -)" ]
}

@test "muted: answers every line, in order" {
  run sh "${HELPER}" --muted <<XEOFX
proj-aaa111 CONNECT noisy.example.net - -
proj-bbb222 CONNECT muted.aaa.test - -
proj-aaa111 CONNECT muted.aaa.test - -
XEOFX
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(mexp baseline exact noisy.example.net)" ]
  [ "${lines[1]}" = "$(exp none none - -)" ]
  [ "${lines[2]}" = "$(mexp project exact muted.aaa.test)" ]
}

@test "muted: never answers OK, so a squid.conf typo naming it would deny" {
  ask_muted proj-aaa111 muted.aaa.test
  [[ "$output" != OK* ]]
}
