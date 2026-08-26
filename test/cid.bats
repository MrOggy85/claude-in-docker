#!/usr/bin/env bats
#
# Unit tests for the `cid` config CLI — specifically the `domains add|rm`
# allowlist editors (the only commands that mutate state). Reading commands
# (list/show/project) are exercised lightly for smoke coverage.
#
# The config dir and projects dir are redirected into this test's private temp
# dir via CLAUDE_DOCKER_CONFIG_DIR / CLAUDE_PROJECTS_DIR, so runs never touch the
# real config. BATS_TEST_TMPDIR is unique per test.
#
# Run with: bats test/cid.bats
# Install bats: https://bats-core.readthedocs.io/en/stable/installation.html

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
CID="${SCRIPT_DIR}/cid"

setup() {
  export CLAUDE_DOCKER_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  export CLAUDE_PROJECTS_DIR="${BATS_TEST_TMPDIR}/cfg/projects"
  mkdir -p "${CLAUDE_DOCKER_CONFIG_DIR}"
  printf '# baseline\napi.anthropic.com\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  # The skip-decryption list is the second proxy-mounted baseline (`make init` seeds
  # it comment-only, like this).
  printf '# hosts never decrypted\n' > "${CLAUDE_DOCKER_CONFIG_DIR}/skip-decryption.txt"

  # A stable project dir to target with -C. Its per-project list starts absent.
  PROJ="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "${PROJ}"
}

# Path to the (single) per-project allowlist file, whatever key it hashed to.
proj_file() { echo "${CLAUDE_PROJECTS_DIR}"/*/allowed-domains.txt; }

# ---------------------------------------------------------------------------
# domains add — per-project (default target)
# ---------------------------------------------------------------------------

@test "add: creates the per-project list and writes the host" {
  run "${CID}" domains add example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "example.com" ]
}

@test "add: multiple hosts on separate lines, wildcard allowed" {
  run "${CID}" domains add example.com .githubusercontent.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "${lines[0]}" = "example.com" ]
  [ "${lines[1]}" = ".githubusercontent.com" ]
}

@test "add: is idempotent and case-insensitive (no duplicate line)" {
  "${CID}" domains add example.com -C "${PROJ}"
  run "${CID}" domains add EXAMPLE.COM -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in"* ]]
  run grep -c '^example.com$' "$(proj_file)"
  [ "$output" -eq 1 ]
}

@test "add: lowercases the stored host" {
  "${CID}" domains add Example.Com -C "${PROJ}"
  run cat "$(proj_file)"
  [ "$output" = "example.com" ]
}

@test "add: rejects an invalid hostname and writes nothing" {
  # 'bad' is where a method list goes, and it is not a method — so the whole
  # entry is refused rather than stored as a rule that could never match.
  run "${CID}" domains add 'bad host/x' -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a valid allowlist entry"* ]]
  run bash -c "cat ${CLAUDE_PROJECTS_DIR}/*/allowed-domains.txt 2>/dev/null || true"
  [ -z "$output" ]
}

@test "add: no host argument is a usage error" {
  run "${CID}" domains add -C "${PROJ}"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# domains add -g — the shared baseline
# ---------------------------------------------------------------------------

@test "add -g: appends to the baseline list" {
  run "${CID}" domains add -g registry.npmjs.org
  [ "$status" -eq 0 ]
  run grep -c '^registry.npmjs.org$' "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [ "$output" -eq 1 ]
}

@test "add -g: fails when the baseline file is absent (points at make init)" {
  rm -f "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  run "${CID}" domains add -g foo.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"make init"* ]]
}

# ---------------------------------------------------------------------------
# domains rm
# ---------------------------------------------------------------------------

@test "rm: removes the entry, keeps other lines and comments" {
  printf '# hdr\nkeep.com\ndrop.com  # trailing\nalso-keep.com\n' \
    > "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  run "${CID}" domains rm -g drop.com
  [ "$status" -eq 0 ]
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [[ "$output" == *"# hdr"* ]]
  [[ "$output" == *"keep.com"* ]]
  [[ "$output" == *"also-keep.com"* ]]
  [[ "$output" != *"drop.com"* ]]
}

@test "rm: a host not present is reported and is a no-op" {
  cp "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt" "${BATS_TEST_TMPDIR}/before"
  run "${CID}" domains rm -g nope.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in baseline"* ]]
  run diff "${BATS_TEST_TMPDIR}/before" "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [ "$status" -eq 0 ]
}

@test "rm: absent per-project list is a graceful no-op" {
  run "${CID}" domains rm example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

# ---------------------------------------------------------------------------
# domains add/rm with a path and/or a method — the narrower-than-a-host rules.
# What each entry then MEANS is proxy/ext-allowlist.sh's job and is covered in
# test/ext-allowlist.bats; here we only check what lands in the file.
# ---------------------------------------------------------------------------

@test "add: a path is stored on the host, verbatim" {
  run "${CID}" domains add api.github.com/repos -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "api.github.com/repos" ]
}

@test "add: the host is lowercased but the path keeps its case" {
  "${CID}" domains add API.GitHub.com/Repos/MyOrg -C "${PROJ}"
  run cat "$(proj_file)"
  [ "$output" = "api.github.com/Repos/MyOrg" ]
}

@test "add: a trailing '*' raw-prefix path is accepted" {
  run "${CID}" domains add 'api.github.com/repos*' -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = 'api.github.com/repos*' ]
}

