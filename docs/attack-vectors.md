# Known Attack Vectors

Known attack vectors. Some are mitigated (noted as such); the rest are documented so you can assess
the risk. For a one-page protects/does-not-protect summary, see [Threat Model](threat-model.md).

## Project-Level Claude Settings (mitigated by default)

Claude Code loads project-level settings from its working directory — `.claude/settings.json` and the
gitignored `.claude/settings.local.json`. Because the project is bind-mounted into the container, a
committed settings file from an untrusted repo is loaded there, and any hooks it defines (e.g. a
`PreToolUse` `command` hook) run arbitrary commands inside the container.

Hooks are the best-known vector but **not the only one**. Several keys run a shell command
automatically, with no permission prompt and no deny rule that can stop them — each is arbitrary code
execution on the same footing as a hook:

- **`statusLine`** (with `{"type": "command"}`) — runs on every UI render cycle, so it fires
  immediately on session start and repeatedly after. The most easily overlooked, because it executes
  before you take any action.
- **`apiKeyHelper`** — runs on an interval to mint auth headers.
- **`awsCredentialExport`**, **`awsAuthRefresh`**, **`gcpAuthRefresh`** — run when cloud credentials
  are needed or expire.
- **`otelHeadersHelper`** — runs on startup and on a periodic refresh.
- **`fileSuggestion`** — runs when the user types `@` for file autocomplete.

A second class executes nothing itself but disables the prompt layer, turning gated tool calls into
silent ones:

- **`permissions.defaultMode`** set to `bypassPermissions`, `acceptEdits`, or `auto` — auto-approves
  tool calls.
- **`permissions.allow`** — pre-approves matching tool calls (e.g. `Bash(*)`).
- **`enableAllProjectMcpServers`** — combined with a project `.mcp.json`, auto-launches the `command`
  of every MCP server defined there (`guards/mcp-bearer-no-push.sh` only vets the GitHub token, not
  arbitrary `.mcp.json` server commands).

(`env` is a softer, indirect risk: it injects variables into every subprocess and can subvert
downstream commands without executing anything itself.)

