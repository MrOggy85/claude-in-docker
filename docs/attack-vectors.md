# Known Attack Vectors

These are known attack vectors. Some are mitigated by this solution (noted as
such); the rest are not handled and are documented so you can assess the risk.
See [docs/threat-model.md](threat-model.md) for the summary table (protects /
does not protect) this page's vectors slot into.

## Project-Level Claude Settings (mitigated by default)

Claude Code loads project-level settings from the working directory it runs in —
`.claude/settings.json` and the gitignored `.claude/settings.local.json`
override. Because the project is bind-mounted into the container, a committed
settings file from an untrusted repo is loaded there, and any hooks it defines
(e.g. a `PreToolUse` `command` hook) run arbitrary commands inside the container.

Hooks are the best-known vector but **not the only one**. Several settings keys
run a shell command automatically, with no permission prompt and no deny rule
that can stop them. Any of these in an untrusted settings file is arbitrary code
execution on the same footing as a hook:

- **`statusLine`** (with `{"type": "command"}`) — runs on every UI render cycle,
  so it fires immediately on session start and repeatedly thereafter. The most
  easily overlooked vector, because it executes before you take any action.
- **`apiKeyHelper`** — runs on an interval to mint auth headers.
- **`awsCredentialExport`**, **`awsAuthRefresh`**, **`gcpAuthRefresh`** — run on
  demand when cloud credentials are needed or expire.
- **`otelHeadersHelper`** — runs on startup and on a periodic refresh.
- **`fileSuggestion`** — runs when the user types `@` for file autocomplete.

A second class does not execute commands itself but disables the prompt layer
that is the last line of defense, turning otherwise-gated tool calls into silent
ones:

- **`permissions.defaultMode`** set to `bypassPermissions`, `acceptEdits`, or
  `auto` — auto-approves tool calls.
- **`permissions.allow`** — pre-approves matching tool calls (e.g. `Bash(*)`).
- **`enableAllProjectMcpServers`** — combined with a project `.mcp.json`,
  auto-launches the `command` of every MCP server defined there (command
  execution sourced from a sibling file; `guards/mcp-bearer-no-push.sh` only
  vets the GitHub token, not arbitrary `.mcp.json` server commands).

(`env` is a softer, indirect risk: it injects variables into every subprocess
and can subvert downstream commands without executing anything itself.)

