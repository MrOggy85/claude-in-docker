# Security Policy

This file covers vulnerability reporting. For what this project does and does
not protect against, see [docs/threat-model.md](docs/threat-model.md) —
please check there first, since a known, documented limitation isn't
necessarily a new vulnerability.

## Supported Versions

There are no version branches or releases — this project ships as a single
rolling `master`. Security fixes land there; if you're running a fork or an
older checkout, update to the latest `master` before reporting.

## Reporting a Vulnerability

Please report suspected vulnerabilities using [GitHub's private vulnerability
reporting](https://github.com/MrOggy85/claude-in-docker/security/advisories/new)
(Security tab → "Report a vulnerability") rather than a public issue, so
details aren't disclosed before a fix is available.

Include what you'd include in any good bug report: the affected file(s) or
component, reproduction steps, and the impact you believe it has. There's no
formal SLA, but expect an initial response within a few days on a best-effort
basis — this is a small, unfunded project maintained outside working hours.

## Disclosure Expectations

This project follows coordinated disclosure: please give us a reasonable
window (90 days is a reasonable default) to investigate and ship a fix before
any public disclosure. If a fix lands sooner, or we agree an issue needs more
time, we'll communicate that directly in the report thread.