A third class grants capability without executing anything: `permissions.allow` entries. Most are
inert (`mcp__github__list_issues`), but a few are equivalent to handing over the shell — see [What
makes an `allow` rule dangerous](#what-makes-an-allow-rule-dangerous).

**Mitigation:** when the project contains `.claude/settings.json` or `.claude/settings.local.json`,
`run.sh` stops before any build, volume, or container work (via `guards/project-settings.sh`). What
happens next depends on what the file grants:

1. `scripts/scan-project-settings.sh` classifies it by **capability**. A dangerous key from the lists
   above, **the value that key is set to** (the hook's command, the `statusLine` command, an `env`
   entry), an `allow` rule granting arbitrary execution / unbounded network / access outside the
   repo, or anything it cannot classify, each becomes a record. Everything else is accepted silently.
2. Nothing flagged → one summary line, no prompt.
3. Something flagged → you see **only those items**, grouped under their settings key
   (`permissions.allow` gets its own block), each with the capability it grants, and one y/n prompt.
   Declining aborts with a non-zero status.

   ```
     [key]  hooks
            registers commands Claude Code runs on tool use / session events
            → hooks.Stop.hooks.command = echo stopped   <-- new since your last approval

     [key]  permissions.allow
            tool calls auto-approved with no prompt
            → Bash(python3 *)
                'python3' with unbounded arguments runs any script
   ```
4. On approval, a sha256 of just those records — the "risk profile" — is stored in the per-project
   config dir. An unchanged profile is never asked about again; a changed one re-prompts and marks
   what is new.

Point 1 covers values, not just key names, for a reason: if the digest only recorded "this file has
hooks", approving a benign hook once would let the repo swap its `command` for anything and never be
asked again. Editing a hook command, its matcher, a `statusLine` command or an `env` value therefore
re-prompts, showing the new value inline. (Adding or removing a hook re-prompts too — a removal is
safe, but the digest only knows the profile changed.) A `[key]` record also prints a `cat` of the
file, because a command that runs with no prompt is worth reading in context.

The two layers are independent by design and the second does **not** stop at the first: a dangerous
key does not make the `allow` list beneath it irrelevant, so both are always reported.

If stdin is not a terminal (`/dev/tty` unavailable), the prompt is treated as declined and the run
aborts, so non-interactive invocations stay secure by default. The container's own settings come from
the config dir (mounted read-only at `~/.claude/settings.json`), never from the project.

Why a memo rather than prompting every time: Claude Code **rewrites `settings.local.json` every
session** as you approve permissions, so a presence-triggered guard dumped a 50-rule file at every
start. A prompt that long and that frequent is answered reflexively, which is the same as no prompt.
The digest covers exactly the security-relevant subset, so appending
`mcp__slack__slack_read_thread` is silent while appending `Bash(bash -c *)` is not. The memo lives
**outside the project** (`<config-dir>/projects/<key>/`), so a repo cannot approve itself; forging
one means finding a sha256 preimage.

Two escape hatches:

- `CLAUDE_ALLOW_PROJECT_SETTINGS=1` (accepts `1`/`true`/`yes`/`on`) skips the guard entirely and
  honors the project settings as-is.
- `CLAUDE_PROJECT_SETTINGS_STRICT=1` restores the old behaviour: the whole file, every run, with no
  approval recorded. Use it to audit.

Inspect any of this without starting a session with `cid settings`; silence a rule you have decided
is fine with `cid settings trust '<rule>'` (`-g` for every project); re-arm with
`cid settings forget`. See [docs/config-cli.md](config-cli.md).

### What makes an `allow` rule dangerous

Not maliciousness — capability. An attacker doesn't write `Bash(rm -rf /)`; they write a rule that
reads like tooling and happens to be Turing-complete. The scanner therefore asks what a rule *hands
over unattended*, and Claude Code's prefix matching means the answer depends on how much of the
command is pinned: `Bash(curl -s http://localhost:3000/*)` can only reach localhost, while
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
`Bash(git -C /path branch -a)`, `Read(src/**)`) grant none of this and are never shown. The
authoritative lists live at the top of `scripts/scan-project-settings.sh`; the dangerous-key list
there mirrors this page, so update both together.

## Project-Level MCP Servers (mitigated by Claude Code)