@test "add: a wildcard host may carry a path" {
  run "${CID}" domains add .githubusercontent.com/assets -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = ".githubusercontent.com/assets" ]
}

@test "add --method: writes the method list first, uppercased" {
  run "${CID}" domains add --method get,head api.github.com/repos -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "GET,HEAD api.github.com/repos" ]
}

@test "add --method: applies to every host in one call" {
  "${CID}" domains add --method GET a.example.com b.example.com -C "${PROJ}"
  run cat "$(proj_file)"
  [ "${lines[0]}" = "GET a.example.com" ]
  [ "${lines[1]}" = "GET b.example.com" ]
}

@test "add --method: a method list in the argument works too" {
  run "${CID}" domains add 'GET api.github.com/repos' -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "GET api.github.com/repos" ]
}

@test "add --method: rejects a method that is not an HTTP method" {
  run "${CID}" domains add --method GETT api.github.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a valid allowlist entry"* ]]
  run bash -c "cat ${CLAUDE_PROJECTS_DIR}/*/allowed-domains.txt 2>/dev/null || true"
  [ -z "$output" ]
}

@test "add --method: rejects CONNECT (the tunnel is judged on the host alone)" {
  run "${CID}" domains add --method CONNECT api.github.com -C "${PROJ}"
  [[ "$output" == *"not a valid allowlist entry"* ]]
}

@test "add: rejects a path that could never match (query, '..', inner '*')" {
  local e
  for e in 'api.github.com/repos?page=1' 'api.github.com/repos/../admin' 'api.github.com/re*os'; do
    run "${CID}" domains add "${e}" -C "${PROJ}"
    [[ "$output" == *"not a valid allowlist entry"* ]] || {
      echo "accepted: ${e}"; return 1
    }
  done
  run bash -c "cat ${CLAUDE_PROJECTS_DIR}/*/allowed-domains.txt 2>/dev/null || true"
  [ -z "$output" ]
}

@test "add: a path-scoped entry is a distinct entry from the bare host" {
  "${CID}" domains add api.github.com -C "${PROJ}"
  "${CID}" domains add api.github.com/repos -C "${PROJ}"
  run cat "$(proj_file)"
  [ "${lines[0]}" = "api.github.com" ]
  [ "${lines[1]}" = "api.github.com/repos" ]
}

@test "add: re-adding a scoped entry is idempotent" {
  "${CID}" domains add --method GET api.github.com/repos -C "${PROJ}"
  run "${CID}" domains add --method get api.github.com/repos -C "${PROJ}"
  [[ "$output" == *"already in"* ]]
  run grep -c . "$(proj_file)"
  [ "$output" -eq 1 ]
}

@test "rm: removes a scoped entry without touching the bare host" {
  "${CID}" domains add api.github.com -C "${PROJ}"
  "${CID}" domains add --method GET api.github.com/repos -C "${PROJ}"
  run "${CID}" domains rm --method GET api.github.com/repos -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [ "$output" = "api.github.com" ]
}

@test "rm: the bare host does not remove a scoped entry for it" {
  "${CID}" domains add api.github.com/repos -C "${PROJ}"
  run "${CID}" domains rm api.github.com -C "${PROJ}"
  [[ "$output" == *"not in"* ]]
  run cat "$(proj_file)"
  [ "$output" = "api.github.com/repos" ]
}

@test "add --for: composes with a method and a path" {
  run "${CID}" domains add --for 15m --method GET api.github.com/repos -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [[ "$output" == "GET api.github.com/repos  # expires="* ]]
}

@test "--method is rejected for a non-domains kind" {
  run "${CID}" domains prune --method GET
  [ "$status" -eq 2 ]
  run "${CID}" skip-decryption add --method GET pinned.example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"--method is only valid"* ]]
}

