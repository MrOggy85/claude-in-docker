#!/usr/bin/env bash
#
# release.sh — cut a release from Conventional Commits: derive the next version
# from the commits since the last tag, prepend a CHANGELOG.md section, commit it,
# and create an annotated tag. Run it with `make release`.
#
# The annotated TAG is the only version store. There is no VERSION file and no
# `version` field in package.json — package.json here is the image's npm manifest
# (see CLAUDE.md), not this project's. `git describe --tags --abbrev=0` is the
# single read of "what was the last release".
#
# It deliberately does NOT push. The tag push is what makes CI create the GitHub
# Release (.github/workflows/release.yml), so it stays a human action:
#   git push --follow-tags origin master
#
# Env vars:
#   VERSION      explicit x.y.z, skipping bump derivation (needed for the first
#                release: with no prior tag the derived bump gives 0.1.0)
#   DRY_RUN=1    print the version and section on stdout, write nothing
#   INTRO_FILE   file inserted under the version heading, above the first group
#   ALLOW_BRANCH release off a branch other than master
#
# Operates on the git repo containing $PWD, not on its own location, so it can be
# pointed at a scratch clone (and is testable — see test/release.bats).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=colors.sh disable=SC1091
source "${SCRIPT_DIR}/colors.sh"
# Info messages on stderr: stdout carries the rendered section under DRY_RUN.
color_init 2

# Field/record separators for the git -> awk stream. Control characters because
# a commit subject may legitimately contain any printable one.
US=$'\037'
RS=$'\036'

# The one shape a version may have, applied to the previous tag and to the next
# version alike.
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

# --- repo + guards ---------------------------------------------------------

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  fail "not inside a git repository"
  exit 1
}
cd "${REPO_DIR}"
CHANGELOG="${REPO_DIR}/CHANGELOG.md"

if ! git rev-parse -q --verify HEAD >/dev/null; then
  fail "no commits yet — nothing to release"
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${BRANCH}" == "HEAD" ]]; then
  fail "detached HEAD" "check out the release branch first"
  exit 1
fi
if [[ "${BRANCH}" != "master" && -z "${ALLOW_BRANCH:-}" ]]; then
  fail "on branch ${BRANCH}, not master" "set ALLOW_BRANCH=1 to release from here anyway"
  exit 1
fi

# Before anything is written, so the release commit only ever contains CHANGELOG.md.
if [[ -n "$(git status --porcelain)" ]]; then
  fail "working tree is not clean" "commit or stash first: git status"
  exit 1
fi

# --- commit range ----------------------------------------------------------

# --abbrev=0 gives the bare tag name of the nearest reachable tag. It fails when
# none exists, which is the first release: take all of history.
#
# --match keeps a non-release tag (a `nightly`, a submodule marker) from being
# read as the previous version: CUR would then be non-numeric, bash arithmetic
# would silently treat it as an unset variable, and the range would be measured
# from the wrong commit.
if PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
  RANGE="${PREV_TAG}..HEAD"
  CUR="${PREV_TAG#v}"
  # --match only asks for a leading v and a digit; a `v1.2` or `v1.2.3.4` would
  # get through it and reach the arithmetic below as garbage.
  if [[ ! "${CUR}" =~ ${SEMVER} && -z "${VERSION:-}" ]]; then
    fail "previous tag ${PREV_TAG} is not vX.Y.Z" "set VERSION=x.y.z to release anyway"
    exit 1
  fi
else
  PREV_TAG=""
  RANGE="HEAD"
  CUR="0.0.0"
fi

# --- repo URL for links ----------------------------------------------------

# Normalize whatever form origin takes into https://host/owner/repo. Empty when
# there is no origin (a scratch clone) — entries are then rendered without links.
BASE=""
if REMOTE="$(git remote get-url origin 2>/dev/null)"; then
  REMOTE="${REMOTE%.git}"
  REMOTE="${REMOTE%/}"
  case "${REMOTE}" in
    http://*|https://*) BASE="${REMOTE}" ;;
    # ssh://git@host/owner/repo
    ssh://*) REMOTE="${REMOTE#ssh://}"; REMOTE="${REMOTE#*@}"; BASE="https://${REMOTE}" ;;
    # git@host:owner/repo — the ':' is a separator here, not a port
    *@*:*) REMOTE="${REMOTE#*@}"; BASE="https://${REMOTE/://}" ;;
  esac
fi

