# Per-Project Launch Config with `.claude-env`

The variables this tool reads — `CLAUDE_MOUNTS`, `CLAUDE_PORTS`, `CLAUDE_VOLUME_PATHS`, etc. (see
[Environment Variables](environment-variables.md)) — come from the shell that launches `run.sh`.
That is easy to set globally in your `claude` function, but every project wants *different* values:
one repo needs a sibling checkout mounted, another a dev-server port, a third a registry token.

This recipe keeps those differences in a small, gitignored `.claude-env` **in each target repo**,
sourced automatically at launch — no edits to `run.sh`, nothing project-specific committed here. It
builds on the **`claude` shell function** from the [README](../README.md#shell-profile-alias) and
**bare-name `.env` lines** for [forwarding
secrets](passing-env-vars.md#forwarding-a-secret-from-the-launch-shell-instead).

## Step 1 — ignore `.claude-env` globally

A globally-ignored filename means it can never be accidentally committed in *any* repo, without
touching each repo's `.gitignore`:

```bash
git config --global core.excludesFile ~/.gitignore   # if not already set
printf '%s\n' '.claude-env' >> ~/.gitignore
```

## Step 2 — expand your `claude` function

Set shared defaults, source a per-project `.claude-env`, then launch. The outer `( … )` subshell is
load-bearing: it scopes every `export` to this one invocation, so nothing leaks into your
interactive shell.

```bash
function claude {
(
  # --- shared defaults for every project ---
  export CLAUDE_MOUNTS="~/obsidian/v:rw"

  # secrets read from the Keychain at launch (never written to disk);
  # see the README for the keychain_get helper
  export NEXUS_NPM_TOKEN="$(keychain_get NEXUS_NPM_TOKEN)"
  export MCP_GH_PERSONAL="$(keychain_get PERSONAL_GITHUB_TOKEN)"
  export MCP_GH_BEARER="$(keychain_get WORK_GITHUB_TOKEN)"

  # --- per-project overrides, if the current repo has them ---
  [[ -f .claude-env ]] && source .claude-env

  ~/code/claude-in-docker/run.sh "$@"
)
}
```

## Step 3 — drop a `.claude-env` in a project

```bash
# .claude-env
export CLAUDE_MOUNTS="$CLAUDE_MOUNTS,~/code/tvh"   # append to the shared default
export CLAUDE_PORTS="6999,7000"
```

The `$CLAUDE_MOUNTS,` prefix extends the shared default rather than replacing it, since the function
exports it *before* sourcing this file; omit the prefix to override entirely.

`claude` from that directory now mounts `~/obsidian/v` **and** `~/code/tvh` and publishes 6999/7000,
while other directories get just the shared defaults.

## Getting the secrets into the container

Exporting a variable in the function only puts it in the launch shell. Two routes onward:

- **`MCP_GH_BEARER`** is forwarded automatically by `run.sh` (`--env MCP_GH_BEARER`), and the
  [read-only guard](environment-variables.md) aborts if the token is write-capable.
- **Everything else** is not. List them as bare names (no `=`) in your config-dir `.env`, and
  `docker --env-file` pulls each from the launch shell:

  ```bash
  # .env
  NEXUS_NPM_TOKEN
  MCP_GH_PERSONAL
  ```

  Values stay in the Keychain and launch-shell environment only, never on disk. See [Passing
  Environment
  Variables](passing-env-vars.md#forwarding-a-secret-from-the-launch-shell-instead).

## Why this layout

- **Nothing project-specific lives in this tool** — `run.sh`, `.env`, and the `claude` function stay
  stable; the moving parts sit in each project's `.claude-env`.
- **Secrets never hit disk** — Keychain → launch shell → container.
- **No leakage into your shell** — the subshell discards every export when the session ends.
- **Per-project, not global** — mounts and ports are scoped to the repo that needs them.

> **Security note:** `.claude-env` is sourced by your shell, so it can run arbitrary code at launch.
> The global gitignore stops *you* from committing your own, but it does **not** protect you from a
> cloned repo that already tracks one — gitignore only affects untracked files, so a committed
> `.claude-env` is still checked out and would be sourced on your next launch. Inspect an unexpected
> one before running `claude` in that directory.