@test "skip-decryption: a path is rejected (splicing is a host-level decision)" {
  run "${CID}" skip-decryption add pinned.example.com/v1 -C "${PROJ}"
  [[ "$output" == *"not a valid hostname"* ]]
}

# ---------------------------------------------------------------------------
# domains add --for <duration> — temporary, auto-expiring entries
# ---------------------------------------------------------------------------

@test "add --for: writes an expires= annotation in the future" {
  run "${CID}" domains add --for 15m example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  [[ "$output" == example.com*"# expires="* ]]
  local exp; exp="${output##*expires=}"
  [ "${exp}" -gt "$(date +%s)" ]
}

@test "add --for: rejects a malformed duration and writes nothing" {
  run "${CID}" domains add --for potato example.com -C "${PROJ}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad --for duration"* ]]
  run bash -c "cat ${CLAUDE_PROJECTS_DIR}/*/allowed-domains.txt 2>/dev/null || true"
  [ -z "$output" ]
}

@test "add --for: re-adding refreshes the expiry (one line, not two)" {
  "${CID}" domains add --for 1s example.com -C "${PROJ}"
  run "${CID}" domains add --for 1h example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run grep -c 'example.com' "$(proj_file)"
  [ "$output" -eq 1 ]
  run cat "$(proj_file)"
  local exp; exp="${output##*expires=}"
  [ "${exp}" -gt "$(( $(date +%s) + 1800 ))" ]
}

@test "add --for: a later plain add (no --for) promotes it to permanent" {
  "${CID}" domains add --for 1h example.com -C "${PROJ}"
  run "${CID}" domains add example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted to permanent"* ]]
  run cat "$(proj_file)"
  [ "$output" = "example.com" ]
}

@test "add --for: a leading-zero duration is decimal, not octal" {
  # "018" starts with a digit sequence that isn't valid octal (8) — a naive
  # bash arithmetic expansion of the raw string would blow up or misparse.
  run "${CID}" domains add --for 018s example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_file)"
  local exp; exp="${output##*expires=}"
  local now; now="$(date +%s)"
  [ "${exp}" -ge "$(( now + 15 ))" ]
  [ "${exp}" -le "$(( now + 25 ))" ]
}

@test "add --for: rejected for a non-domains kind (containers)" {
  run "${CID}" containers add --for 15m myapp-web -C "${PROJ}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"only valid for 'cid domains add'"* ]]
}

@test "prune: drops an expired entry, keeps a live one and a permanent one" {
  "${CID}" domains add example.com -C "${PROJ}"
  printf 'gone.com  # expires=1\n' >> "$(proj_file)"
  local future=$(( $(date +%s) + 3600 ))
  printf 'stays.com  # expires=%s\n' "${future}" >> "$(proj_file)"
  run "${CID}" domains prune -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pruned 1"* ]]
  run cat "$(proj_file)"
  [[ "$output" == *"example.com"* ]]
  [[ "$output" == *"stays.com"* ]]
  [[ "$output" != *"gone.com"* ]]
}

@test "prune: no-op on a list with nothing expired" {
  "${CID}" domains add example.com -C "${PROJ}"
  run "${CID}" domains prune -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to prune"* ]]
}

@test "prune: absent per-project list is a graceful no-op" {
  run "${CID}" domains prune -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to prune"* ]]
}

# ---------------------------------------------------------------------------
# domains show + smoke tests for the read-only commands
# ---------------------------------------------------------------------------

@test "domains: shows baseline and per-project additions" {
  "${CID}" domains add example.com -C "${PROJ}"
  run "${CID}" domains "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"api.anthropic.com"* ]]     # baseline
  [[ "$output" == *"example.com"* ]]           # per-project
}

# ---------------------------------------------------------------------------
# skip-decryption add|rm|show — the TLS-interception exception list. Same machinery
# and grammar as domains, a different file and a different question.
# ---------------------------------------------------------------------------