# --- render ----------------------------------------------------------------

# One awk pass produces both the grouped section and the bump level, so the two
# can never disagree about what a commit is. `%b` (the body) is included for
# BREAKING CHANGE footers, hence the record separator: bodies are multi-line.
#
# --no-merges: a "Merge pull request #NN" subject is not a change of its own, and
# counting it would credit the range with work its children already describe.
#
# The first output line is "bump=<level> entries=<n>"; the rest is the section.
RENDERED="$(
  git log --no-merges --format="%s${US}%h${US}%b${RS}" "${RANGE}" |
    awk -v RS="${RS}" -v FS="${US}" -v base="${BASE}" '
      BEGIN {
        # Display order, and every type this repo uses. Unlike the
        # conventional-changelog default preset we hide nothing: docs, chore,
        # refactor, ci and test are a third of this history.
        n = split("feat fix perf refactor docs test build ci chore", order, " ")
        title["feat"]     = "Features"
        title["fix"]      = "Bug Fixes"
        title["perf"]     = "Performance Improvements"
        title["refactor"] = "Code Refactoring"
        title["docs"]     = "Documentation"
        title["test"]     = "Tests"
        title["build"]    = "Build System"
        title["ci"]       = "Continuous Integration"
        title["chore"]    = "Chores"
        level = 0   # 0 nothing, 1 patch, 2 minor, 3 major
        entries = 0
        dropped = 0
      }

      {
        subject = $1
        hash    = $2
        body    = $3
        # git ends each record with a newline, which lands at the head of the next.
        sub(/^\n+/, "", subject)
        if (subject == "") next

        # A previous release commit is not part of the next release.
        if (subject ~ /^chore\(release\)/) next

        # Any commit at all is releasable; type only decides how far.
        if (level < 1) level = 1

        breaking = 0
        if (subject ~ /^[a-z]+(\([^)]*\))?!: /) breaking = 1
        if (body ~ /(^|\n)BREAKING[ -]CHANGE: /) breaking = 1
        if (breaking) level = 3

        # Non-conventional subjects (this repo has 16, all pre-#30) bump the
        # version but cannot be grouped, so they are dropped from the section.
        if (!match(subject, /^[a-z]+(\([^)]+\))?!?: /)) { dropped++; next }

        head = substr(subject, 1, RLENGTH - 2)    # strip the trailing ": "
        rest = substr(subject, RLENGTH + 1)
        sub(/!$/, "", head)
        scope = ""
        if (match(head, /\([^)]+\)$/)) {
          scope = substr(head, RSTART + 1, RLENGTH - 2)
          type  = substr(head, 1, RSTART - 1)
        } else {
          type = head
        }
        if (type == "feat" && level < 2) level = 2

        # Squash merges end with " (#NN)": link the PR, else link the commit.
        link = ""
        if (match(rest, / \(#[0-9]+\)$/)) {
          num  = substr(rest, RSTART + 3, RLENGTH - 4)
          rest = substr(rest, 1, RSTART - 1)
          if (base != "") link = " ([#" num "](" base "/pull/" num "))"
        } else if (base != "") {
          link = " ([" hash "](" base "/commit/" hash "))"
        }

        entry = "* "
        if (scope != "") entry = entry "**" scope ":** "
        entry = entry rest link
        if (!(type in title)) type = "other"
        lines[type] = lines[type] entry "\n"
        entries++

        if (breaking) {
          # The footer text says what broke; the subject is only a fallback.
          msg = rest
          if (match(body, /(^|\n)BREAKING[ -]CHANGE: /)) {
            tail = substr(body, RSTART + RLENGTH)
            p = index(tail, "\n")
            if (p > 0) tail = substr(tail, 1, p - 1)
            if (tail != "") msg = tail
          }
          breaks = breaks "* " msg link "\n"
        }
      }

      END {
        bump = "none"
        if (level == 1) bump = "patch"
        if (level == 2) bump = "minor"
        if (level == 3) bump = "major"
        print "bump=" bump " entries=" entries

        if (breaks != "") printf "### BREAKING CHANGES\n\n%s\n", breaks
        for (i = 1; i <= n; i++) {
          t = order[i]
          if (t in lines) printf "### %s\n\n%s\n", title[t], lines[t]
        }
        if ("other" in lines) printf "### Other Changes\n\n%s\n", lines["other"]

        # A range of nothing but non-conventional subjects still releases, so say
        # so in one line rather than emit a heading with no body — an empty
        # section is what release.yml refuses to publish.
        if (entries == 0)
          printf "### Other Changes\n\n* %d non-conventional commit%s in this range — see the commit log\n\n",
            dropped, (dropped == 1 ? "" : "s")
      }
    '
)"

