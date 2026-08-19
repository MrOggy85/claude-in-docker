#!/usr/bin/env bats
#
# Unit tests for scripts/release.sh — version derivation, the CHANGELOG section,
# and the guards that stand between a typo and a published tag.
#
# The bump rules get the most cases because they are the part this repo's own
# history cannot vouch for: across 121 commits there is not one `!:` marker and
# not one BREAKING CHANGE footer, so major bumps have never actually run. A bug
# there would surface for the first time at v2.0.0, on a tag that is awkward to
# retract.
#
# Every case builds a throwaway repo in $BATS_TEST_TMPDIR, so nothing here can
# touch the real one.
#
# Run with: bats test/release.bats

bats_require_minimum_version 1.5.0

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
RELEASE="${SCRIPT_DIR}/scripts/release.sh"

setup() {
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}"
  cd "${REPO}"
  git init -q -b master .
  # Repo-local, so the suite does not depend on (or disturb) the host's identity.
  git config user.email 'test@example.com'
  git config user.name  'Test'
  git config commit.gpgsign false
  git remote add origin 'git@github.com:o/r.git'
}

# One commit whose subject is <subject>; a second -m becomes the body, which is
# where BREAKING CHANGE footers live.
_commit() {  # <subject> [body]
  echo "$1" >>log.txt
  git add -A
  if [[ -n "${2:-}" ]]; then
    git commit -q -m "$1" -m "$2"
  else
    git commit -q -m "$1"
  fi
}

# A prior release to measure the next one against.
_tagged() {  # <version>
  _commit "feat: groundwork"
  git tag -a "$1" -m "$1"
}

_dry() { run env DRY_RUN=1 "$@" "${RELEASE}"; }

# ---------------------------------------------------------------------------
# Version derivation
# ---------------------------------------------------------------------------

@test "release: a feat bumps the minor version" {
  _tagged v1.2.3
  _commit "feat: something new"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump: minor"* ]]
  [[ "$output" == *"next version: v1.3.0"* ]]
}

@test "release: a fix bumps the patch version" {
  _tagged v1.2.3
  _commit "fix: something broken"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v1.2.4"* ]]
}

@test "release: types other than feat/fix still bump the patch version" {
  _tagged v1.2.3
  _commit "docs: explain the thing"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump: patch"* ]]
  [[ "$output" == *"next version: v1.2.4"* ]]
}

@test "release: a feat outranks a fix in the same range" {
  _tagged v1.2.3
  _commit "fix: something broken"
  _commit "feat: something new"
  _dry
  [[ "$output" == *"next version: v1.3.0"* ]]
}

@test "release: a bang-marked subject bumps the major version" {
  _tagged v1.2.3
  _commit "feat!: drop the old flag"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"bump: major"* ]]
  [[ "$output" == *"next version: v2.0.0"* ]]
}

@test "release: a bang-marked subject with a scope bumps the major version" {
  _tagged v1.2.3
  _commit "feat(cid)!: drop the old flag"
  _dry
  [[ "$output" == *"next version: v2.0.0"* ]]
}

@test "release: a BREAKING CHANGE footer bumps the major version" {
  _tagged v1.2.3
  _commit "fix: tighten the guard" "BREAKING CHANGE: the guard now rejects empty input"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v2.0.0"* ]]
}

@test "release: the BREAKING-CHANGE hyphen spelling is honoured too" {
  _tagged v1.2.3
  _commit "fix: tighten the guard" "BREAKING-CHANGE: the guard now rejects empty input"
  _dry
  [[ "$output" == *"next version: v2.0.0"* ]]
}

@test "release: the breaking footer text becomes the BREAKING CHANGES entry" {
  _tagged v1.2.3
  _commit "fix: tighten the guard" "BREAKING CHANGE: empty input is now rejected"
  _dry
  [[ "$output" == *"### BREAKING CHANGES"* ]]
  [[ "$output" == *"* empty input is now rejected"* ]]
}

@test "release: with no prior tag the range is all of history" {
  _commit "feat: first thing"
  _commit "fix: second thing"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous release: none (first release)"* ]]
  [[ "$output" == *"from 2 commits"* ]]
}

@test "release: an explicit VERSION overrides the derived bump" {
  _commit "feat: first thing"
  _dry VERSION=1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v1.0.0"* ]]
  [[ "$output" == *"## 1.0.0 ("* ]]
}

@test "release: a non-semver VERSION is rejected" {
  _commit "feat: first thing"
  _dry VERSION=1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERSION is not semver"* ]]
}