A third class grants capability without executing anything itself:
`permissions.allow` entries. Most are inert (`mcp__github__list_issues`), but a
few are equivalent to handing over the shell — see [What makes an `allow` rule
dangerous](#what-makes-an-allow-rule-dangerous) below.

**Mitigation:** when the project contains `.claude/settings.json` or
`.claude/settings.local.json`, `run.sh` stops before any build, volume, or
container work happens (via `guards/project-settings.sh`). What it does then
depends on what the file actually grants:

1. `scripts/scan-project-settings.sh` classifies the file by **capability**. A
   dangerous key from the lists above, **the value that key is set to** (the
   hook's command, the `statusLine` command, an `env` entry), an `allow` rule
   that grants arbitrary execution / unbounded network / access outside the repo,
   or anything it cannot classify, each becomes a record. Everything else is
   accepted silently.
2. Nothing flagged → one summary line, no prompt.
3. Something flagged → you see **only those items**, grouped under the settings
   key they belong to (`permissions.allow` gets a block of its own), each with
   the capability it grants, and one y/n prompt. Declining aborts with a non-zero
   status.

   ```
     [key]  hooks
            registers commands Claude Code runs on tool use / session events
            → hooks.Stop.hooks.command = echo stopped   <-- new since your last approval

     [key]  permissions.allow
            tool calls auto-approved with no prompt
            → Bash(python3 *)
                'python3' with unbounded arguments runs any script
   ```
4. On approval, a sha256 of just those records — the "risk profile" — is stored
   in the per-project config dir. An unchanged profile is not asked about again;
   a changed one re-prompts and marks what is new.

Point 1 covers the values, not just the key names, for a specific reason: if the
digest only recorded "this file has hooks", approving a benign hook once would
let the repo swap its `command` for anything and never be asked again. Editing a
hook command, its matcher, a `statusLine` command or an `env` value therefore
re-prompts, and the prompt shows the new value inline. (Adding or removing a hook
re-prompts too — a removal is safe, but the digest only knows the profile
changed.) A `[key]` record also prints a `cat` of the file, because a command
that runs with no prompt is worth reading in its original context.

Note the two layers are independent by design and the second does **not** stop at
the first: a dangerous key does not make the `allow` list beneath it irrelevant,
so both are always reported.

If stdin is not a terminal (`/dev/tty` unavailable), the prompt is treated as
declined and the run aborts, so non-interactive invocations remain secure by
default. The container's settings come from the config dir
(`~/.config/claude-in-docker/settings.json`, mounted read-only at
`~/.claude/settings.json`), never from the project.

Why the memo, and why it is not weaker than prompting every time: Claude Code
**rewrites `settings.local.json` every session** as you approve permissions, so a
presence-triggered guard dumped a 50-rule file at every start. A prompt that long
and that frequent is answered reflexively, which is the same as no prompt. The
digest covers exactly the security-relevant subset, so appending
`mcp__slack__slack_read_thread` is silent while appending `Bash(bash -c *)` is
not. The memo lives **outside the project** (`<config-dir>/projects/<key>/`), so
a repo cannot approve itself; forging one means finding a sha256 preimage.

Two escape hatches:

- `CLAUDE_ALLOW_PROJECT_SETTINGS=1` (accepts `1`/`true`/`yes`/`on`) skips the
  guard entirely and honors the project settings as-is.
- `CLAUDE_PROJECT_SETTINGS_STRICT=1` restores the old behaviour: the whole file,
  every run, with no approval recorded. Use it to audit.

Inspect any of this without starting a session with `cid settings`; silence one
rule you have decided is fine with `cid settings trust '<rule>'` (`-g` for every
project); re-arm the prompt with `cid settings forget`. See
[docs/config-cli.md](config-cli.md).

### What makes an `allow` rule dangerous

Not maliciousness — capability. An attacker does not write `Bash(rm -rf /)`; they
write a rule that reads like tooling and happens to be Turing-complete. The
scanner therefore asks what a rule *hands over unattended*, and Claude Code's
prefix matching means the answer depends on how much of the command is pinned:
`Bash(curl -s http://localhost:3000/*)` can only reach localhost, while
`Bash(curl *)` can reach anything.

| Rule | What it actually grants |
| --- | --- |
| `Bash(python3 *)`, `Bash(node -e …)` | Arbitrary code execution, spelled as ordinary dev tooling. No different in effect from `Bash(*)`. |
| `Bash(*)`, bare `Bash` | Unbounded shell. |
| `Bash(npm run …)`, `Bash(npx …)` | Runs whatever the untrusted repo put in `package.json`. |
| `Read(//home/dev/.claude/**)` | Reads `~/.claude/.credentials.json` — your real Claude OAuth token, mounted there by `run.sh`. |
| `Bash(cat *)` | The same read, one level of indirection away. |
| `Bash(git config …)`, `Bash(git -c …)` | Sets `core.hooksPath` in the **bind-mounted** repo, so the payload runs on the **host** at your next commit. The one vector here that escapes the container. |
| `Bash(curl *)`, `WebFetch(domain:*)` | An unpinned egress destination — the exfil half of a pair. |
| `mcp__github-unext__*` | Auto-approves every tool that server exposes, including ones a later update adds. |

Rules that pin their arguments (`Bash(pnpm --version)`, `Bash(go version *)`,
`Bash(git -C /path branch -a)`, `Read(src/**)`) grant none of this and are never
shown. The authoritative lists live at the top of
`scripts/scan-project-settings.sh`; the dangerous-key list there mirrors this
page, so update both together.

## Project-Level MCP Servers (mitigated by Claude Code)

A committed `.mcp.json` can define a stdio MCP server whose `command` is executed
to launch it — another way an untrusted repo could run code in the container.
This is **not** an unguarded path: Claude Code prompts for approval before
launching any project-scoped server from `.mcp.json`, so a server from an
untrusted repo is not started until you accept it. The approval is per-project
and persisted (in the mounted `~/.claude.json`), so you are asked once and not
re-prompted on later runs. In a non-interactive invocation there is no prompt and
unapproved servers are simply skipped.

The one way to turn this into a silent launch is `enableAllProjectMcpServers` (or
`enabledMcpjsonServers`) in a project settings file, which auto-approves without
prompting — but that route is already caught by the [project settings
guard](#project-level-claude-settings-mitigated-by-default) above: both keys are
on its dangerous-key list, so either one triggers the prompt. Note that
`guards/mcp-bearer-no-push.sh` only vets the GitHub MCP token; it does not
inspect `.mcp.json` server commands — Claude Code's own approval prompt is what
covers them.

## In-Container Privilege Escalation (Partially Mitigated)

The main process runs as your unprivileged host UID:GID (`run.sh` `--user
"$(id -u):$(id -g)"`), and root escalation along the *intended* path is locked
down: `sudo` is restricted by `/etc/sudoers.d/firewall` to exactly one command,
`/usr/local/bin/init-firewall.sh` (set up in the `Dockerfile`), and that script
is `COPY`'d to a root-owned path the runtime user cannot edit. You cannot `sudo
bash`, and you cannot swap the script for your own. `NET_ADMIN` is only
exercisable through it.

What is **not** mitigated is the rest of the escalation surface, because the
container runs without two hardening flags:

- **Default capabilities are not dropped.** `run.sh` passes `--cap-add=NET_ADMIN`
  but no `--cap-drop=ALL`. `--cap-add` *adds* to Docker's default
  capability set rather than replacing it, so the container holds the full
  default set (`CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `NET_RAW`, …) **plus**
  `NET_ADMIN`. A root-level compromise inside the container therefore wields the
  whole default cap set, widening the blast radius.
- **`no-new-privileges` is off.** There is no `--security-opt
  no-new-privileges`, and `sudo` (a setuid-root binary) is installed
  (in the `Dockerfile`). Any setuid-root vulnerability — the Baron Samedit
  (CVE-2021-3156) and PwnKit (CVE-2021-4034) class, several of which need no
  sudoers entry — is a live root path **independent of** the scoped sudoers
  rule. With `no-new-privileges` set, such bugs are inert; without it, they are
  not.

The scoped sudoers rule and the unprivileged runtime user defend the intended
escalation path; they do **not** defend against setuid bugs or limit the
capability blast radius after a root compromise. Closing this requires
`--cap-drop=ALL` (re-adding only `NET_ADMIN`) and `--security-opt
no-new-privileges` on the `docker run` invocation. Note that the `NET_ADMIN`
comment in `run.sh` — "no other escalation is possible from the non-root runtime
user" — is accurate only for the intended path; it overstates the guarantee for
the setuid surface described above.

## Update of Allowed Domains

The egress allowlist (the baseline `allowed-domains.txt` and each
`<config-dir>/projects/<key>/allowed-domains.txt`) lives in **the config dir on
the host** (`~/.config/claude-in-docker/`), outside every mounted project, and is
bind-mounted read-only into the Squid proxy. It is **not** mounted into the
Claude containers that work on your projects, so Claude running in those
containers cannot see or edit it.

The narrow exception is running Claude **on this repo itself** (the
claude-in-docker checkout is the mounted project) with the config dir mounted in.
Then Claude can edit `allowed-domains.txt`, and because the proxy re-reads the lists live (≈30s verdict
cache, no rebuild), a widened allowlist takes effect within ~30s for the proxy —
note this is faster than the old image-rebuild model. The blast radius is still
bounded: a widened list only adds hostnames the proxy will then permit by CONNECT
target; it cannot reach anything else. Treat edits to these files as you would
any change to a security boundary, and review diffs to `allowed-domains.txt`.

## Egress Boundary Disclosure via Fast-Fail

The in-container egress-lock REJECTs non-permitted outbound connections (TCP RST / ICMP unreachable) rather than silently dropping them, so a blocked connection fails immediately with `ECONNREFUSED` instead of hanging. At the packet-filter layer this reveals little — only that egress is locked to the Squid host — but the proxy itself is also a fast signal: Squid answers a denied CONNECT with an immediate HTTP `403`, so a process can map the per-host allowlist by probing (allowed → tunnel established; denied → 403) without timeouts.

This does not let a process *reach* a blocked destination; it only reveals which hosts are allowed. The allowlist is not secret (it is a host-side file you maintain in the config dir), so the disclosure is low impact. It is noted here because silent-drop behavior would make such probing slow and impractical, and fast-fail removes that friction.

## Allowlist Is Hostname-Based, but Filters on the CONNECT Host (not SNI)

This is the threat the move to a Squid egress proxy **resolves**: filtering is now on the **CONNECT target hostname**, not on destination IP. A host that shares a CDN IP block with an allowlisted host is no longer implicitly reachable — the proxy permits a tunnel only when the requested host is on the list, regardless of where it resolves. The earlier IP-allowlist concern (allowing `api.githubcopilot.com`'s `140.82.x` IPs implicitly permitting anything else co-hosted there) no longer applies.

One residual gap remains, lower-impact than the IP version it replaces: Squid matches on the **CONNECT host string**, and for an HTTPS tunnel it does not verify that the TLS **SNI** inside the tunnel matches that CONNECT host. A host that permits *domain fronting* could therefore be reached under an allowed CONNECT name while the encrypted SNI names a different host on the same frontable infrastructure. Closing this is optional hardening — Squid `ssl_bump peek` + a `splice` rule asserting SNI == CONNECT host (no decryption, so cert pinning is unaffected); it is not enabled by default. See the [Centralized Egress Proxy](egress-proxy.md#trust-model--limitations) trust model.

## DNS Exfiltration (Partially Mitigated)

Egress to the proxy required closing the wide-open DNS channel the old IP-allowlist mode had. `init-firewall.sh` now permits port 53 **only to Docker's embedded resolver** (`127.0.0.11`); external DNS to an arbitrary IP is rejected by the egress-lock:

```sh
# init-firewall.sh — DNS restricted to Docker's embedded resolver (nftables)
ip daddr 127.0.0.11 udp dport 53 accept
ip daddr 127.0.0.11 tcp dport 53 accept
```

This kills the **direct-to-authoritative** variant: a process can no longer open a UDP socket to port 53 of an attacker-controlled nameserver IP, because that packet is rejected. (The container only needs DNS at all to resolve the `squid` alias; Squid resolves upstream hostnames itself.)

It does **not** fully close the channel. `127.0.0.11` is a recursive forwarder — it relays queries it receives up the DNS hierarchy — so a query for `exfil-chunk.attacker.example` still reaches the attacker's authoritative NS, one hop removed, with the data encoded in the hostname labels. The bar is raised from *trivial* (direct packet to any IP) to *one-hop-proxied via the Docker resolver*. Fully closing it would require:

- **L7 DNS proxy** — a local allowlist-only resolver (e.g. Unbound, CoreDNS) that resolves only the names in `allowed-domains.txt` and returns NXDOMAIN for everything else, with port 53 restricted to that resolver. Queries for unlisted names fail without leaving the host.
- **DNS egress monitoring** — log outgoing queries and alert/block on suspicious patterns (high query rate, high-entropy labels, unlisted second-level domains, unusual TLDs).

Neither is implemented. The residual one-hop channel is the practical gap; it is narrower than the prior unrestricted-port-53 channel but, like the [fast-fail disclosure](#egress-boundary-disclosure-via-fast-fail), it remains a way to move data out without reaching a blocked destination directly.

## Host Bridges on Host-Outbound Ports (Accepted Trade-off, Opt-In)

Three optional features let the container connect **directly to the host**, on an
explicit port allowlist enforced by `init-firewall.sh`: the [sound
server](sound-effects.md), the [chrome-devtools bridge](chrome-devtools-mcp.md),
and the [read-only docker bridge](docker-bridge.md). Traffic to
`host.docker.internal` is in `NO_PROXY`, so **none of it passes through Squid** —
`allowed-domains.txt` does not apply, and the port rule plus whatever the host
daemon itself enforces are the only controls. All three are off unless you open
the port (the sound port is the one merged by default, and its endpoint only plays
a local file).

Two properties are worth stating plainly:

- **The sound server and the chrome bridge have no authentication at all.** Both
  bind `0.0.0.0` — required, because the container reaches the host over the
  Docker gateway and a `127.0.0.1` bind is unreachable from it — so anything that
  can reach your host on those ports can drive them. For the sound server that
  means playing a file from a fixed directory. For the chrome bridge it means full
  browser automation as the host user, which is why that page calls it a
  deliberate hole.
- **The docker bridge is the one that requires a token**, because a view of the
  host's containers is not something to leave open. The token is minted per
  project and also *selects* that project's container allowlist, so the container
  cannot assert which allowlist applies to it — unlike the Squid proxy username
  (see [Egress Proxy](egress-proxy.md)).

For the docker bridge specifically, the residual risks after the token, the
container allowlist, and the fixed argv are:

- **Container logs are an unfiltered read channel.** Whatever your allowlisted
  containers log — tokens, connection strings, user data — the agent can read over
  a path Squid does not see. Keeping the allowlist to the project at hand is the
  mitigation; there is no output filtering beyond stripping `Labels` and `Mounts`
  from `docker ps` (they carry host filesystem paths).
- **A too-broad allowlist would expose other sessions.** `docker logs` on another
  `claude-*` container would surface its env — including that session's
  `MCP_GH_BEARER` — and on `claude-egress-proxy` would surface every URL every
  session has requested. `guards/docker-bridge.sh` refuses to launch with a bare
  `*`, a `claude-…` entry, or a glob covering either, but the guard runs once
  pre-flight: it validates the list, it does not gate individual calls.
- **No mutating verb exists, by construction.** There is no `run`, `build`,
  `exec`, `cp`, or `inspect` — the last because `docker inspect` dumps
  `Config.Env` for any container. Mounting `/var/run/docker.sock` instead would
  void essentially every invariant on this page at once; that is why it is not an
  option here. See
  [Not implemented: build and run](docker-bridge.md#not-implemented-build-and-run).

## GitHub MCP Token Write Access (Accepted Trade-off)

The GitHub MCP token (`MCP_GH_BEARER`) may hold **Issues** and **Pull requests** write access, so Claude can open, comment on, and update issues and PRs on your behalf. `guards/mcp-bearer-no-push.sh` still rejects any token with **Contents: write** (code push), so repository *contents* cannot be mutated through it — see [docs/mcp-servers.md](mcp-servers.md). Two residual risks come with the write scope; both are the price of the convenience, not defects.

**Exfiltration sink.** Issue, PR, and comment bodies are attacker-writable free text. A compromised in-container process — or a prompt-injected Claude — can encode stolen data into a comment or a new issue on any repo the token can write to, and read it back later from a location it controls (e.g. an issue on a public repo). The **egress allowlist does not stop this**: the data leaves via GitHub, an already-allowed destination (the MCP endpoint `api.githubcopilot.com`), so it looks like ordinary API traffic. This is a working exfil channel of the same character as the [DNS](#dns-exfiltration-partially-mitigated) and [fast-fail](#egress-boundary-disclosure-via-fast-fail) channels — it moves data out without reaching a *blocked* host. The enabler is the write scope itself, not any one hostname; adding or removing `api.github.com` from the allowlist does not change it, because the same operations are already reachable through the MCP server.

**Unwanted writes.** The same access lets a compromised session create, edit, close, or comment on issues and PRs — noise, misleading content, or a merge of an already-open PR — bounded to the repos and orgs the token is scoped to.

**Reducing it:** scope the fine-grained token to the **minimum set of repositories** it needs (not "all repositories"), and drop Issues / Pull requests write entirely if you do not need Claude acting on your behalf — a read-only token removes this channel. The code-push guard bounds the blast radius (no contents mutation) but does not close the write-to-issues channel; that is inherent to granting the scope.

## Untrusted Package Artifacts on the Host

The project directory is bind-mounted read-write, so anything an in-container install writes (e.g. `node_modules/`, lockfiles, dotfiles) lands on the host disk. Those files are harmless at rest, but the container cannot prevent the host from later executing or interpreting them. The blast radius is whatever you mount (the repo plus any `CLAUDE_MOUNTS`); mitigation is host-side op-sec — never run project tooling on the host, and gate the unsafe path behind a deliberate action (e.g. a `claude-bare` alias).

[Volume-Backed Paths](volume-backed-paths.md) removes these files from the host by backing `node_modules` (and any `CLAUDE_VOLUME_PATHS` you add) with named volumes. This is **on by default**; the vectors below apply to whatever is *not* volume-backed — paths you haven't covered, or everything if you opt out with `SKIP_CLAUDE_VOLUME_PATHS`.

- **Lifecycle scripts on the host** — a later `npm install` / `npm run` / `npx` on the host runs `postinstall` and `node_modules/.bin` scripts that were fetched in the container.
- **Git hooks** — husky or `core.hooksPath` pointing into `node_modules` runs package code on a host `git commit` / `push`.
- **Editor/LSP auto-execution** — eslint/prettier plugins, TS `tsconfig` `"plugins"`, test-runner configs, and VS Code tasks (`runOn: folderOpen`) execute package code when a host tool opens or lints the project.
- **Planted host-triggered payloads** — a container-side script can write anywhere in the mounted tree (`Makefile`, `.envrc`, `.vscode/tasks.json`, `package.json` `scripts`) to be triggered later on the host.
- **Symlink traps** — a package symlinks within `node_modules` to host secrets (`~/.ssh`, `~/.aws`); a host tool that follows the link reads or exfiltrates them.
- **Config poisoning** — a dropped `.npmrc` (registry override or `_authToken` exfil) is honored by a later host `npm` invocation.
- **`direnv` / `.envrc`** — a planted `.envrc` runs on the host when you `cd` into the directory.
- **Parser/tooling exploits** — a crafted file exploits a vulnerability in a host editor/LSP/parser that merely reads it (low probability).
