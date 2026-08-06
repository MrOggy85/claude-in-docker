# Permissions: How the Layers Compose

"Permission" means three unrelated things in this project, enforced by three
programs that have no visibility into each other. Getting this container's
threat model right depends on knowing which one you're adjusting and what it
can and can't do. This page uses the container as the running example
throughout; see [Known Attack Vectors](attack-vectors.md) for the specific
exploits each layer is meant to stop.

## Three different things

| Layer | Enforced by | Decides | Configured via |
| --- | --- | --- | --- |
| **Permission rules** | Claude Code, in-process | Should *this* tool call run silently, be denied silently, or prompt you? | `permissions.allow` / `.deny` / `.ask` in `settings.json` |
| **Permission mode** | Claude Code, in-process | Does the prompt layer run at all? | `permissions.defaultMode`, `--dangerously-skip-permissions`, `/permissions` |
| **OS / container sandbox** | the kernel, Docker, nftables, Squid | What can the `claude` process *physically* reach, no matter what it thinks it's allowed to do? | `run.sh`, `Dockerfile`, `init-firewall.sh`, `proxy/` |

The first two live entirely inside the `claude` binary's own logic. It is the
same program deciding what its own rules say and whether to enforce them — a
confused or compromised Claude Code process is only as constrained as those
settings, and a bug or a malicious project settings file (see
[Project-Level Claude Settings](attack-vectors.md#project-level-claude-settings-mitigated-by-default))
can turn either one off from the inside.

The sandbox is different in kind: it is enforced by things the `claude`
process cannot see or negotiate with. `init-firewall.sh` runs as root before
`claude` ever starts and then the entrypoint drops to your unprivileged UID
([`entrypoint.sh`](../entrypoint.sh)); the egress proxy allow/denies by
hostname *outside* the container entirely (see [Centralized Egress
Proxy](egress-proxy.md)). Claude Code has no rule, mode, or setting that
reaches either one. That's the point — it's the backstop for when the first
two layers are wrong, disabled, or simply don't apply (a raw shell command has
no "permission rule" concept at all once it's running; the sandbox is what
still bounds it).

One scoping detail specific to this container: the `permissions` block that
matters for *trust* is the one at `~/.claude/settings.json`, which `run.sh`
mounts read-only from your own config dir (`add_ro_mount
"${CONFIG_DIR}/settings.json" "${HOME_IN_CONTAINER}/.claude/settings.json"`,
[`run.sh:196`](../run.sh)) — it's yours, so nothing here inspects or gates it.
A project's own `.claude/settings.json` / `settings.local.json` is a different
story: it arrives inside whatever repo you bind-mounted, so it's exactly as
trustworthy as that repo. That's the file
[`guards/project-settings.sh`](../guards/project-settings.sh) stops the run to
vet — see [Project-Level Claude Settings](attack-vectors.md#project-level-claude-settings-mitigated-by-default).

## Permission rules: deny → ask → allow, in that order

A rule is a `Tool` or `Tool(pattern)` entry (e.g. `Bash(git status)`,
`Read(src/**)`, `WebFetch(domain:github.com)`) matched as a prefix against the
actual call. Claude Code checks the three lists in a fixed order:

1. **`deny`** — matches here stop the call cold. No prompt, not overridable.
2. **`ask`** — matches here always prompt, even if the same call also matches
   an `allow` rule elsewhere.
3. **`allow`** — matches here run silently, no prompt.
4. Nothing matches → the active **permission mode** decides (below).

The nuance worth internalizing: **a `deny` rule cannot carry an allowlist
exception.** There's no "deny X except Y" syntax — `deny` and `allow` are just
two independent pattern lists, and `deny` is checked first, unconditionally.
If a call matches both, `deny` wins regardless of which pattern is more
specific. So a global `deny: ["Bash(curl *)"]` cannot be selectively reopened
by adding `allow: ["Bash(curl -s https://api.example.com/*)"]` underneath it
in a project's `settings.local.json` — that allow rule never gets consulted,
because the call already matched `deny` on the way in. The only way to carve
out an exception is to make the `deny` pattern itself narrower.

That asymmetry is exactly what lets [`guards/project-settings.sh`](../guards/project-settings.sh)
treat `deny` and `ask` entries in a project's committed settings as harmless
by construction: [`scripts/scan-project-settings.sh:662`](../scripts/scan-project-settings.sh)
skips them outright —

```sh
permissions.deny|permissions.ask) continue ;;   # only ever add friction
```

— because a `deny`/`ask` rule can only make *that project* stricter than your
global settings; it has no mechanism to loosen anything you haven't already
allowed. `permissions.allow` entries get the opposite treatment (classified
line by line by [`_classify_rule`](../scripts/scan-project-settings.sh)) precisely
because `allow` is the one list that can hand over capability. See [What makes
an `allow` rule dangerous](attack-vectors.md#what-makes-an-allow-rule-dangerous).

## Permission modes: why `bypassPermissions` is reasonable here, not on a bare host

The mode governs step 4 above — what happens when nothing in `deny`/`ask`/`allow`
matched. `default` prompts per call; `acceptEdits` auto-approves file edits but
still prompts for execution/network; `plan` runs read-only; `bypassPermissions`
(set via `permissions.defaultMode` or passed for one run as
`--dangerously-skip-permissions`, which `run.sh` forwards to `claude`
verbatim — see [`test/run.bats`](../test/run.bats)) skips the prompt layer
altogether, so every otherwise-unmatched call proceeds as if allowed.

`bypassPermissions` removes exactly one of the two layers in the table above —
Claude Code's own gate. What's left standing is whatever the sandbox still
enforces, and that's where the container changes the calculation:

- **On a bare host**, `bypassPermissions` removes the *only* gate. Whatever
  Claude Code decides to run, it runs as you: your full filesystem, your real
  SSH keys and cloud credentials, your unrestricted network, no undo.
- **Inside this container**, the same flag removes one gate out of two. The
  process still runs as an unprivileged UID with no path to root beyond one
  fixed script (`sudo` is restricted to `init-firewall.sh` alone — see
  [Egress Proxy: privilege model](egress-proxy.md#privilege-model)), still
  sees only the bind-mounted project (plus whatever you explicitly added via
  `CLAUDE_MOUNTS`), and still can reach the network *only* through the Squid
  proxy's per-project hostname allowlist — nothing else is routable, so a
  process that ignores the proxy env vars doesn't leak, it just fails to
  connect. A mistake made without a prompt is still bounded by all of that.

This is why `--dangerously-skip-permissions` is a reasonable convenience *for
this project* and a bad idea unwrapped: the name
warns you about the layer it removes, and the container is what makes
removing that layer tolerable. See [In-Container Privilege
Escalation](attack-vectors.md#in-container-privilege-escalation-partially-mitigated)
for what the sandbox layer does *not* close — capabilities are not dropped and
`no-new-privileges` is not set, so this is "reasonable," not "consequence-free."

## Sorting operations into buckets: irreversibility, not intent

`scripts/scan-project-settings.sh` never asks whether a rule is malicious —
"the question is never 'is this rule malicious' ... it is 'what capability does
this rule hand over unattended'" ([scripts/scan-project-settings.sh:200-203](../scripts/scan-project-settings.sh)).
The same question is the right one to ask when you write your own rules, and
the answer sorts cleanly by **can you undo it by reading a diff, or is the
effect already outside anything Claude Code or git can see the moment it
happens**:

| Bucket | Example operations | Why |
| --- | --- | --- |
| **allow** | `Read`/`Grep`/`Glob`/`LS` in the repo; `Edit`/`Write` inside the repo; local `git` history ops (`status`, `diff`, `log`, `branch`) | Changes nothing (reads), or changes something `git` already tracks and you can revert by looking at a diff. |
| **ask** | anything with a wildcard destination that's *usually* fine but not always: `Bash(npm run *)` (runs whatever the repo's `package.json` says), a pinned network call to a known endpoint | Reversibility depends on what's actually inside the wildcard; a human glance resolves it faster than a rule can. |
| **deny** | interpreters handed inline code (`python3 -c`, `node -e`) or a bare script (equivalent to `Bash(*)`); unpinned network commands (`curl *`, `WebFetch(domain:*)`); anything that crosses a boundary the session doesn't own — `chmod`/`mount`/`docker`, or `git -c core.hooksPath=...` planting a hook that fires on the **host** at your next commit | The effect either leaves the process entirely (network egress — you cannot recall sent bytes) or persists past the session in a place git doesn't track (a host git hook, a changed file mode, another container's state). No diff shows it; nothing "reverts" it. |

This is the same logic behind every list at the top of that script
(`ALWAYS_EXEC`, `INTERPRETERS`, `NET_CMDS`, `BOUNDARY_CMDS`, `GIT_BAD_SUBS`,
...): a rule is flagged not because the command *sounds* dangerous, but
because what it hands over can't be walked back once it runs. `Bash(git
config …)` is the sharpest example in this repo specifically because it's the
one path here that escapes the container outright — the payload it plants
runs on your **host**, at your next `git commit`, long after the session that
approved the rule is gone.

## The egress allowlist and `WebFetch(domain:...)` are two independent gates

Both look like "is this domain okay," but they're enforced by different
programs that don't consult each other, and allowing a host in one does
**not** allow it in the other:

- **`WebFetch(domain:example.com)`** is a Claude Code permission *rule*. It
  only decides whether Claude Code prompts before calling its own `WebFetch`
  tool for that host. It has no effect on `curl`, `git`, an MCP server's HTTP
  client, or anything else in the container — and no effect on the network
  itself.
- **`allowed-domains.txt`** ([Centralized Egress Proxy](egress-proxy.md)) is
  the container's network boundary, enforced by Squid outside the container
  and backed by an nftables rule that permits egress *only* to the proxy. It
  filters every outbound connection from every process in the container —
  `curl`, an MCP server, `WebFetch`'s own HTTP request — by CONNECT hostname,
  regardless of which tool or permission rule triggered it.

They can drift apart in either direction:

- A domain allowed by `WebFetch(domain:x)` but missing from
  `allowed-domains.txt` means Claude Code won't even ask before fetching it —
  and the request then fails at the network layer anyway, because Squid
  denies the CONNECT (`403`, or a connection failure if egress is misrouted).
  No prompt, no leak, just an error.
- A domain present in `allowed-domains.txt` but not covered by any `WebFetch`
  rule is reachable over the network the moment *any* process asks for it
  (`Bash(curl ...)`, an MCP client) — the proxy has no concept of "which tool
  requested this." Claude Code's own prompt for the `WebFetch` tool
  specifically is the only thing standing between an unlisted domain and a
  fetch, which is exactly why [`scripts/scan-project-settings.sh:490-494`](../scripts/scan-project-settings.sh)
  classifies a wildcard `WebFetch(domain:*)` allow rule the same way it
  classifies `Bash(curl *)` — an unpinned egress destination, the exfil half
  of a pair (see the [`allow` rule danger table](attack-vectors.md#what-makes-an-allow-rule-dangerous)).

Treat them as what they are: a permission rule scoped to one tool inside one
program, and a network boundary that has never heard of that program. Widening
one is not a substitute for widening the other, and narrowing one is not a
substitute for narrowing the other.
