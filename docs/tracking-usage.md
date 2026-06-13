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

`ccusage` is baked into the container image, so **no host Node/npm is required**. `usage.sh`
uses a host-installed `ccusage` if you happen to have one (a fast path that skips the container);
otherwise it runs the copy inside the image. The script can be re-run at any time — it only reads
from the volumes, and `ccusage` deduplicates by message ID, so usage is never double-counted.

The in-image run is fully **network-isolated** (`--network none --offline`): `ccusage`'s only
network use is downloading the LiteLLM model-pricing table to turn tokens into costs, and
`--offline` serves that from a snapshot bundled into the image at build time. The one tradeoff is
that the snapshot can lag the very newest models, which would then report `$0.00` until you
rebuild the image — though records that already carry Claude Code's precomputed cost stay correct.
Set `CLAUDE_USAGE_ONLINE=1` to fetch live pricing instead when you need it.

See [usage-sync.md](usage-sync.md) for how the sync works, what is (and isn't) copied,
and the requirements and caveats (archive protection, volume pruning, project relabeling).
