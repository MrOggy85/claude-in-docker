# Known Attack Vectors

These are known attack vectors. Some are mitigated by this solution (noted as
such); the rest are not handled and are documented so you can assess the risk.

## Project-Level Claude Settings (mitigated by default)

Claude Code loads project-level settings from the working directory it runs in —
`.claude/settings.json` and the gitignored `.claude/settings.local.json`
override. Because the project is bind-mounted into the container, a committed
settings file from an untrusted repo is loaded there, and any hooks it defines
(e.g. a `PreToolUse` `command` hook) run arbitrary commands inside the container.

**Mitigation:** `run.sh` refuses to launch when the project contains
`.claude/settings.json` or `.claude/settings.local.json`, before any build,
volume, or container work happens. The container's settings come from
`${SCRIPT_DIR}` (mounted at `~/.claude/settings.json`), never from the project.

To run a project you trust that ships its own settings, opt in with
`CLAUDE_ALLOW_PROJECT_SETTINGS=1` (accepts `1`/`true`/`yes`/`on`), which skips
the guard and honors the project settings as-is.

## Update of Allowed Domains

If you run Claude in this folder, Claude can update `allowed-domains.txt` by itself. This is a very narrow threat which only applies if this folder is mounted in the container.

Note that the change does not take effect at runtime. `allowed-domains.txt` is read only at image build time (baked into `/etc/allowed-domains.txt`). The firewall — both its startup resolution and the [background refresher](firewall.md#ip-rotation-and-the-background-refresher) that re-resolves rotating IPs during the session — reads only that baked copy, never the mounted repo file. So Claude editing the mounted file cannot widen the live firewall — it only stages a new domain that takes effect on the next `./run.sh` rebuild.

## Firewall Boundary Disclosure via Fast-Fail

The firewall REJECTs non-whitelisted outbound connections (TCP RST / ICMP unreachable) rather than silently dropping them, so a blocked connection fails immediately with `ECONNREFUSED` instead of hanging until timeout. This is a deliberate DX tradeoff: it also lets any in-container process map the firewall boundary by probing — attempting connections and observing refused-vs-accepted — quickly and without timeouts.

This does not let a process *reach* a blocked destination; it only reveals which destinations are allowed. The whitelist is not secret (it is committed in `allowed-domains.txt`), so the disclosure is low impact. It is noted here because the prior silent-drop behavior made such probing slow and impractical, and the fast-fail change removes that friction.

## Allowlist Is IP-Based, Not Hostname-Based

The allowlist names **hostnames**, but the firewall enforces on **destination IP**: `init-firewall.sh` resolves each hostname to IPs and matches those in an ipset. It never inspects the TLS SNI or HTTP `Host` header. The actual policy is therefore *"any hostname reachable at an IP currently in the ipset is allowed"* — not *"only the hostnames you listed."*

This matters when an allowed host shares IPs with hosts you did **not** intend to allow — common on CDN/shared infrastructure. If `evil.example` (or another domain on the same provider) is served from an IP that one of your allowed hostnames also resolves to, a process in the container can reach it by connecting to that IP with a different SNI/`Host`; the firewall cannot tell the difference. Equally, a domain you deliberately excluded becomes reachable if it is ever served from an already-allowed IP.

Concrete example: the allowlist intends to permit `api.githubcopilot.com` only, **not** `api.github.com`, `github.com`, or `raw.githubusercontent.com`. As of this writing those happen to sit on separate networks — `api.githubcopilot.com` on GitHub's own range (`140.82.112.0/20`), the web/API on Azure (`20.27.177.0/24`), and `raw`/`objects` on Fastly (`185.199.108.0/22`) — so allowing the Copilot IPs does not grant the others **in practice today**. But that is an artifact of GitHub's current infra split, not something this firewall enforces: if GitHub serves `api.github.com` from a `140.82.112.x` address again (it historically did), or if a Copilot edge IP also answers for the `api.github.com` vhost, that traffic would be permitted. The IP allowlist cannot prevent it.

Enforcing a true per-hostname policy requires moving the check to L7 — e.g. an egress proxy that filters on TLS SNI and is the only permitted outbound destination, with the firewall blocking all direct egress. That is not implemented here; the IP allowlist is a deliberately simpler boundary that is sufficient when allowed hosts do not share infrastructure with untrusted ones. See [Outbound Firewall](firewall.md) for how the allowlist and its IP resolution work.

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
