# Threat Model

What this project protects against and what it doesn't. For vector-by-vector detail behind each row,
see [Known Attack Vectors](attack-vectors.md).

This page covers the container sandbox `run.sh` builds when you run the tool **locally**. This
repository's own maintenance automation (`.github/workflows/claude.yml`) is a separate CI-side
surface — see [Issue/Comment-Triggered CI
Automation](attack-vectors.md#issuecomment-triggered-ci-automation-mitigated-by-the-action).

## Protects against

| Threat | How |
| --- | --- |
| Host filesystem outside the mounted project | Only the project directory (and any explicit `CLAUDE_MOUNTS`) is bind-mounted; nothing else on the host is reachable. |
| Arbitrary egress | Outbound traffic is locked to a per-project hostname allowlist enforced by a shared Squid proxy — see [Centralized Egress Proxy](egress-proxy.md). |
| Credentials outside the container | Your Claude Code login and MCP tokens live in the host config dir, mounted read-only; nothing inside can write back to them or reach another host's credentials. |
| Untrusted project settings / auto-launched MCP servers | `run.sh` gates on a project's `.claude/settings*.json` and `.mcp.json` before any build or container work — see [Project-Level Claude Settings](attack-vectors.md#project-level-claude-settings-mitigated-by-default) and [Project-Level MCP Servers](attack-vectors.md#project-level-mcp-servers-mitigated-by-claude-code). |
| One project's trust/MCP-approval state leaking into another | `claude.json` is seeded and mounted per-project, so an approval recorded for one project can't apply to an unrelated one — see [Shared `claude.json`](attack-vectors.md#shared-claudejson-collapses-per-project-trust-state-mitigated). |
| The intended root-escalation path | `sudo` is restricted to one fixed, root-owned firewall script — see [In-Container Privilege Escalation](attack-vectors.md#in-container-privilege-escalation-partially-mitigated). |
| Direct-to-IP DNS exfiltration | Port 53 is restricted to Docker's embedded resolver — see [DNS Exfiltration](attack-vectors.md#dns-exfiltration-partially-mitigated). |

## Does not protect against

| Threat | Why |
| --- | --- |
| Anything inside the mounted folder | The project directory is bind-mounted read-write by design — see [Untrusted Package Artifacts on the Host](attack-vectors.md#untrusted-package-artifacts-on-the-host). |
| Exfiltration via an allowed domain | The allowlist controls *which hosts* are reachable, not what's sent to them. A destination already on the list (e.g. the GitHub MCP endpoint) is a usable exfil sink — see [GitHub MCP Token Write Access](attack-vectors.md#github-mcp-token-write-access-accepted-trade-off). |
| Container escape | The container runs without `--cap-drop=ALL` or `--security-opt no-new-privileges`, so a root-level compromise wields a wider capability set and setuid bugs stay live — see [In-Container Privilege Escalation](attack-vectors.md#in-container-privilege-escalation-partially-mitigated). |
| Malicious packages installed by your own build script | `install_additional_packages.sh` runs as root at image build time; what it installs is trusted like the rest of the image. |
| Prompt injection acting within its permitted powers | If untrusted input convinces Claude to make a tool call it's already allowed (write in the mount, hit an allowed domain, comment on an issue), nothing here distinguishes that from a legitimate action. The sandbox limits *what's reachable*, not *whether the agent should do it*. |
| Untrusted text reaching this repo's own CI agent | `claude-code-action` requires the triggering user to have write access, so strangers can't invoke it — but a collaborator who tags `@claude` on an issue anyone can open hands that text to Claude, in a job with write permissions and outside the container sandbox — see [Issue/Comment-Triggered CI Automation](attack-vectors.md#issuecomment-triggered-ci-automation-mitigated-by-the-action). |

## Residual risk, plainly

This is not an air-gapped sandbox. It reduces the blast radius of running a non-deterministic agent
and third-party code you don't fully trust — mainly by keeping the host filesystem and network out
of reach by default — but an attacker who compromises the container, or an agent misusing powers
it already has, can still corrupt or exfiltrate the mounted project, use an allowed destination as a
covert channel, or escalate further inside the container. Every mitigation here raises the cost of
an attack; none eliminates it.

Found a way past a "protects against" row, or a gap not listed on [Known Attack
Vectors](attack-vectors.md)? See [SECURITY.md](../SECURITY.md) for how to report it.
