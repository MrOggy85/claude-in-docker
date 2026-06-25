# Per-Project Launch Config with `.claude-env`

The environment variables this tool reads — `CLAUDE_MOUNTS`, `CLAUDE_PORTS`,
`CLAUDE_VOLUME_PATHS`, and so on (see
[Environment Variables](environment-variables.md)) — are read from the shell
that launches `run.sh`. That makes them easy to set globally in your `claude`
shell function, but every project tends to want *different* values: one repo
needs a sibling checkout mounted, another needs a dev-server port published, a
third needs a registry token.

This recipe keeps those per-project differences in a small, gitignored
`.claude-env` file **in each target repo**, sourced automatically at launch. You
never edit `run.sh` and never commit anything project-specific into this tool.

It builds on two mechanisms already documented elsewhere:

- the **`claude` shell function** from the [README](../README.md#shell-profile-alias), and
- **forwarding secrets from the launch shell** via bare-name `.env` lines (see
  [Passing Environment Variables](passing-env-vars.md#forwarding-a-secret-from-the-launch-shell-instead)).

## How it works

1. A globally-ignored filename means `.claude-env` is never committed in *any*
   repo, without touching each repo's `.gitignore`.
2. Your `claude` function exports the baseline (shared mounts, secrets pulled
   from the macOS Keychain), then `source`s `.claude-env` from the current
   directory if one is present, then runs `run.sh`.
3. Because the function body runs in a **subshell** `( … )`, all those exports
   live only for that one launch — they never leak into your interactive shell.

## Step 1 — ignore `.claude-env` globally

Set a global gitignore (if you don't already have one) and add `.claude-env` to
it. This applies to every repo on your machine, so a per-project `.claude-env`
can never be accidentally committed:

```bash
git config --global core.excludesFile ~/.gitignore   # if not already set
printf '%s\n' '.claude-env' >> ~/.gitignore
```

## Step 2 — expand your `claude` function

Replace the simple alias from the README with one that sets shared defaults,
sources a per-project `.claude-env`, and launches. The outer `( … )` subshell is
load-bearing: it scopes every `export` to this single invocation.

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

In a repo that needs extra mounts and a published port, add (this file stays
local — it's globally ignored):

```bash
# .claude-env
export CLAUDE_MOUNTS="$CLAUDE_MOUNTS,~/code/tvh"   # append to the shared default
export CLAUDE_PORTS="6999,7000"
```

Note the `$CLAUDE_MOUNTS,` prefix: because the function exports the shared
default *before* sourcing this file, you can extend it rather than replace it.
Omit the prefix to override it entirely.

Now `claude` from that directory mounts `~/obsidian/v` **and** `~/code/tvh`, and
publishes ports 6999/7000 — while `claude` from any other directory gets just
the shared defaults.

## Getting the secrets into the container

Exporting `NEXUS_NPM_TOKEN` / `MCP_GH_PERSONAL` in the function only puts them in
the launch shell. They reach the container by two different routes:

- **`MCP_GH_BEARER`** is forwarded automatically — `run.sh` passes it with an
  explicit `--env MCP_GH_BEARER` flag (and the
  [read-only guard](environment-variables.md) aborts the run if that token is
  write-capable).
- **`NEXUS_NPM_TOKEN` and `MCP_GH_PERSONAL`** are *not* forwarded by `run.sh`.
  List them as bare names (no `=`) in your gitignored `.env` next to `run.sh`,
  and `docker --env-file` pulls each from the launch shell:

  ```bash
  # .env
  NEXUS_NPM_TOKEN
  MCP_GH_PERSONAL
  ```

  This keeps the values in the Keychain and the launch-shell environment only —
  never on disk. See
  [Passing Environment Variables](passing-env-vars.md#forwarding-a-secret-from-the-launch-shell-instead).

## Why this layout

- **Nothing project-specific lives in this tool.** `run.sh`, `.env`, and the
  `claude` function are stable; the moving parts sit in each project's
  `.claude-env`.
- **Secrets never hit disk.** They flow Keychain → launch shell → container.
- **No leakage into your shell.** The subshell discards every export when the
  session ends.
- **Per-project, not global.** Mounts and ports are scoped to the repo that
  actually needs them, so unrelated sessions stay minimal.

> **Security note:** `.claude-env` is sourced by your shell, so it can run
> arbitrary code at launch. The global gitignore stops *you* from committing your
> own, but it does **not** protect you from a cloned repo that already tracks a
> `.claude-env` — gitignore only affects untracked files, so a committed one is
> still checked out to disk and would be sourced on your next launch. Treat an
> unexpected `.claude-env` the same way you'd treat any executable a stranger
> handed you: inspect it before running `claude` in that directory.
