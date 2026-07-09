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
}

# Feed the helper one Squid-format request line and capture status/output.
# Squid sends three whitespace tokens: "<project-key> <host> -" (it appends a
# trailing "-" placeholder), so every line here mirrors that exactly.
ask() {  # <project-key> <host>
  # Run under /bin/sh (not bash): the helper ships as POSIX sh and Squid execs
  # it with whatever /bin/sh the base image provides. This guards the shebang
  # contract — a stray bashism would fail here.
  run sh "${HELPER}" <<< "$1 $2 -"
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
  run sh "${HELPER}" <<< "proj-aaa111 api.anthropic.com:443 -"
  [ "$output" = "OK" ]
}

@test "trailing dot (FQDN root) is tolerated" {
  ask proj-aaa111 api.anthropic.com.
  [ "$output" = "OK" ]
}

# ---------------------------------------------------------------------------
# Malformed / hostile input — must fail closed (no traversal, no allow)
# ---------------------------------------------------------------------------

@test "empty host is denied" {
  run sh "${HELPER}" <<< "proj-aaa111  -"
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
proj-aaa111 api.anthropic.com -
proj-aaa111 evil.test -
proj-aaa111 internal.aaa.test -
EOF
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "OK" ]
  [ "${lines[1]}" = "ERR" ]
  [ "${lines[2]}" = "OK" ]
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