# Path to the (single) per-project skip-decryption list.
proj_skip_decryption() { echo "${CLAUDE_PROJECTS_DIR}"/*/skip-decryption.txt; }

@test "skip-decryption add: creates the per-project list and lowercases the host" {
  run "${CID}" skip-decryption add API.Example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_skip_decryption)"
  [ "$output" = "api.example.com" ]
}

@test "skip-decryption add: a wildcard entry is accepted, an invalid host is not" {
  run "${CID}" skip-decryption add .example.com -C "${PROJ}"
  [ "$status" -eq 0 ]
  run "${CID}" skip-decryption add 'not a host' -C "${PROJ}"
  [[ "$output" == *"not a valid hostname"* ]]
  run cat "$(proj_skip_decryption)"
  [ "$output" = ".example.com" ]
}

@test "skip-decryption add -g: appends to the baseline skip-decryption list" {
  run "${CID}" skip-decryption add -g pinned.example.org
  [ "$status" -eq 0 ]
  run grep -c '^pinned.example.org$' "${CLAUDE_DOCKER_CONFIG_DIR}/skip-decryption.txt"
  [ "$output" -eq 1 ]
}

@test "skip-decryption add -g: fails when the baseline file is absent (the proxy mounts it)" {
  rm -f "${CLAUDE_DOCKER_CONFIG_DIR}/skip-decryption.txt"
  run "${CID}" skip-decryption add -g pinned.example.org
  [ "$status" -eq 1 ]
  [[ "$output" == *"make init"* ]]
}

@test "skip-decryption rm: removes the entry and keeps comments" {
  "${CID}" skip-decryption add pinned.example.org -C "${PROJ}"
  printf '# keep me\n' >> "$(proj_skip_decryption)"
  run "${CID}" skip-decryption rm pinned.example.org -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_skip_decryption)"
  [ "$output" = "# keep me" ]
}

@test "skip-decryption: shows baseline and per-project entries" {
  "${CID}" skip-decryption add -g pinned.example.org
  "${CID}" skip-decryption add pinned.aaa.test -C "${PROJ}"
  run "${CID}" skip-decryption "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned.example.org"* ]]
  [[ "$output" == *"pinned.aaa.test"* ]]
}

@test "skip-decryption editing does not touch the egress allowlist" {
  "${CID}" skip-decryption add pinned.example.org -C "${PROJ}"
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [[ "$output" != *"pinned.example.org"* ]]
  [ ! -f "$(proj_file)" ]
}

@test "skip-decryption: --for and prune are rejected (they are domains-only)" {
  run "${CID}" skip-decryption add --for 15m pinned.example.org -C "${PROJ}"
  [ "$status" -eq 2 ]
  run "${CID}" skip-decryption prune -C "${PROJ}"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# ca — read-only view of the egress CA
# ---------------------------------------------------------------------------

@test "ca: reports a missing CA as an error pointing at make ca" {
  run "${CID}" ca
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"* ]]
  [[ "$output" == *"make ca"* ]]
}

@test "ca: prints path, expiry and fingerprint for a real CA" {
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  CA_KEY_BITS=2048 "${SCRIPT_DIR}/scripts/gen-ca.sh" >/dev/null
  run "${CID}" ca
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-in-docker egress CA"* ]]
  [[ "$output" == *"expires:"* ]]
  [[ "$output" == *"fingerprint:"* ]]
}

@test "ca: never prints the private key's contents" {
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  CA_KEY_BITS=2048 "${SCRIPT_DIR}/scripts/gen-ca.sh" >/dev/null
  run "${CID}" ca
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRIVATE KEY"* ]]
}

# ---------------------------------------------------------------------------
# containers add|rm|show — the docker-bridge allowlist, same machinery as
# domains but with container-name validation and no lowercasing.
# ---------------------------------------------------------------------------

# Path to the (single) per-project container allowlist file.
proj_containers() { echo "${CLAUDE_PROJECTS_DIR}"/*/docker-containers.txt; }

@test "containers add: creates the per-project list and writes the name" {
  run "${CID}" containers add myapp-web -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_containers)"
  [ "$output" = "myapp-web" ]
}

@test "containers add: a trailing '*' prefix glob is accepted" {
  run "${CID}" containers add 'myapp-*' -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_containers)"
  [ "$output" = "myapp-*" ]
}

@test "containers add: preserves case (container names are case-sensitive)" {
  run "${CID}" containers add MyApp -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_containers)"
  [ "$output" = "MyApp" ]
}

@test "containers add: rejects a name with shell metacharacters" {
  run "${CID}" containers add 'web; rm -rf /' -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a valid container name"* ]]
  [ ! -f "$(proj_containers)" ]
}

@test "containers add -g: appends to the baseline list, creating it" {
  run "${CID}" containers add -g infra-db
  [ "$status" -eq 0 ]
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/docker-containers.txt"
  [ "$output" = "infra-db" ]
}

@test "containers rm: removes the entry and keeps comments" {
  "${CID}" containers add myapp-web -C "${PROJ}"
  printf '# keep me\n' >> "$(proj_containers)"
  run "${CID}" containers rm myapp-web -C "${PROJ}"
  [ "$status" -eq 0 ]
  run cat "$(proj_containers)"
  [ "$output" = "# keep me" ]
}

