# Security Policy

This project sandboxes an untrusted AI agent; it is a risk-mitigation tool,
not a claim of total isolation. Before reporting, read
[docs/threat-model.md](docs/threat-model.md) — anything listed there as
"does not protect against" or in
[docs/attack-vectors.md](docs/attack-vectors.md) as a partial mitigation or
accepted trade-off is a **known, already-documented** limitation, not a new
vulnerability.

## Supported Versions

There are no versioned releases — this project ships as a single rolling
`master` branch. Only the latest commit on `master` is supported; if you hit
an issue, update to the latest commit before reporting.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately using [GitHub's private
vulnerability reporting](https://github.com/MrOggy85/claude-in-docker/security/advisories/new)
(Security tab → "Report a vulnerability") rather than a public issue, so a fix
can land before details are public.

This is a personal, spare-time project with no formal SLA. Best-effort
expectations:

- Acknowledgment within **5 business days**.
- An initial assessment (confirmed / not applicable / needs more info) within
  **14 days**.
- A fix or mitigation timeline once confirmed, communicated in the advisory
  thread.

## Disclosure Expectations

This project follows coordinated disclosure: please give us a reasonable
window (**90 days** is a good default) to ship a fix before any public
disclosure. We'll credit reporters in the advisory and release notes unless
you ask to stay anonymous.
