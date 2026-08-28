<!--
Title this PR as a Conventional Commit — it becomes the squash commit subject,
and `scripts/release.sh` groups the changelog by it. A non-conventional subject
still bumps the version but is dropped from the release notes.

    feat(proxy): path- and method-level egress allowlist rules

`feat` bumps the minor version; every other type bumps the patch.
Delete any section below that has nothing to say.
-->

## Summary

<!-- What the branch does, in a few sentences. What could a user not do before? -->

## New Functionality

<!-- Each new capability, named. Flags, commands and config keys spelled out. -->

## Syntax

<!-- New or changed grammar: entry formats, CLI invocations, config shape.
     Show it in a fenced block with a worked example per case. Drop this
     section if the change adds no surface a user types. -->

## Decisions and caveats

<!-- The judgment calls a reviewer would otherwise have to reverse-engineer,
     and the limits of what this does. Boundary conditions, what is refused
     rather than handled, interactions with existing features, anything that
     changes behaviour for someone already relying on it. -->

## Testing

<!-- What was added and what it covers. Test-count deltas per file are the
     convention here. State what is NOT covered — the gap is the useful half. -->

## Breaking Change

<!-- OPTIONAL — delete this whole section if nothing breaks.

     This section is for the reviewer. It does NOT reach `scripts/release.sh`:
     we squash-merge, and GitHub builds the squash body from the branch's
     COMMIT MESSAGES, not from this description. A `## Breaking Change`
     heading flags nothing on its own.

     To actually cut a major version, do both:

     1. Mark the PR title:  feat(scope)!: ...   (the `!` before the colon)
        The title becomes the squash subject, and the `!` alone is enough to
        force the major bump.
     2. Put a `BREAKING CHANGE: ` footer in a COMMIT MESSAGE on this branch
        (amend or add one). The changelog prefers that footer for its wording
        and falls back to the bare subject without it.

     The changelog quotes only the FIRST LINE after the marker, so make that
     line stand alone: what broke, and what to do about it.

     Restate it here for the reviewer, and keep it identical to the commit: -->

BREAKING CHANGE: <what no longer works> — <what the user must change>
