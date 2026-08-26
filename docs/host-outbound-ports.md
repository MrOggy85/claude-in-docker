# Host-Outbound Ports

The container's only egress path is the Squid proxy, which filters by domain. The one exception is
**direct** traffic to the Docker host (`host.docker.internal`): the host is in `NO_PROXY`, so this
bypasses Squid and is governed solely by `init-firewall.sh`, whose `OUTPUT` policy is `DROP`.

`CLAUDE_HOST_OUTBOUND_PORTS` is the allowlist of host ports the container may connect **out** to.
Each opened port becomes one `OUTPUT` accept rule to the host's IP.

```bash
CLAUDE_HOST_OUTBOUND_PORTS="8080" ./run.sh
# -> container may connect out to host.docker.internal:8080

CLAUDE_HOST_OUTBOUND_PORTS="8080,5432,9000/udp" ./run.sh
```

Each entry is `PORT` or `PORT/PROTO` (`tcp` default, or `udp`). Invalid entries — non-numeric, out
of range 1–65535, unknown protocol — are skipped with a warning.

## Ports merged automatically

Three ports need no listing, and `CLAUDE_HOST_OUTBOUND_PORTS` adds **on top of** them:

- **`SOUND_PORT`** (default `4767`) is always merged, so the [sound server](sound-effects.md) works
  out of the box.
- **`DOCKER_BRIDGE_PORT`** (default `9334`) is merged only when `CLAUDE_DOCKER_BRIDGE=1`.
- **`CHROME_DEVTOOLS_MCP_PORT`** (default `9333`) is merged only when `CLAUDE_CHROME_DEVTOOLS=1` —
  see the [chrome-devtools bridge](chrome-devtools-mcp.md).

## Direction: out vs in

This is the opposite direction from [`CLAUDE_PORTS`](publishing-ports.md):

| Goal | Direction | Firewall chain | Variable |
| --- | --- | --- | --- |
| Host reaches a server in the container | host → container | `INPUT` | `CLAUDE_PORTS` |
| Container reaches a server on the host | container → host | `OUTPUT` | `CLAUDE_HOST_OUTBOUND_PORTS` (+ `SOUND_PORT`, `DOCKER_BRIDGE_PORT`) |

The [`sandbox` skill](sandbox-info.md) reports both lists on demand, labelling the ports `run.sh`
knows the purpose of.

## Caveats

- **The host must be reachable via the Docker host gateway.** `host.docker.internal` resolves to the
  host's gateway IP, not its loopback: a service bound to `0.0.0.0` is reachable, one bound only to
  `127.0.0.1` generally is not.
- **These connections are unfiltered.** Host traffic bypasses Squid, so the domain allowlist does
  not apply and the port rule is the only control. Whatever listens there is responsible for its own
  authorization — of the three bundled bridges only the [docker bridge](docker-bridge.md)
  authenticates callers. See [Known Attack
  Vectors](attack-vectors.md#host-bridges-on-host-outbound-ports-accepted-trade-off-opt-in).
- **Not general outbound.** Only traffic to the Docker host is affected; everything else still goes
  through Squid — see [Centralized Egress Proxy](egress-proxy.md).
