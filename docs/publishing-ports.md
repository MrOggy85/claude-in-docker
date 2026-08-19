# Publishing Ports

By default the container publishes no ports. To expose a server running **inside** it, set
`CLAUDE_PORTS` to a comma-separated list:

```bash
CLAUDE_PORTS="8080" run.sh
# -> host 0.0.0.0:8080 forwards to container :8080
```

Each entry is a `docker run --publish` spec with an optional `/tcp` (default) or `/udp` suffix:

| Entry                       | Effect                                                       |
| --------------------------- | ------------------------------------------------------------ |
| `8080`                      | publish `8080:8080` — host port = container port             |
| `3000:8080`                 | host `3000` → container `8080`                               |
| `127.0.0.1:5000:5000`       | bind the host side to localhost only (not reachable off-box) |
| `9000/udp`                  | UDP instead of TCP                                           |

Multiple ports: `CLAUDE_PORTS="3000:8080, 127.0.0.1:5000:5000, 9000/udp"`. Invalid entries
(non-numeric, out-of-range, unknown protocol, too many `:` fields) are skipped with a warning.

Use a port ≥1024 — the container runs as a non-root user and cannot bind privileged ports.

## Why this needs two steps

`init-firewall.sh` sets the `INPUT` policy to `DROP`. A published port DNATs the host packet into
the container, where it arrives on `INPUT` as `NEW`, so `docker run --publish` **alone** would be
dropped. `run.sh` therefore also hands the container-side ports to the firewall, which adds an
`INPUT ... ACCEPT` rule for each before applying the `DROP` policy. Both happen automatically from
the one `CLAUDE_PORTS` value.

Parsing lives in [`scripts/extra-ports.sh`](../scripts/extra-ports.sh), which produces the
`--publish` flags, the firewall's inbound-port list, and the host endpoint of each mapping.

## Caveats

- **Bind to localhost for anything sensitive.** The bare `8080` and `3000:8080` forms bind the host
  side to `0.0.0.0`, reachable from other machines. Prefix with `127.0.0.1:` to keep it host-local.
- Session volume, container name, and usage tracking are unaffected by published ports.

## Telling the session about the mapping

With `3000:8080`, code in the container reaches its own server on `8080` while the host uses `3000`
— and a browser driven by the [chrome-devtools MCP server](chrome-devtools-mcp.md) runs on the
*host*, so it needs `3000`. The [`sandbox` skill](sandbox-info.md) reports the mapping on demand so
the session doesn't guess.
