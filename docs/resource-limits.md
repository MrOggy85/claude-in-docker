# Resource Limits

Every container this project starts is capped on memory, CPU and process count. Defaults come from
the Docker host and need no configuration:

| Variable | Default | `docker run` flag |
| --- | --- | --- |
| `CLAUDE_MEMORY` | 25% of the host's RAM, rounded down to whole GiB, floor `2g` | `--memory` |
| `CLAUDE_MEMORY_SWAP` | same as `CLAUDE_MEMORY`, i.e. swap off | `--memory-swap` |
| `CLAUDE_CPUS` | host cores − 2; unset on a 1–2 core host | `--cpus` |
| `CLAUDE_PIDS_LIMIT` | `2048` | `--pids-limit` |

The host figures are read once per run from `docker info` (`.MemTotal` / `.NCPU`) — the daemon's
view, which on Docker Desktop is the VM's slice rather than the machine's RAM, and the VM is what a
limit has to fit inside. If that reading fails the memory and CPU defaults are skipped with a
warning instead of guessed.

Set any variable to override, or to `0` / `off` / `none` / `unlimited` to drop that one cap:

```bash
CLAUDE_MEMORY=12g run.sh          # a build that needs more
CLAUDE_CPUS=unlimited run.sh      # no CPU quota; memory and pids still capped
```

A malformed value aborts the run. Silently falling back to "no limit" is the failure this exists to
prevent.

## Why cap at all

Without a cgroup limit a container's memory counts against the host total, and the kernel's OOM
killer picks its victim by `oom_score` across every process on the box — roughly, the largest. The
container that spiked need not be the largest, so a long-lived 3 GiB one dies to make room for a
runaway 2 GiB one. `systemd-oomd`, which acts on cgroup pressure, can mis-target the same way. With
`--memory` the limit is reached inside the offending cgroup and the kill is scoped to it.

It is also the one host-level denial of service the rest of the sandbox does not address: a
malicious `postinstall` cannot reach the network ([egress proxy](egress-proxy.md)) or the host disk
([volume-backed paths](volume-backed-paths.md)), but it could allocate until the machine thrashed.
See [Known Attack Vectors](attack-vectors.md#host-resource-exhaustion-mitigated).

**The trade-off:** the cgroup OOM killer kills the largest process *in that container*, which is
often `claude` itself. Since containers run with `--rm`, that session ends. You are trading a
bystander's death for the offender's — better, but not free. The transcript lives in the
per-project session volume, so relaunching and `claude --resume` picks it back up.

## Swap is off by default

`--memory-swap` is the memory+swap **total**, so setting it equal to `--memory` gives the container
no swap at all.

Swap is disk the kernel lends out as substitute RAM: rather than fail an allocation it writes idle
pages out, at roughly a thousandth of RAM's speed. Two things make that worse than the kill it
replaces:

- **The cap is per container; the disk is not.** A container paging heavily saturates the host's
  I/O queue, and everything else that touches disk — your editor, another container's compiler —
  waits behind it. That is the bystander damage the memory cap exists to prevent, arriving through
  the disk instead of the OOM killer, and it is what a "frozen" machine usually is: I/O starvation,
  not exhausted RAM.
- **It mostly delays the kill.** A runaway is normally a leak, not a job that would finish given one
  more gigabyte, so it grinds through the swap at disk speed and dies anyway — minutes later, with
  the host unusable in between. Those minutes are *thrashing*: each page read back in evicts one
  needed moments later, so nearly all the time goes into moving pages rather than running code.

The cost is real — a job that genuinely needed a little more than its cap now dies instead of
finishing slowly. Prefer raising the RAM. The cushion is there if you want it anyway:

```bash
CLAUDE_MEMORY=4g CLAUDE_MEMORY_SWAP=6g run.sh   # 4g RAM + 2g swap
```

Swap accounting has to be enabled for the kernel to honour this. Under cgroup v2 it is; under cgroup
v1 it needs `swapaccount=1` on the kernel command line, and without it Docker prints `Your kernel
does not support swap limit capabilities` and ignores the flag — leaving swap unbounded.

## Hitting a limit

- **Memory.** The kernel `SIGKILL`s the biggest process in the container: exit 137, or a bare
  `Killed`, with nothing from the program itself. Node 16+ sizes its default heap from the cgroup
  limit (via `uv_get_constrained_memory`), so V8 usually hits its own GC ceiling first; a native
  allocation, or a `--max-old-space-size` above the cap, still gets killed.
- **CPU.** Throttling only, never a kill. Note `nproc` reports the host's core count and ignores
  `--cpus`, so `make -j$(nproc)` oversubscribes the quota.
- **Processes.** A spawn fails with `EAGAIN` / `Resource temporarily unavailable`.

The [`sandbox` skill](sandbox-info.md) reports this container's three ceilings on demand, so the
session reads an exit 137 as policy and tells you which variable to raise rather than retrying the
same command.

## The egress proxy

The shared Squid container is capped too, at a fixed `1g` (no swap) and 512 processes — its
workload is known and bounded, so it takes no share of the host. Override with
`CLAUDE_EGRESS_MEMORY`. It is
the longest-lived container here, so a leak in it is the most likely way this project takes a host
down; `--restart unless-stopped` brings it back if the cap ever fires, and the
[alert watcher](egress-alerts.md) reconnects to the new instance on its own.

Derivation, validation and the token emission live in
[`scripts/resource-limits.sh`](../scripts/resource-limits.sh); the proxy's are inline in
[`proxy/up.sh`](../proxy/up.sh).