@test "release: a leading v on VERSION is accepted and not doubled" {
  _commit "feat: first thing"
  _dry VERSION=v2.5.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v2.5.0"* ]]
  [[ "$output" != *"vv2.5.0"* ]]
}

# ---------------------------------------------------------------------------
# What lands in the section
# ---------------------------------------------------------------------------

@test "release: commits are grouped under their type's heading, in a fixed order" {
  _tagged v1.0.0
  _commit "chore: tidy up"
  _commit "docs: write it down"
  _commit "fix: repair it"
  _commit "feat: build it"
  _dry
  # Features before Bug Fixes before Documentation before Chores.
  feat_at=$(printf '%s\n' "$output" | grep -n '^### Features' | cut -d: -f1)
  fix_at=$(printf '%s\n' "$output" | grep -n '^### Bug Fixes' | cut -d: -f1)
  docs_at=$(printf '%s\n' "$output" | grep -n '^### Documentation' | cut -d: -f1)
  chore_at=$(printf '%s\n' "$output" | grep -n '^### Chores' | cut -d: -f1)
  [ "$feat_at" -lt "$fix_at" ]
  [ "$fix_at" -lt "$docs_at" ]
  [ "$docs_at" -lt "$chore_at" ]
}

@test "release: a scope is rendered in bold ahead of the subject" {
  _tagged v1.0.0
  _commit "feat(sandbox): report the port mapping"
  _dry
  [[ "$output" == *"* **sandbox:** report the port mapping"* ]]
}

@test "release: a trailing (#NN) becomes a pull-request link" {
  _tagged v1.0.0
  _commit "feat: squash-merged thing (#42)"
  _dry
  [[ "$output" == *"* squash-merged thing ([#42](https://github.com/o/r/pull/42))"* ]]
}

@test "release: a commit without a PR number is linked by hash" {
  _tagged v1.0.0
  _commit "feat: direct commit"
  _dry
  [[ "$output" == *"](https://github.com/o/r/commit/"* ]]
}

@test "release: an https origin yields the same base URL as the ssh form" {
  _tagged v1.0.0
  _commit "feat: thing (#7)"
  git remote set-url origin 'https://github.com/o/r.git'
  _dry
  [[ "$output" == *"([#7](https://github.com/o/r/pull/7))"* ]]
}

@test "release: an ssh:// origin yields the same base URL" {
  _tagged v1.0.0
  _commit "feat: thing (#7)"
  git remote set-url origin 'ssh://git@github.com/o/r.git'
  _dry
  [[ "$output" == *"([#7](https://github.com/o/r/pull/7))"* ]]
}

@test "release: entries are unlinked when there is no origin" {
  _tagged v1.0.0
  _commit "feat: thing (#7)"
  git remote remove origin
  _dry
  [[ "$output" == *"* thing"* ]]
  [[ "$output" != *"](http"* ]]
}

@test "release: non-conventional subjects bump the version but are not listed" {
  _tagged v1.0.0
  _commit "Update the readme"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v1.0.1"* ]]
  [[ "$output" == *"no conventional commits in range"* ]]
  [[ "$output" != *"* Update the readme"* ]]
}

# The section is empty here, which is where the awk summary line used to survive
# into it: with nothing after it there was no newline left to split the two apart.
@test "release: a range with no conventional commits says so instead of leaking awk's summary" {
  _tagged v1.0.0
  _commit "Update the readme"
  _commit "Another stray subject"
  _dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"* 2 non-conventional commits in this range"* ]]
  [[ "$output" != *"bump=patch"* ]]
  [[ "$output" != *"entries="* ]]
}

@test "release: one non-conventional commit is counted in the singular" {
  _tagged v1.0.0
  _commit "Update the readme"
  _dry
  [[ "$output" == *"* 1 non-conventional commit in this range"* ]]
}

@test "release: the committed changelog never carries awk's summary line" {
  _tagged v1.0.0
  _commit "Update the readme"
  run "${RELEASE}"
  [ "$status" -eq 0 ]
  ! grep -q 'entries=' CHANGELOG.md
}

@test "release: an unknown type lands under Other Changes" {
  _tagged v1.0.0
  _commit "style: reflow the comments"
  _dry
  [[ "$output" == *"### Other Changes"* ]]
  [[ "$output" == *"* reflow the comments"* ]]
}

@test "release: a previous release commit is not part of the next release" {
  _tagged v1.0.0
  _commit "chore(release): v1.0.0"
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to release since v1.0.0"* ]]
}

