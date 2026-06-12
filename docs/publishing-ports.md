# Publishing Ports

By default the container publishes no ports — nothing it listens on is reachable
from the host. To expose a server running **inside** the container (e.g. a dev
web server a workflow starts), set `CLAUDE_PORTS` to a comma-separated list:

```bash
CLAUDE_PORTS="8080" run.sh
# -> host 0.0.0.0:8080 forwards to container :8080
```

Each entry is a `docker run --publish` spec, with an optional `/tcp` (default) or
`/udp` suffix:

| Entry                       | Effect                                                       |
| --------------------------- | ------------------------------------------------------------ |
| `8080`                      | publish `8080:8080` — host port = container port             |
| `3000:8080`                 | host `3000` → container `8080`                               |
| `127.0.0.1:5000:5000`       | bind the host side to localhost only (not reachable off-box) |
| `9000/udp`                  | UDP instead of TCP                                           |

Multiple ports: `CLAUDE_PORTS="3000:8080, 127.0.0.1:5000:5000, 9000/udp"`.
Invalid entries (non-numeric, out-of-range, unknown protocol, too many `:`
fields) are skipped with a warning.

Use a port ≥1024: the container runs as a non-root user and cannot bind
privileged ports (<1024).

## Why this needs two steps

The container runs an outbound firewall (`init-firewall.sh`) whose `INPUT`
policy is `DROP`. A published port works by DNAT'ing the host packet into the
container, where the inbound connection arrives on the `INPUT` chain as `NEW` —
so `docker run --publish` **alone** would be dropped by the firewall. `run.sh`
therefore also passes the container-side ports to the firewall, which opens an
`INPUT ... ACCEPT` rule for each before applying the `DROP` policy. Both happen
automatically from the single `CLAUDE_PORTS` value.

## Caveats

- **Bind to localhost for anything sensitive.** The bare `8080` and `3000:8080`
  forms bind the host side to `0.0.0.0`, reachable from other machines that can
  reach your host. Prefix with `127.0.0.1:` to keep it host-local.
- The session volume, container name, and usage tracking are unaffected by
  published ports.

The parsing lives in [`scripts/extra-ports.sh`](../scripts/extra-ports.sh),
which `run.sh` calls to turn `CLAUDE_PORTS` into `docker run --publish` flags and
the firewall's inbound-port list.
