<!--
Title this PR as a Conventional Commit — it becomes the squash commit subject,
and `scripts/release.sh` groups the changelog by it. A non-conventional subject
still bumps the version but is dropped from the release notes.

    fix(proxy): tell a rule denial apart from an unlisted host in egress alerts

`fix` bumps the patch version.
Delete any section below that has nothing to say.
-->

## Problem

<!-- The wrong behaviour, and the conditions that produce it. What a user sees
     when they hit it. Link the issue if there is one (Closes #NN). If it was
     never reported, say how it was found. -->

## Solution

<!-- What now happens instead, and why the fix belongs where it was put rather
     than at the nearest place the symptom showed up. -->

## Decisions and caveats

<!-- Cases deliberately left unfixed and why, adjacent bugs found but not
     touched, and anything whose behaviour changes for someone who had worked
     around the bug. -->

## Testing

<!-- The regression test that fails without the fix, plus any test-count
     deltas. State what is NOT covered. -->

## Breaking Change

<!-- OPTIONAL — delete this whole section if nothing breaks. Rare for a fix,
     but a bug someone depends on is still a break.

     This section is for the reviewer. It does NOT reach `scripts/release.sh`:
     we squash-merge, and GitHub builds the squash body from the branch's
     COMMIT MESSAGES, not from this description. A `## Breaking Change`
     heading flags nothing on its own.

     To actually cut a major version, do both:

     1. Mark the PR title:  fix(scope)!: ...   (the `!` before the colon)
        The title becomes the squash subject, and the `!` alone is enough to
        force the major bump.
     2. Put a `BREAKING CHANGE: ` footer in a COMMIT MESSAGE on this branch
        (amend or add one). The changelog prefers that footer for its wording
        and falls back to the bare subject without it.

     The changelog quotes only the FIRST LINE after the marker, so make that
     line stand alone: what broke, and what to do about it.

     Restate it here for the reviewer, and keep it identical to the commit: -->

BREAKING CHANGE: <what no longer works> — <what the user must change>