@test "release: INTRO_FILE lands under the heading, above the first group" {
  _tagged v1.0.0
  _commit "feat: something new"
  echo 'First tagged release of the thing.' >"${BATS_TEST_TMPDIR}/intro.md"
  _dry INTRO_FILE="${BATS_TEST_TMPDIR}/intro.md"
  [ "$status" -eq 0 ]
  intro_at=$(printf '%s\n' "$output" | grep -n 'First tagged release' | cut -d: -f1)
  head_at=$(printf '%s\n' "$output" | grep -n '^## 1\.1\.0' | cut -d: -f1)
  group_at=$(printf '%s\n' "$output" | grep -n '^### Features' | cut -d: -f1)
  [ "$head_at" -lt "$intro_at" ]
  [ "$intro_at" -lt "$group_at" ]
}

@test "release: an unreadable INTRO_FILE is rejected" {
  _tagged v1.0.0
  _commit "feat: something new"
  _dry INTRO_FILE="${BATS_TEST_TMPDIR}/nope.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTRO_FILE is not readable"* ]]
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

@test "release: a dirty working tree aborts" {
  _tagged v1.0.0
  _commit "feat: something new"
  echo 'uncommitted' >>log.txt
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
}

@test "release: an untracked file counts as dirty" {
  _tagged v1.0.0
  _commit "feat: something new"
  echo 'new' >stray.txt
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
}

@test "release: a branch other than master aborts" {
  _tagged v1.0.0
  git checkout -q -b feature
  _commit "feat: something new"
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"not master"* ]]
}

@test "release: ALLOW_BRANCH releases from another branch anyway" {
  _tagged v1.0.0
  git checkout -q -b feature
  _commit "feat: something new"
  _dry ALLOW_BRANCH=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"next version: v1.1.0"* ]]
}

@test "release: an existing tag aborts" {
  _tagged v1.0.0
  _commit "feat: something new"
  _dry VERSION=1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v1.0.0 already exists"* ]]
}

@test "release: a detached HEAD aborts" {
  _tagged v1.0.0
  _commit "feat: something new"
  git checkout -q --detach HEAD
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached HEAD"* ]]
}

@test "release: a repo with no commits aborts" {
  _dry
  [ "$status" -eq 1 ]
  [[ "$output" == *"no commits yet"* ]]
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

@test "release: DRY_RUN writes no file, no commit and no tag" {
  _tagged v1.0.0
  _commit "feat: something new"
  before="$(git rev-parse HEAD)"
  _dry
  [ "$status" -eq 0 ]
  [ ! -e CHANGELOG.md ]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ "$(git tag --list)" = 'v1.0.0' ]
  [ -z "$(git status --porcelain)" ]
}

@test "release: a real run commits the changelog and annotates the tag" {
  _tagged v1.0.0
  _commit "feat: something new"
  run "${RELEASE}"
  [ "$status" -eq 0 ]
  [ -f CHANGELOG.md ]
  # Only CHANGELOG.md is in the release commit, and the tree is clean after.
  [ "$(git show --name-only --format='' HEAD)" = 'CHANGELOG.md' ]
  [ "$(git log -1 --format='%s')" = 'chore(release): v1.1.0' ]
  [ -z "$(git status --porcelain)" ]
  # Annotated, not lightweight — `git push --follow-tags` ignores lightweight tags.
  [ "$(git cat-file -t v1.1.0)" = 'tag' ]
}

@test "release: the newest section is prepended above the previous one" {
  _tagged v1.0.0
  _commit "feat: the first new thing"
  run "${RELEASE}"
  [ "$status" -eq 0 ]
  _commit "feat: the second new thing"
  run "${RELEASE}"
  [ "$status" -eq 0 ]

  header_at=$(grep -n '^# Changelog' CHANGELOG.md | cut -d: -f1)
  new_at=$(grep -n '^## 1\.2\.0' CHANGELOG.md | cut -d: -f1)
  old_at=$(grep -n '^## 1\.1\.0' CHANGELOG.md | cut -d: -f1)
  [ "$header_at" -lt "$new_at" ]
  [ "$new_at" -lt "$old_at" ]
  # The release commit itself must not show up as a Chores entry.
  ! grep -q 'chore(release)' CHANGELOG.md
}

@test "release: a second release only covers commits since the previous tag" {
  _tagged v1.0.0
  _commit "feat: the first new thing"
  run "${RELEASE}"
  _commit "feat: the second new thing"
  run "${RELEASE}"
  [ "$status" -eq 0 ]

  # The 1.2.0 section must not repeat 1.1.0's entry.
  section="$(awk '/^## 1\.2\.0/{f=1;next} /^## 1\.1\.0/{f=0} f' CHANGELOG.md)"
  [[ "$section" == *"the second new thing"* ]]
  [[ "$section" != *"the first new thing"* ]]
}
