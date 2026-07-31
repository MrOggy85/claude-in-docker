# The `cid` config CLI

`cid` inspects and edits the claude-in-docker configuration. All config lives
outside the repo, in the config dir (`~/.config/claude-in-docker/` by default —
see [Environment Variables](environment-variables.md)). `cid` finds those files
for you, prints them, and edits the allowlists in place so you don't have to open
`allowed-domains.txt` or `docker-containers.txt` by hand.

## Commands

```bash
./cid list                       # config dir + every global file (present/missing) + projects dir
./cid show <file>                # print a global config file (credentials are never dumped)
./cid project [dir]              # per-project key, config dir, and which overrides exist
./cid domains [dir]              # effective allowlist = baseline + this project's additions
./cid domains add <host>...      # add host(s) to the egress allowlist
./cid domains rm  <host>...      # remove host(s) from the egress allowlist
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

Both edit an `allowed-domains.txt`. By default they target the **current
project's** list (`<config-dir>/projects/<key>/allowed-domains.txt`), created on
demand. Flags:

- `-g`, `--global` — target the shared **baseline** list
  (`<config-dir>/allowed-domains.txt`) that applies to every project instead.
- `-C`, `--dir <dir>` — select the project by directory (default: the current
  dir). Ignored with `-g`.

A host is either an exact name (`example.com`) or a **wildcard** with a leading
dot (`.githubusercontent.com`) that matches the apex and every subdomain — the
same syntax the proxy enforces (see [Centralized Egress Proxy](egress-proxy.md)).
Hostnames are lowercased; `add` is idempotent (a duplicate is reported and
skipped) and validates the input; `rm` matches on the bare entry, so it removes a
line even if it carries a trailing `# comment`, and leaves all other lines
untouched.

```bash
cid domains add example.com              # allow example.com for THIS project
cid domains add .githubusercontent.com   # wildcard: apex + all subdomains
cid domains add -g registry.npmjs.org    # allow for EVERY project (baseline)
cid domains rm  example.com              # remove from this project's list
cid domains rm  -g sentry.io             # remove from the baseline
cid domains add -C ~/code/other foo.com  # edit a different project's list
```

Edits take effect **within ~30s** — Squid re-reads the baseline and per-project
lists live on each request and caches verdicts for 30 seconds (`ttl=30` in
`proxy/squid.conf`). No image rebuild and no proxy restart. (Adding the very
baseline file for the first time still needs `make init`, which the proxy mounts.)

### `containers add` / `containers rm`

The same machinery against `docker-containers.txt`: the list of host containers
the [read-only docker bridge](docker-bridge.md) may inspect. `-g` and `-C` mean
exactly what they do for `domains`, and the baseline file is created on demand
(unlike `allowed-domains.txt`, nothing mounts it, so there is no `make init`
prerequisite).

An entry is either an exact container name or a **prefix glob** with a trailing
`*` — quote it so your shell doesn't expand it. Names are validated against
Docker's own charset and kept case-sensitive (unlike hostnames, which are
lowercased).

```bash
cid containers add myapp-web myapp-db    # allow two containers for THIS project
cid containers add 'myapp-*'             # prefix glob (quoted)
cid containers add -g infra-db           # allow for EVERY project (baseline)
cid containers rm  myapp-db              # remove from this project's list
cid containers                           # show the effective list
```

Edits apply on the **next bridge call** — the bridge re-reads the file every time,
so no session restart. With an empty list nothing is visible and `run.sh` refuses
to launch with `CLAUDE_DOCKER_BRIDGE=1`; `guards/docker-bridge.sh` also rejects a
bare `*` or anything matching the other Claude sessions / the egress proxy.

### `settings`

The read-only view of what `guards/project-settings.sh` will do before it does
it. `cid settings` runs the same scanner the guard runs
(`scripts/scan-project-settings.sh`) against the project's
`.claude/settings.json` and `.claude/settings.local.json`, and prints:

- every **flagged** item, grouped under the settings key it belongs to — a key
  that runs a command, the values that key carries (the hook's `command`, the
  matcher, an `env` entry), and, under its own `permissions.allow` block, each
  rule that grants arbitrary execution / unbounded network / access outside the
  repo, with the capability it grants;
- how many further `allow` rules grant nothing (these are never shown, and are
  the reason the guard's prompt is short);
- whether the risk profile is already **approved** for this project, stale, or
  not yet seen;
- the trusted rules in force.

```bash
cid settings                     # this project
cid settings -C ~/code/other     # another one
```

The block is colour-coded when it goes to a terminal — key names in yellow, the
values and rules you actually have to read in cyan, the surrounding explanation
dimmed, and anything new since your last approval in red. Piped or redirected
output is plain. Most explicit wins: `NO_COLOR=1` disables colour outright,
`CLICOLOR_FORCE=1` enables it even through a pipe or under `TERM=dumb`, and with
neither set `TERM=dumb` or a non-terminal target means plain text.

### `settings trust` / `settings untrust`

Same machinery as `domains` and `containers`, against
`trusted-settings-rules.txt`: rules listed there are dropped before
classification, so the guard stops flagging them. Use it for a rule you have
looked at and decided you are fine with — `Bash(python3 *)` in a Python repo,
say. `-g` and `-C` mean what they do elsewhere; the file is created on demand.

Unlike the other two lists, a rule contains spaces, quotes and globs, so **quote
it** and give it exactly as it appears in `permissions.allow`. Only a line whose
first non-blank character is `#` counts as a comment; nothing internal is
stripped.

```bash
cid settings trust 'Bash(python3 *)'      # accept that rule in THIS project
cid settings trust -g 'Bash(npx *)'       # ...in every project
cid settings untrust 'Bash(python3 *)'    # flag it again
```

### `settings forget`

Deletes the approval memo (`<config-dir>/projects/<key>/approved-project-settings`),
so the next run in that project prompts again. The memo holds a sha256 of the
flagged records plus the records themselves; it lives outside the project so a
repo cannot approve itself. See [Known Attack
Vectors](attack-vectors.md#project-level-claude-settings-mitigated-by-default).

## Listing environment variables

`cid env` prints every environment variable you can set on the host to change how
the container runs, grouped by area, with each variable's current value or
default and a one-line description. A leading `*` marks the ones set in your
current environment; secret values (e.g. `MCP_GH_BEARER`) are shown as
`<set: hidden>`. Pass a substring to filter by name:

```bash
cid env             # everything
cid env EGRESS      # just the egress-proxy variables
cid env USAGE       # just the ccusage variables
```

It is a terminal mirror of [Environment Variables](environment-variables.md),
which carries the full descriptions and per-variable reference links.

## Putting `cid` on your PATH

`cid` is a self-contained script that resolves its own location, so it works
from anywhere. Symlink it onto your PATH:

```bash
ln -s "$PWD/cid" ~/.local/bin/cid    # or any dir already on $PATH
```

Then `cid domains add foo.com` works from inside any project directory.

## Shell completion

`cid` ships a zsh completion at `completions/_cid`. After `cid ` press Tab for
subcommands; after `cid show ` press Tab for config filenames; after
`cid domains ` or `cid containers ` press Tab for `add` / `rm` / `ls`; and after
`cid domains rm ` / `cid containers rm ` press Tab to list entries already on the
corresponding allowlist.

Install (zsh) by putting the `completions` dir on your `fpath` before
`compinit`, e.g. in `~/.zshrc`:

```zsh
fpath=(/path/to/claude-in-docker/completions $fpath)
autoload -Uz compinit && compinit
```

Or, with Homebrew's zsh, symlink it onto the existing site-functions `fpath`:

```zsh
ln -s "$PWD/completions/_cid" "$(brew --prefix)/share/zsh/site-functions/_cid"
rm -f ~/.zcompdump*
exec zsh
```