SUMMARY="${RENDERED%%$'\n'*}"
# Guarded rather than a bare `#*\n`: with an empty section there is no newline
# left to split on and the pattern would not match, handing the whole summary
# line back as the section.
if [[ "${RENDERED}" == *$'\n'* ]]; then
  SECTION="${RENDERED#*$'\n'}"
else
  SECTION=""
fi
BUMP="${SUMMARY#bump=}"; BUMP="${BUMP%% *}"
ENTRIES="${SUMMARY##*entries=}"

if [[ "${BUMP}" == "none" ]]; then
  fail "nothing to release since ${PREV_TAG:-the first commit}"
  exit 1
fi

# --- version ---------------------------------------------------------------

if [[ -n "${VERSION:-}" ]]; then
  NEXT="${VERSION#v}"
  ORIGIN="VERSION"
else
  IFS=. read -r MAJ MIN PAT <<<"${CUR%%-*}"
  case "${BUMP}" in
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    patch) PAT=$((PAT + 1)) ;;
  esac
  NEXT="${MAJ}.${MIN}.${PAT}"
  ORIGIN="derived version"
fi

# Both paths, not just VERSION: the derived one is only as good as PREV_TAG, and
# the commit lands before the tag — an invalid name discovered by `git tag` would
# leave a release commit behind with nothing pointing at it.
if [[ ! "${NEXT}" =~ ${SEMVER} ]]; then
  fail "${ORIGIN} is not semver: ${VERSION:-${NEXT}}"
  exit 1
fi

TAG="v${NEXT}"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  fail "tag ${TAG} already exists"
  exit 1
fi

kv "previous release" "${PREV_TAG:-none (first release)}"
kv "bump" "${BUMP}" "from $(git rev-list --no-merges --count "${RANGE}") commits"
kv "next version" "${TAG}"
if [[ "${ENTRIES}" == "0" ]]; then
  warn "no conventional commits in range" "the section will only say how many commits it covers"
fi

# --- assemble the section --------------------------------------------------

TMP_SECTION="$(mktemp)"
TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_SECTION}" "${TMP_FILE}"' EXIT

{
  printf '## %s (%s)\n\n' "${NEXT}" "$(date +%Y-%m-%d)"
  if [[ -n "${INTRO_FILE:-}" ]]; then
    if [[ ! -r "${INTRO_FILE}" ]]; then
      fail "INTRO_FILE is not readable: ${INTRO_FILE}"
      exit 1
    fi
    cat "${INTRO_FILE}"
    printf '\n'
  fi
  # $(...) stripped the trailing newline; put it back so the file is POSIX text.
  printf '%s\n' "${SECTION}"
} >"${TMP_SECTION}"

if [[ -n "${DRY_RUN:-}" ]]; then
  cat "${TMP_SECTION}"
  say "dry run — nothing written"
  exit 0
fi

# --- write, commit, tag ----------------------------------------------------

# Only a scratch repo reaches this: the real CHANGELOG.md is committed.
if [[ ! -f "${CHANGELOG}" ]]; then
  # shellcheck disable=SC2016  # the backticks are a markdown code span, not a subshell
  printf '# Changelog\n\nGenerated by `make release` from Conventional Commits; see docs/releasing.md.\n' \
    >"${CHANGELOG}"
fi

# Insert above the newest existing section. awk to a temp file then mv: `sed -i`
# alone is GNU-only (same reason as the Makefile's pin-digest target).
awk -v secfile="${TMP_SECTION}" '
  /^## / && !inserted {
    while ((getline line < secfile) > 0) print line
    print ""
    inserted = 1
  }
  { print }
  END {
    if (!inserted) {
      print ""
      while ((getline line < secfile) > 0) print line
    }
  }
' "${CHANGELOG}" >"${TMP_FILE}"
cp "${TMP_FILE}" "${CHANGELOG}"

git add -- "${CHANGELOG}"
git commit -q -m "chore(release): ${TAG}" -- "${CHANGELOG}"
git tag -a "${TAG}" -m "${TAG}"

ok "released ${TAG}" "push with: git push --follow-tags origin ${BRANCH}"
