# Host-Outbound Ports

By default the container's only egress path is the Squid proxy, which filters by
domain (`allowed-domains.txt`). The one exception is **direct** outbound traffic
to the Docker host (`host.docker.internal`): the host is in `NO_PROXY`, so this
traffic bypasses Squid and is governed solely by the in-container firewall
(`init-firewall.sh`), whose `OUTPUT` policy is `DROP`.

`CLAUDE_HOST_OUTBOUND_PORTS` is the allowlist of host ports the container may
connect **out** to. Each opened port becomes one `OUTPUT` accept rule to the
host's IP.

```bash
CLAUDE_HOST_OUTBOUND_PORTS="8080" ./run.sh
# -> container may connect out to host.docker.internal:8080

CLAUDE_HOST_OUTBOUND_PORTS="8080,5432,9000/udp" ./run.sh
```

Each comma-separated entry is `PORT` or `PORT/PROTO`, where `PROTO` is `tcp`
(default) or `udp`. Invalid entries (non-numeric, out of range 1–65535, or an
unknown protocol) are skipped with a warning.

## Ports merged automatically

Two ports do not need listing here:

- **`SOUND_PORT`** (default `4767`) is always merged, so the
  [sound server](sound-effects.md) works out of the box.
- **`DOCKER_BRIDGE_PORT`** (default `9334`) is merged when
  `CLAUDE_DOCKER_BRIDGE=1`, i.e. only when the
  [docker bridge](docker-bridge.md) is enabled.

Setting `CLAUDE_HOST_OUTBOUND_PORTS` adds ports **on top of** those:

```bash
# firewall opens 4767 (sound) AND 8080
CLAUDE_HOST_OUTBOUND_PORTS="8080" ./run.sh
```

The [chrome-devtools bridge](chrome-devtools-mcp.md) is the one that is *not*
merged — open `9333` yourself.

## Direction: out vs in

This is the opposite direction from [`CLAUDE_PORTS`](publishing-ports.md):

| Goal | Direction | Firewall chain | Variable |
| --- | --- | --- | --- |
| Host reaches a server in the container | host → container | `INPUT` | `CLAUDE_PORTS` |
| Container reaches a server on the host | container → host | `OUTPUT` | `CLAUDE_HOST_OUTBOUND_PORTS` (+ `SOUND_PORT`, `DOCKER_BRIDGE_PORT`) |

## Caveats

- **The host must be reachable via the Docker host gateway.** `host.docker.internal`
  resolves to the host's gateway IP, not its loopback. A host service bound to
  `0.0.0.0` is reachable; one bound only to `127.0.0.1` generally is not.
- **These connections are unfiltered.** Because host traffic bypasses Squid, the
  domain allowlist does not apply — the port rule is the only control. Each port
  you open is unrestricted access to that host port. Whatever listens there is
  responsible for its own authorization: of the three bundled bridges only the
  [docker bridge](docker-bridge.md) authenticates its callers. See
  [Known Attack Vectors](attack-vectors.md#host-bridges-on-host-outbound-ports-accepted-trade-off-opt-in).
- **Not general outbound.** This only affects traffic to the Docker host. All
  other outbound traffic still goes through Squid and its domain allowlist; see
  [Centralized Egress Proxy](egress-proxy.md).
