# Tracking Usage (ccusage)

`ccusage` reads Claude Code's transcript logs, but in this setup they live inside per-project
Docker volumes rather than your host `~/.claude`, so running `npx ccusage` on the host reports
`No usage data found`. `usage.sh` bridges the gap: it copies the cost-only records out of every
`claude-*` volume into a single host archive (`~/.claude-docker-usage` by default) and runs
`ccusage` over the combined set. `run.sh` also refreshes the archive automatically after each
session.

Run it from this repository's checkout (unlike `claude`, which runs from your project
directories):

```bash
cd ~/code/claude-in-docker
./usage.sh                # monthly breakdown across all projects (default)
./usage.sh daily          # any ccusage subcommand or flags are passed through
./usage.sh monthly --json
```

The report runs `ccusage` on the host, so it needs to be available there. Install and audit it
once with `npm i -g ccusage` (requires Node.js); `usage.sh` otherwise falls back to `npx`. The
script can be re-run at any time — it only reads from the volumes, and `ccusage` deduplicates by
message ID, so usage is never double-counted.

See [usage-sync.md](usage-sync.md) for how the sync works, what is (and isn't) copied,
and the requirements and caveats (archive protection, volume pruning, project relabeling).
