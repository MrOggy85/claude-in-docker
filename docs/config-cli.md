# The `cid` config CLI

`cid` inspects and edits the claude-in-docker configuration, which lives outside the repo in the
config dir (`~/.config/claude-in-docker/` by default — see [Environment
Variables](environment-variables.md)). It finds those files, prints them, and edits the allowlists in
place so you never open `allowed-domains.txt`, `splice-domains.txt` or `docker-containers.txt` by
hand.

## Commands

```bash
./cid list                       # config dir + every global file (present/missing) + projects dir
./cid show <file>                # print a global config file (credentials are never dumped)
./cid project [dir]              # per-project key, config dir, and which overrides exist
./cid domains [dir]              # effective allowlist = baseline + this project's additions
./cid domains add <host>...      # add host(s) to the egress allowlist
./cid domains add --for <dur> <host>...   # add, but the entry auto-expires after <dur>
./cid domains rm  <host>...      # remove host(s) from the egress allowlist
./cid domains prune              # drop expired --for entries (hygiene only)
./cid splice [dir]               # hosts the proxy tunnels without decrypting TLS
./cid splice add|rm <host>...    # stop / resume decrypting a host
./cid ca                         # the egress CA: path, expiry, fingerprint, image copy status
./cid containers [dir]           # containers the docker bridge may inspect (baseline + project)
./cid containers add <name>...   # allow container(s) for the docker bridge
./cid containers rm  <name>...   # remove container(s) from that allowlist
./cid settings [dir]             # what a project's .claude/settings*.json actually grants
./cid settings trust '<rule>'    # stop flagging a permissions.allow rule
./cid settings untrust '<rule>'  # flag it again
./cid settings forget            # drop the approved risk profile, so the next run re-prompts
./cid env [filter]               # list the env vars you can set (current value / default)
./cid help
```

### `domains add` / `domains rm`

Both edit an `allowed-domains.txt`, by default the **current project's**
(`<config-dir>/projects/<key>/allowed-domains.txt`), created on demand.

- `-g`, `--global` — target the shared **baseline** list applying to every project.
- `-C`, `--dir <dir>` — select the project by directory (default: current). Ignored with `-g`.

A host is either an exact name (`example.com`) or a **wildcard** with a leading dot
(`.githubusercontent.com`) matching the apex and every subdomain — the same syntax the proxy enforces
(see [Centralized Egress Proxy](egress-proxy.md)). Hostnames are lowercased. `add` validates input
and is idempotent (duplicates reported and skipped); `rm` matches on the bare entry, so it removes a
line even with a trailing `# comment` and leaves others untouched.

```bash
cid domains add example.com              # allow example.com for THIS project
cid domains add .githubusercontent.com   # wildcard: apex + all subdomains
cid domains add -g registry.npmjs.org    # allow for EVERY project (baseline)
cid domains rm  example.com              # remove from this project's list
cid domains rm  -g sentry.io             # remove from the baseline
cid domains add -C ~/code/other foo.com  # edit a different project's list
```

Edits take effect **within ~2s**: Squid re-reads both lists on each request and caches verdicts for
2 seconds (`ttl=2` in `proxy/squid.conf`). No rebuild, no proxy restart. (Creating the baseline
file for the first time still needs `make init`, since the proxy mounts it.)

#### `domains add --for <duration>`