A committed `.mcp.json` can define a stdio MCP server whose `command` is executed to launch it. This
is **not** an unguarded path: Claude Code prompts for approval before launching any project-scoped
server, so one from an untrusted repo is not started until you accept it. The approval is per-project
and persisted in the mounted `~/.claude.json` — see [Shared `claude.json` Collapses Per-Project Trust
State](#shared-claudejson-collapses-per-project-trust-state-mitigated) for how that file is kept
genuinely per-project. In a non-interactive invocation there is no prompt and unapproved servers are
skipped.

The one way to turn this into a silent launch is `enableAllProjectMcpServers` (or
`enabledMcpjsonServers`) in a project settings file, which auto-approves without prompting — but both
keys are on the [project settings guard](#project-level-claude-settings-mitigated-by-default)'s
dangerous-key list, so either triggers the prompt. Note that `guards/mcp-bearer-no-push.sh` only vets
the GitHub MCP token; Claude Code's own approval prompt is what covers `.mcp.json` server commands.

## Shared `claude.json` Collapses Per-Project Trust State (Mitigated)

Every project is bind-mounted at the same in-container path (`/home/dev/repo`), and `claude.json` —
which Claude Code uses to key trust-dialog acceptance and MCP-server approvals by working-directory
path — was previously mounted straight from the global config dir, read-write, into every container.
That collapsed every project's entry onto the identical key (`projects["/home/dev/repo"]`) in the
same host file: approving a `.mcp.json` server once for a project you trust could silently
pre-approve a same-named entry the next time an unrelated project — including a stranger's freshly
cloned repo — defined a server Claude Code matches against that state. Same failure class as the
public "TrustFall" disclosure (one trust decision extending past its intended scope), introduced here
by this tool's fixed-path mount design rather than by Claude Code itself.

`run.sh` now seeds a private `claude.json` under `<config-dir>/projects/<key>/` the first time it
sees a project (copied from the global file, so existing onboarding state carries over) and mounts
that instead — the same fallback pattern already used for `container-CLAUDE.md` and
`mcp-servers.json`. Mutations after that stay local to each project.

This is unrelated to usage/cost tracking: `ccusage` reads the JSONL transcripts under `~/.claude/`
(the directory), backed by the per-project **named volume**, not `~/.claude.json` (the file), which
only ever held onboarding/trust state.

**Residual risk:** projects that ran this tool before the fix keep whatever mixed approval history
their pre-fix `claude.json` accumulated; the fix only stops new collisions. For a clean slate, delete
`<config-dir>/projects/<key>/claude.json` and it is reseeded on the next run.

**To verify:** run the tool against two scratch directories in sequence, each with a `.mcp.json`
defining a server under the *same* name but a different `command`. Approve the prompt in the first;
the second should still prompt. Diff the two `<config-dir>/projects/<key>/claude.json` files
(`./cid project` prints each key) to confirm they diverge.

## In-Container Privilege Escalation (Partially Mitigated)

The main process runs as your unprivileged host UID:GID (`run.sh` `--user "$(id -u):$(id -g)"`), and
root escalation along the *intended* path is locked down: `sudo` is restricted by
`/etc/sudoers.d/firewall` to exactly one command, `/usr/local/bin/init-firewall.sh`, and that script
is `COPY`'d to a root-owned path the runtime user cannot edit. You cannot `sudo bash`, and you cannot
swap the script. `NET_ADMIN` is only exercisable through it.

What is **not** mitigated is the rest of the escalation surface, because the container runs without
two hardening flags:

- **Default capabilities are not dropped.** `run.sh` passes `--cap-add=NET_ADMIN` but no
  `--cap-drop=ALL`. `--cap-add` *adds* to Docker's default set rather than replacing it, so the
  container holds the full default set (`CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `NET_RAW`, …)
  **plus** `NET_ADMIN`. A root-level compromise therefore wields the whole default cap set.
- **`no-new-privileges` is off.** There is no `--security-opt no-new-privileges`, and `sudo` (a
  setuid-root binary) is installed by the `Dockerfile`. Any setuid-root vulnerability — the Baron Samedit (CVE-2021-3156)
  and PwnKit (CVE-2021-4034) class, several of which need no sudoers entry — is a live root path
  **independent of** the scoped sudoers rule. With `no-new-privileges` set, such bugs are inert.

The scoped sudoers rule and unprivileged runtime user defend the intended escalation path; they do
**not** defend against setuid bugs or limit the capability blast radius after a root compromise.
Closing this requires `--cap-drop=ALL` (re-adding only `NET_ADMIN`) and `--security-opt
no-new-privileges`. Note the `NET_ADMIN` comment in `run.sh` — "no other escalation is possible from
the non-root runtime user" — is accurate only for the intended path; it overstates the guarantee for
the setuid surface.

## Update of Allowed Domains

The egress allowlist (baseline and per-project) lives in **the config dir on the host**, outside every
mounted project, and is bind-mounted read-only into the Squid proxy. It is **not** mounted into the
Claude containers, so Claude running in them cannot see or edit it.

The narrow exception is running Claude **on this repo itself** with the config dir mounted in. Then
Claude can edit `allowed-domains.txt`, and because the proxy re-reads the lists live (≈30s verdict
cache, no rebuild), a widened allowlist takes effect within ~30s. The blast radius is still bounded:
a widened list only adds hostnames the proxy will then permit by CONNECT target. Treat edits to these
files as changes to a security boundary, and review the diffs.

## Egress Boundary Disclosure via Fast-Fail

The in-container egress-lock REJECTs non-permitted outbound connections (TCP RST / ICMP unreachable)
rather than dropping them, so a blocked connection fails immediately with `ECONNREFUSED` instead of
hanging. At the packet-filter layer this reveals little — only that egress is locked to the Squid
host — but the proxy is also a fast signal: Squid answers a denied CONNECT with an immediate HTTP
`403`, so a process can map the per-host allowlist by probing (allowed → tunnel established; denied →
403) without timeouts.

This does not let a process *reach* a blocked destination; it only reveals which hosts are allowed.
The allowlist is not secret (it is a host-side file you maintain), so the disclosure is low impact.
It is noted because silent-drop behavior would make such probing slow and impractical.

## Allowlist Is Hostname-Based, but Filters on the CONNECT Host (not SNI)

This is the threat the Squid egress proxy **resolves**: filtering is on the **CONNECT target
hostname**, not destination IP. A host sharing a CDN IP block with an allowlisted host is no longer
implicitly reachable — the proxy permits a tunnel only when the requested host is on the list,
regardless of where it resolves. The earlier IP-allowlist concern no longer applies.

One residual gap remains, lower-impact than the IP version it replaces: Squid matches on the
**CONNECT host string**, and for an HTTPS tunnel it does not verify that the TLS **SNI** inside the
tunnel matches. A host permitting *domain fronting* could therefore be reached under an allowed
CONNECT name while the encrypted SNI names a different host on the same frontable infrastructure.
Closing this is optional hardening — Squid `ssl_bump peek` + a `splice` rule asserting SNI == CONNECT
host (no decryption, so cert pinning is unaffected); not enabled by default. See the [Centralized
Egress Proxy](egress-proxy.md#trust-model--limitations) trust model.

## DNS Exfiltration (Partially Mitigated)

Egress to the proxy required closing the wide-open DNS channel the old IP-allowlist mode had.
`init-firewall.sh` permits port 53 **only to Docker's embedded resolver** (`127.0.0.11`); external
DNS to an arbitrary IP is rejected:

```sh
# init-firewall.sh — DNS restricted to Docker's embedded resolver (nftables)
ip daddr 127.0.0.11 udp dport 53 accept
ip daddr 127.0.0.11 tcp dport 53 accept
```

This kills the **direct-to-authoritative** variant: a process can no longer open a socket to port 53
of an attacker-controlled nameserver. (The container only needs DNS to resolve the `squid` alias;
Squid resolves upstream hostnames itself.)

It does **not** fully close the channel. `127.0.0.11` is a recursive forwarder, so a query for
`exfil-chunk.attacker.example` still reaches the attacker's authoritative NS one hop removed, with
the data encoded in the hostname labels. The bar rises from *trivial* to *one-hop-proxied via the
Docker resolver*. Fully closing it would require either an **L7 DNS proxy** — an allowlist-only
resolver (Unbound, CoreDNS) returning NXDOMAIN for anything not in `allowed-domains.txt`, with port
53 restricted to it, so queries for unlisted names fail without leaving the host — or **DNS egress
monitoring** for suspicious patterns (high query rate,
high-entropy labels, unlisted second-level domains, unusual TLDs). Neither is implemented. Like the
[fast-fail disclosure](#egress-boundary-disclosure-via-fast-fail), the residual one-hop channel moves
data out without reaching a blocked destination directly.

## Host Bridges on Host-Outbound Ports (Accepted Trade-off, Opt-In)

Three optional features let the container connect **directly to the host**, on an explicit port
allowlist enforced by `init-firewall.sh`: the [sound server](sound-effects.md), the [chrome-devtools
bridge](chrome-devtools-mcp.md), and the [read-only docker bridge](docker-bridge.md). Traffic to
`host.docker.internal` is in `NO_PROXY`, so **none of it passes through Squid** —
`allowed-domains.txt` does not apply, and the port rule plus whatever the host daemon enforces are
the only controls. All three are off unless you open the port (the sound port is the one merged by
default, and its endpoint only plays a local file).

- **The sound server and the chrome bridge have no authentication at all.** Both bind `0.0.0.0` —
  required, because the container reaches the host over the Docker gateway — so anything that can
  reach your host on those ports can drive them. For the sound server that means playing a file from
  a fixed directory; for the chrome bridge, full browser automation as the host user, which is why
  that page calls it a deliberate hole.
- **The docker bridge is the one that requires a token**, because a view of the host's containers is
  not something to leave open. The token is minted per project and also *selects* that project's
  container allowlist, so the container cannot assert which allowlist applies to it — unlike the
  Squid proxy username (see [Egress Proxy](egress-proxy.md)).

For the docker bridge, the residual risks after the token, allowlist, and fixed argv are:

- **Container logs are an unfiltered read channel.** Whatever your allowlisted containers log —
  tokens, connection strings, user data — the agent can read over a path Squid does not see. Keeping
  the allowlist to the project at hand is the mitigation; there is no output filtering beyond
  stripping `Labels` and `Mounts` from `docker ps` (they carry host filesystem paths).
- **A too-broad allowlist would expose other sessions.** `docker logs` on another `claude-*`
  container would surface its env — including that session's `MCP_GH_BEARER` — and on
  `claude-egress-proxy` would surface every URL every session has requested.
  `guards/docker-bridge.sh` refuses to launch with a bare `*`, a `claude-…` entry, or a glob covering
  either, but it runs once pre-flight: it validates the list, it does not gate individual calls.
- **No mutating verb exists, by construction.** There is no `run`, `build`, `exec`, `cp`, or
  `inspect` — the last because `docker inspect` dumps `Config.Env` for any container. Mounting
  `/var/run/docker.sock` instead would void essentially every invariant on this page at once. See
  [Not implemented: build and run](docker-bridge.md#not-implemented-build-and-run).

## GitHub MCP Token Write Access (Accepted Trade-off)

The GitHub MCP token (`MCP_GH_BEARER`) may hold **Issues** and **Pull requests** write access, so
Claude can open, comment on, and update issues and PRs on your behalf.
`guards/mcp-bearer-no-push.sh` still rejects any token with **Contents: write**, so repository
*contents* cannot be mutated — see [docs/mcp-servers.md](mcp-servers.md). Two residual risks come
with the write scope; both are the price of the convenience, not defects.

**Exfiltration sink.** Issue, PR, and comment bodies are attacker-writable free text. A compromised
in-container process — or a prompt-injected Claude — can encode stolen data into a comment or issue
on any repo the token can write to, and read it back later from a location it controls. The **egress
allowlist does not stop this**: the data leaves via GitHub, an already-allowed destination, so it
looks like ordinary API traffic. This is a working exfil channel of the same character as the
[DNS](#dns-exfiltration-partially-mitigated) and
[fast-fail](#egress-boundary-disclosure-via-fast-fail) channels. The enabler is the write scope
itself, not any one hostname; adding or removing `api.github.com` from the allowlist changes nothing,
because the same operations are already reachable through the MCP server.

**Unwanted writes.** The same access lets a compromised session create, edit, close, or comment on
issues and PRs — noise, misleading content, or a merge of an already-open PR — bounded to the repos
and orgs the token is scoped to.

**Reducing it:** scope the fine-grained token to the **minimum set of repositories** (not "all
repositories"), and drop Issues / Pull requests write entirely if you don't need Claude acting on
your behalf — a read-only token removes this channel. The code-push guard bounds the blast radius
but does not close the write-to-issues channel; that is inherent to granting the scope.

## Issue/Comment-Triggered CI Automation (mitigated by the action)

Everything above concerns the sandbox `run.sh` builds when you run this tool **locally**. This
repository also runs Claude **on itself**, for maintenance, via `.github/workflows/claude.yml` — a
separate surface executing in GitHub Actions, outside that sandbox, with `contents: write` /
`pull-requests: write` / `issues: write`.

Two gates stand between a comment and a session, and only the second matters:

1. **The workflow `if:`** — a substring check for `@claude` in the issue, comment, or review body. It
   does not look at `author_association`, so on a public repo any account's comment can *start the
   job*.
2. **`claude-code-action`'s own actor check** — the action requires the triggering user to have
   **write access**, verified for issue, pull request, comment and review events, and refuses GitHub
   Apps and bots unless named in `allowed_bots`. A run started by an account without write access
   stops here, before Claude executes. See the action's [security
   docs](https://github.com/anthropics/claude-code-action/blob/main/docs/security.md).

So the trigger population is collaborators, not the internet. Adding an `author_association`
allowlist to the `if:` is cheap defence in depth — it declines the run before a runner is spent — but
it is not what closes the hole.

What remains:

- **A compromised or careless collaborator account** — the same population as [GitHub MCP Token Write
  Access](#github-mcp-token-write-access-accepted-trade-off), one layer earlier: that row is what a
  *running* session can do, this is who can cause one to run.
- **Prompt injection through text the trigger did not write.** A collaborator who tags `@claude` on
  an issue opened by a stranger hands that stranger's text to Claude as context. The action strips
  HTML comments, invisible characters and hidden attributes, but the sanitiser is a filter, not a
  boundary.
- **The granted tools.** `claude_args` allows `WebFetch`, `WebSearch`, and a pinned set of Bash
  commands (`make test:*`, `make lint`, `bats`, `shellcheck`, `jq`) on top of the action's
  file/git/GitHub defaults. `curl`/`wget` are deliberately not granted: `WebFetch` covers reading
  linked material, and a raw HTTP client in a job holding write tokens is a cleaner exfil path.
  Widening that list widens this row.

## Untrusted Package Artifacts on the Host

The project directory is bind-mounted read-write, so anything an in-container install writes
(`node_modules/`, lockfiles, dotfiles) lands on the host disk. Those files are harmless at rest, but
the container cannot prevent the host from later executing or interpreting them. The blast radius is
whatever you mount (the repo plus any `CLAUDE_MOUNTS`); mitigation is host-side op-sec — never run
project tooling on the host, and gate the unsafe path behind a deliberate action (e.g. a
`claude-bare` alias).

[Volume-Backed Paths](volume-backed-paths.md) removes these files from the host by backing
`node_modules` (and any `CLAUDE_VOLUME_PATHS` you add) with named volumes. This is **on by default**;
the vectors below apply to whatever is *not* volume-backed — paths you haven't covered, or everything
if you opt out with `SKIP_CLAUDE_VOLUME_PATHS`.

- **Lifecycle scripts on the host** — a later `npm install` / `npm run` / `npx` on the host runs
  `postinstall` and `node_modules/.bin` scripts fetched in the container.
- **Git hooks** — husky or `core.hooksPath` pointing into `node_modules` runs package code on a host
  `git commit` / `push`.
- **Editor/LSP auto-execution** — eslint/prettier plugins, TS `tsconfig` `"plugins"`, test-runner
  configs, and VS Code tasks (`runOn: folderOpen`) execute package code when a host tool opens or
  lints the project.
- **Planted host-triggered payloads** — a container-side script can write anywhere in the mounted
  tree (`Makefile`, `.envrc`, `.vscode/tasks.json`, `package.json` `scripts`) to be triggered later
  on the host.
- **Symlink traps** — a package symlinks within `node_modules` to host secrets (`~/.ssh`, `~/.aws`);
  a host tool following the link reads or exfiltrates them.
- **Config poisoning** — a dropped `.npmrc` (registry override or `_authToken` exfil) is honored by a
  later host `npm` invocation.
- **`direnv` / `.envrc`** — a planted `.envrc` runs on the host when you `cd` into the directory.
- **Parser/tooling exploits** — a crafted file exploits a vulnerability in a host editor/LSP/parser
  that merely reads it (low probability).
