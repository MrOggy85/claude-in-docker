# Tracking Usage (ccusage)

`ccusage` reads Claude Code's transcript logs, but here they live in per-project Docker volumes
rather than the host `~/.claude`, so `npx ccusage` on the host reports `No usage data found`.
`usage.sh` copies the cost-only records out of every `claude-*` volume into one host archive
(`~/.claude-docker-usage` by default) and runs `ccusage` over the combined set. `run.sh` refreshes
the archive after each session.

Run it from this repository's checkout, not from a project directory:

```bash
cd ~/code/claude-in-docker
./usage.sh                # monthly breakdown across all projects (default)
./usage.sh daily          # any ccusage subcommand or flags are passed through
./usage.sh monthly --json
```

`ccusage` is baked into the image, so **no host Node/npm is required** — a host-installed `ccusage`
is used as a fast path if present. Re-run it freely: it only reads from the volumes, and `ccusage`
deduplicates by message ID.

The in-image run is **network-isolated** (`--network none --offline`). `ccusage` otherwise fetches
the LiteLLM model-pricing table to convert tokens to costs; `--offline` serves that from a snapshot
baked in at build time. The snapshot can lag the newest models, which then report `$0.00` until you
rebuild — records carrying Claude Code's precomputed cost stay correct either way. Set
`CLAUDE_USAGE_ONLINE=1` to fetch live pricing.

See [usage-sync.md](usage-sync.md) for how the sync works, what is copied, and the caveats
(archive protection, volume pruning, project relabeling).
