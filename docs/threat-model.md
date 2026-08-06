# Threat Model

This project runs an untrusted, non-deterministic agent — and whatever
untrusted repo/packages it touches — inside a container as your host user. It
narrows the blast radius of that agent going wrong or the host being
compromised. It does **not** eliminate either risk. This page is the summary;
[Known Attack Vectors](attack-vectors.md) is the detailed, per-vector
enumeration it points into.

## Protects against

| Threat | How |
| --- | --- |
| Host filesystem outside the mounted project | Only the project directory (plus anything you explicitly add via `CLAUDE_MOUNTS`) is bind-mounted; nothing else on the host is visible inside the container. |
| Arbitrary egress | `init-firewall.sh` locks all outbound traffic to the shared Squid proxy; Squid enforces a per-project hostname allowlist. See [Centralized Egress Proxy](egress-proxy.md). |
| Credentials outside the container | Only what `run.sh` explicitly mounts in (the Claude OAuth token, optionally `MCP_GH_BEARER`) is present; nothing else from the host's keychain, env, or other credential stores is exposed. |
| Untrusted project settings running commands unattended | `guards/project-settings.sh` gates on capability, not presence — see [Project-Level Claude Settings](attack-vectors.md#project-level-claude-settings-mitigated-by-default). |
| Untrusted project MCP servers auto-launching | Claude Code prompts for approval before launching a project-scoped server — see [Project-Level MCP Servers](attack-vectors.md#project-level-mcp-servers-mitigated-by-claude-code). |
| Root escalation via the intended `sudo` path | `sudo` is restricted to one script, `init-firewall.sh` — see [In-Container Privilege Escalation](attack-vectors.md#in-container-privilege-escalation-partially-mitigated) (partial: setuid-bug and capability risks remain, see below). |
| Direct-to-arbitrary-IP DNS exfiltration | Port 53 is restricted to Docker's embedded resolver — see [DNS Exfiltration](attack-vectors.md#dns-exfiltration-partially-mitigated) (partial: a one-hop channel remains). |

## Does not protect against

| Threat | Why |
| --- | --- |
| Anything inside the mounted folder | Files under the mount are as trusted as the session itself — a compromised or manipulated agent can read, write, or exfiltrate anything there (and anything under `CLAUDE_MOUNTS`). |
| Exfiltration via allowed domains | Data sent to an already-allowlisted host (GitHub, npm, an API endpoint) looks like ordinary traffic; the allowlist controls *destination*, not *content*. See [GitHub MCP Token Write Access](attack-vectors.md#github-mcp-token-write-access-accepted-trade-off) for the concrete case. |
| Container escape | A kernel or container-runtime vulnerability that breaks out of the container is not something this project defends against; hardening here (see [In-Container Privilege Escalation](attack-vectors.md#in-container-privilege-escalation-partially-mitigated)) reduces what a *root-in-container* compromise can reach, not whether the container boundary itself holds. |
| Malicious packages installed by the user's own build script | `install_additional_packages.sh` runs as root at image build time and is baked into the image; whatever it installs is trusted by construction — that trust is yours to place carefully. |
| Prompt injection deciding what to do within its permitted powers | The container constrains *where* the agent can act (this mounted folder, these allowlisted hosts), not *what* it decides to do inside that boundary. An agent talked into misusing an allowed tool call — writing a misleading PR, encoding data into an allowed API call — is a behavioral problem, not one a sandbox boundary can catch. |

## Residual risk, stated plainly

This is not an air-gapped or 100% secure setup, and nothing on this page should
be read as implying total isolation. It mitigates the obvious risks in both
directions: from within the container (an agent you cannot fully trust) and
from the host outward (if your host is later compromised, credentials and
conversations here are not trivially reachable). Several vectors in
[Known Attack Vectors](attack-vectors.md) are explicitly **partial**
mitigations or **accepted trade-offs** — read that page for what is
outstanding and why each was left as-is.
