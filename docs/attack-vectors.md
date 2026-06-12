# Known Attack Vectors

These are known attack vectors that are not handled by this solution.

## Update of Allowed Domains

If you run Claude in this folder, Claude can update `allowed-domains.txt` by itself. This is a very narrow threat which only applies if this folder is mounted in the container.

Note that the change does not take effect at runtime. `allowed-domains.txt` is read only at image build time (baked into `/etc/allowed-domains.txt`), and the firewall resolves it to IPs once at container start. So Claude editing the mounted file cannot widen the live firewall — it only stages a new domain that takes effect on the next `./run.sh` rebuild.

## Firewall Boundary Disclosure via Fast-Fail

The firewall REJECTs non-whitelisted outbound connections (TCP RST / ICMP unreachable) rather than silently dropping them, so a blocked connection fails immediately with `ECONNREFUSED` instead of hanging until timeout. This is a deliberate DX tradeoff: it also lets any in-container process map the firewall boundary by probing — attempting connections and observing refused-vs-accepted — quickly and without timeouts.

This does not let a process *reach* a blocked destination; it only reveals which destinations are allowed. The whitelist is not secret (it is committed in `allowed-domains.txt`), so the disclosure is low impact. It is noted here because the prior silent-drop behavior made such probing slow and impractical, and the fast-fail change removes that friction.

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