Adds the host with an expiry instead of permanently: `<duration>` is digits plus an optional
`s`/`m`/`h`/`d` suffix (bare digits = seconds). The proxy stops honoring the entry once the
duration elapses — see [Temporary entries](egress-proxy.md#temporary-entries) for how enforcement
works. Re-running `add --for` on the same host replaces its expiry; a later plain `add` (no
`--for`) promotes it to permanent. `--for` is only valid with `domains add` (not `containers` or
`settings`).

```bash
cid domains add --for 15m github.com         # allow for 15 minutes, then auto-deny
cid domains add --for 2h -g ci.example.com   # ...in the baseline, for 2 hours
cid domains prune                            # drop expired --for entries (hygiene; not required)
```

### `splice add` / `splice rm`

The same machinery against `splice-domains.txt`, the exception list to TLS interception: a host
listed there is tunnelled undecrypted, for clients that pin certificates. Identical grammar, `-g`/`-C`
behaviour and ~2s propagation as `domains`; `--for` and `prune` are not accepted. Splicing grants no
access — the host must still be on the egress allowlist. See [TLS Inspection](tls-inspection.md).

```bash
cid splice add api.example.com     # stop decrypting it, for THIS project
cid splice add -g .example.com     # ...for every project (baseline)
cid splice rm  api.example.com     # decrypt it again
cid splice                         # show the effective list
```

### `ca`

Read-only view of the CA the proxy signs decrypted TLS with: its path, mode, subject, expiry and
SHA-256 fingerprint, plus whether the copy baked into the image still matches (a mismatch means the
next `run.sh` rebuilds). Exits non-zero when there is no CA or it has expired — the first thing to
check when every HTTPS request in a session fails. The private key's contents are never printed.
Create or rotate with `make ca`.

### `containers add` / `containers rm`

The same machinery against `docker-containers.txt` — the host containers the [read-only docker
bridge](docker-bridge.md) may inspect. `-g` and `-C` behave as for `domains`, and the baseline file
is created on demand (nothing mounts it, so there is no `make init` prerequisite).

An entry is an exact container name or a **prefix glob** with a trailing `*` — quote it so your shell
doesn't expand it. Names are validated against Docker's charset and stay case-sensitive.

```bash
cid containers add myapp-web myapp-db    # allow two containers for THIS project
cid containers add 'myapp-*'             # prefix glob (quoted)
cid containers add -g infra-db           # allow for EVERY project (baseline)
cid containers rm  myapp-db              # remove from this project's list
cid containers                           # show the effective list
```

Edits apply on the **next bridge call** — the bridge re-reads the file every time, so no session
restart. With an empty list nothing is visible and `run.sh` refuses to launch with
`CLAUDE_DOCKER_BRIDGE=1`; `guards/docker-bridge.sh` also rejects a bare `*` or anything matching
other Claude sessions / the egress proxy.

### `settings`

A read-only preview of what `guards/project-settings.sh` will do. It runs the same scanner
(`scripts/scan-project-settings.sh`) against the project's `.claude/settings.json` and
`.claude/settings.local.json`, printing:

- every **flagged** item, grouped under its settings key — a key that runs a command, the values it
  carries (hook `command`, matcher, `env` entry), and under its own `permissions.allow` block each
  rule granting arbitrary execution / unbounded network / access outside the repo, with the
  capability it grants;
- how many further `allow` rules grant nothing (never shown — the reason the guard's prompt is short);
- whether the risk profile is **approved** for this project, stale, or not yet seen;
- the trusted rules in force.

```bash
cid settings                     # this project
cid settings -C ~/code/other     # another one
```

Output is colour-coded to a terminal — key names yellow, the values and rules you must actually read
cyan, surrounding explanation dimmed, anything new since your last approval red. The palette and the
`NO_COLOR` / `CLICOLOR_FORCE` / `TERM` precedence are shared with every other message; see
[Environment Variables](environment-variables.md#output).

### `settings trust` / `settings untrust`

Same machinery again, against `trusted-settings-rules.txt`: rules listed there are dropped before
classification, so the guard stops flagging them. Use it for a rule you have looked at and accepted —
`Bash(python3 *)` in a Python repo, say. `-g` and `-C` behave as elsewhere; the file is created on
demand.

Unlike the other lists, a rule contains spaces, quotes and globs, so **quote it** and give it exactly
as it appears in `permissions.allow`. Only a line whose first non-blank character is `#` is a
comment; nothing internal is stripped.

```bash
cid settings trust 'Bash(python3 *)'      # accept that rule in THIS project
cid settings trust -g 'Bash(npx *)'       # ...in every project
cid settings untrust 'Bash(python3 *)'    # flag it again
```

### `settings forget`

Deletes the approval memo (`<config-dir>/projects/<key>/approved-project-settings`), so the next run
prompts again. The memo holds a sha256 of the flagged records plus the records themselves, and lives
outside the project so a repo cannot approve itself. See [Known Attack
Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default).

## Listing environment variables

`cid env` prints every host environment variable that changes how the container runs, grouped by
area, with each one's current value or default and a one-line description. A leading `*` marks those
set in your environment; secrets (e.g. `MCP_GH_BEARER`) show as `<set: hidden>`. Pass a substring to
filter:

```bash
cid env             # everything
cid env EGRESS      # just the egress-proxy variables
cid env USAGE       # just the ccusage variables
```

It mirrors [Environment Variables](environment-variables.md), which carries the full descriptions
and per-variable reference links.

## Putting `cid` on your PATH

`cid` resolves its own location, so it works from anywhere. Symlink it:

```bash
ln -s "$PWD/cid" ~/.local/bin/cid    # or any dir already on $PATH
```

## Shell completion

`cid` ships a zsh completion at `completions/_cid`. Tab after `cid ` gives subcommands; after
`cid show ` config filenames; after `cid domains ` / `cid splice ` / `cid containers ` the `add` /
`rm` / `ls` verbs; and after each `rm ` the entries already on that list.

Install by putting the `completions` dir on your `fpath` before `compinit`:

```zsh
fpath=(/path/to/claude-in-docker/completions $fpath)
autoload -Uz compinit && compinit
```

Or, with Homebrew's zsh, symlink it into the existing site-functions `fpath`:

```zsh
ln -s "$PWD/completions/_cid" "$(brew --prefix)/share/zsh/site-functions/_cid"
rm -f ~/.zcompdump*
exec zsh
```
