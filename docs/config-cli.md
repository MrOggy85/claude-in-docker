# The `cid` config CLI

`cid` inspects and edits the claude-in-docker configuration. All config lives
outside the repo, in the config dir (`~/.config/claude-in-docker/` by default —
see [Environment Variables](environment-variables.md)). `cid` finds those files
for you, prints them, and edits the egress allowlists in place so you don't have
to open `allowed-domains.txt` by hand.

## Commands

```bash
./cid list                    # config dir + every global file (present/missing) + projects dir
./cid show <file>             # print a global config file (credentials are never dumped)
./cid project [dir]           # per-project key, config dir, and which overrides exist
./cid domains [dir]           # effective allowlist = baseline + this project's additions
./cid domains add <host>...   # add host(s) to the allowlist
./cid domains rm  <host>...   # remove host(s) from the allowlist
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
`cid domains ` press Tab for `add` / `rm` / `ls`; and after `cid domains rm `
press Tab to list hosts already on an allowlist.

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
