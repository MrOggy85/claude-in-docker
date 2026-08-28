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