@test "containers: shows baseline and per-project additions" {
  "${CID}" containers add -g infra-db
  "${CID}" containers add myapp-web -C "${PROJ}"
  run "${CID}" containers "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra-db"* ]]
  [[ "$output" == *"myapp-web"* ]]
}

@test "containers: editing does not touch the egress allowlist" {
  "${CID}" containers add myapp-web -C "${PROJ}"
  run cat "${CLAUDE_DOCKER_CONFIG_DIR}/allowed-domains.txt"
  [[ "$output" != *"myapp-web"* ]]
}

@test "env: lists a known variable under its section header" {
  run "${CID}" env
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuration"* ]]
  [[ "$output" == *"CLAUDE_MOUNTS"* ]]
  [[ "$output" == *"Egress proxy"* ]]
  [[ "$output" == *"Usage tracking"* ]]
}

@test "env: marks a currently-set variable with a leading *" {
  CLAUDE_MOUNTS="/x:/y" run "${CID}" env
  [ "$status" -eq 0 ]
  [[ "$output" == *"* CLAUDE_MOUNTS"* ]]
}

@test "env: never prints a secret's value" {
  MCP_GH_BEARER="github_pat_TOPSECRET" run "${CID}" env
  [ "$status" -eq 0 ]
  [[ "$output" != *"TOPSECRET"* ]]
  [[ "$output" == *"<set: hidden>"* ]]
}

@test "env: filter narrows to matching names" {
  run "${CID}" env EGRESS
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_EGRESS_NETWORK"* ]]
  # SOUND_PORT is a non-matching row and (unlike CLAUDE_MOUNTS) not in the banner.
  [[ "$output" != *"SOUND_PORT"* ]]
}

@test "env: an unmatched filter exits non-zero" {
  run "${CID}" env n/a-nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no variable name matches"* ]]
}

# ---------------------------------------------------------------------------
# watch / hosts — the egress alert watcher's viewers. The watcher itself is
# covered by test/watch.bats; these check the cid side reaches it.
# ---------------------------------------------------------------------------

@test "watch: status reports the watcher and the notifier" {
  run "${CID}" watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"watcher"* ]]
  [[ "$output" == *"notifier"* ]]
}

@test "watch: log says so when nothing has been recorded" {
  run "${CID}" watch log
  [ "$status" -eq 0 ]
  [[ "$output" == *"none yet"* ]]
}

@test "watch: log prints the most recent alerts" {
  printf 'ts\tinfo\tNew egress host: k\tcdn.example.com\n' \
    > "${CLAUDE_DOCKER_CONFIG_DIR}/egress-alerts.log"
  run "${CID}" watch log 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdn.example.com"* ]]
}

@test "watch: an unknown verb exits 2" {
  run "${CID}" watch bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown 'cid watch' verb"* ]]
}

@test "hosts: shows nothing recorded for a fresh project" {
  run "${CID}" hosts -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has contacted"* ]]
  [[ "$output" == *"Recorded: none"* ]]
}

@test "hosts: lists what the watcher recorded" {
  # `domains add` is the cheapest way to create the per-project dir; proj_file
  # then finds it without recomputing the key hash, as the domains tests do.
  "${CID}" domains add placeholder.test -C "${PROJ}"
  local dir; dir="$(dirname "$(proj_file)")"
  printf 'cdn.example.com\n' > "${dir}/seen-hosts.txt"
  run "${CID}" hosts -C "${PROJ}"
  [[ "$output" == *"cdn.example.com"* ]]
}

@test "hosts forget: removes the record so it alerts again" {
  "${CID}" domains add placeholder.test -C "${PROJ}"
  local dir; dir="$(dirname "$(proj_file)")"
  printf 'cdn.example.com\n' > "${dir}/seen-hosts.txt"
  run "${CID}" hosts forget -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"forgot every recorded host"* ]]
  [ ! -f "${dir}/seen-hosts.txt" ]
}

@test "hosts forget: nothing to forget is not an error" {
  run "${CID}" hosts forget -C "${PROJ}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to forget"* ]]
}

@test "list: runs and names the config dir" {
  run "${CID}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"${CLAUDE_DOCKER_CONFIG_DIR}"* ]]
}

@test "help: prints usage" {
  run "${CID}" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"domains add"* ]]
}

@test "unknown command exits non-zero" {
  run "${CID}" bogus
  [ "$status" -eq 2 ]
}
