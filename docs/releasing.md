# Cutting a Release

A release is three artifacts: an annotated **git tag**, a **CHANGELOG.md** section, and a **GitHub
Release page**. `make release` produces the first two; pushing the tag produces the third.

```bash
make release                    # derive the version from the commits since the last tag
make release DRY_RUN=1          # print what it would do, write nothing
git push --follow-tags origin master
```

The annotated tag is the only version store. There is no `VERSION` file and no `version` field in
`package.json` — that file is the image's npm manifest, not this project's.

| Variable       | Effect                                                                       |
| -------------- | ---------------------------------------------------------------------------- |
| `VERSION`      | explicit `x.y.z`, skipping bump derivation                                   |
| `DRY_RUN=1`    | print the version and section on stdout, write nothing                       |
| `INTRO_FILE`   | file inserted under the version heading, above the first group               |
| `ALLOW_BRANCH` | release off a branch other than `master`                                      |

## How the version is derived

[`scripts/release.sh`](../scripts/release.sh) reads the previous release with `git describe --tags
--abbrev=0 --match 'v[0-9]*'` — a tag that is not `vX.Y.Z` is skipped by the match or aborts the
run — and scans every commit since it:

| Found in the range                                                      | Bump    |
| ----------------------------------------------------------------------- | ------- |
| `!` before the `:` in a subject, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` body footer | major |
| a `feat`                                                                | minor   |
| anything else                                                           | patch   |

Any commit is releasable, so a docs-only range still yields a patch. A range containing nothing but
a previous `chore(release):` commit yields `nothing to release` and exits 1.

## What lands in the section

Commits are grouped by type in a fixed order — Features, Bug Fixes, Performance Improvements, Code
Refactoring, Documentation, Tests, Build System, Continuous Integration, Chores, then Other Changes
for a type outside that list. **Nothing is hidden**, unlike the conventional-changelog default preset
which drops `docs`/`chore`/`refactor`/`test`/`ci` — a third of this repo's history.

A scope renders as `**scope:** subject`. A trailing `(#NN)` from a squash merge becomes a
pull-request link; without one the commit is linked by hash. The base URL comes from `git remote
get-url origin`; with no origin, entries render unlinked.

Two kinds of commit are dropped from the section but still bump the version: non-conventional
subjects (this repo has 16, all pre-`#30`), and `chore(release):` commits, so a release never
appears in the next release's notes. A range of nothing but the former renders one Other Changes
line with their count — an empty section is what the workflow refuses to publish.

A breaking commit also gets a `### BREAKING CHANGES` group at the top, using the `BREAKING CHANGE:`
footer text where there is one and the subject otherwise.

## Pushing

`make release` never pushes — the tag push is what fires
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which extracts that version's
section from CHANGELOG.md and runs `gh release create`. Push from the **host**: the container has no
`gh`, cannot push, and neither GitHub MCP server exposes a create-release tool. The script itself
runs fine inside the container.

The workflow fails rather than publishing an empty Release, which is how a tag/changelog mismatch
surfaces.

## The first release

With no prior tag the derived bump gives `0.1.0`, so name it:

```bash
printf 'First tagged release of ...\n' > /tmp/intro.md
make release VERSION=1.0.0 INTRO_FILE=/tmp/intro.md DRY_RUN=1   # review
make release VERSION=1.0.0 INTRO_FILE=/tmp/intro.md
```

Use `INTRO_FILE` rather than editing CHANGELOG.md afterwards: the tag points at the release commit,
so anything added later is invisible to the workflow's checkout at that tag.

## Fixing a bad release

Before pushing, `git tag -d vX.Y.Z` and `git reset --hard HEAD~1`. After pushing, the tag is public
and its Release page exists — release a new patch version instead.
