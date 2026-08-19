# Chrome DevTools MCP

Let Claude Code drive a real Chrome through the
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) server — navigate
pages, run scripts, take screenshots, inspect the DOM and network.

## Why a host-side server?

The container has no browser and no display, and `chrome-devtools-mcp` is a **stdio** server that
launches and drives a real Chrome. So — like the [sound server](sound-effects.md) and the [docker
bridge](docker-bridge.md) — it runs on the **host**, reached over HTTP via `host.docker.internal`.

Since the server speaks stdio only, a **zero-dependency Node bridge**
(`chrome-devtools-mcp/host-chrome-devtools-mcp.js`, ~120 lines, node built-ins only) translates MCP's
Streamable HTTP transport to stdin/stdout: it spawns `chrome-devtools-mcp`, forwards each HTTP
request to its stdin, and streams the matching JSON-RPC responses back as Server-Sent Events. It
listens on `0.0.0.0:9333` so the Docker host gateway is reachable (`127.0.0.1` is not), and traffic
to `host.docker.internal` bypasses Squid — see [Host-Outbound Ports](host-outbound-ports.md).

```
HOST:  Chrome  <-- chrome-devtools-mcp (stdio, --isolated)
              <-- host-chrome-devtools-mcp.js  -->  http://0.0.0.0:9333/mcp
CONTAINER:  claude --mcp-config  -->  http://host.docker.internal:9333/mcp
```

The bridge keeps a **single active session**: a new `initialize` replaces the previous one, so at
most one Chrome runs at a time. It is not a multi-client gateway.

## Setup

### 1. Start the bridge on your host

```bash
./chrome-devtools-mcp/host-chrome-devtools-mcp.sh
```
Or install it as a launchd service so it starts automatically:
```bash
cp chrome-devtools-mcp/com.user.claude-chrome-devtools-mcp.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-chrome-devtools-mcp.plist
launchctl kickstart -k gui/$(id -u)/com.user.claude-chrome-devtools-mcp
```
The plist assumes the repo is at `~/code/claude-in-docker`; edit `ProgramArguments` if not. To reload
after editing, `launchctl bootout gui/$(id -u)/com.user.claude-chrome-devtools-mcp` first. Logs go to
`/tmp/claude-chrome-devtools-mcp.log`.

### 2. Add the server to `mcp-servers.json`

In the config dir (or a per-project `<config-dir>/projects/<key>/mcp-servers.json`), inside
`mcpServers`:
```json
"chrome-devtools": {
   "type": "http",
   "url": "http://host.docker.internal:9333/mcp"
}
```

### 3. Open the port at launch

```bash
CLAUDE_HOST_OUTBOUND_PORTS="9333" ./run.sh
```
This stacks additively with `SOUND_PORT` (the firewall opens `4767,9333`). Set it in your `claude`
alias or a per-project `.claude-env` so you don't forget — see [Per-Project Launch
Config](per-project-env.md).

## Port and Chrome flags

- **Port** defaults to `9333`; override with `CHROME_DEVTOOLS_MCP_PORT` (read by the bridge). Unlike
  `SOUND_PORT` it is **not** auto-merged into the firewall allowlist, so changing it means keeping
  three places in sync: `CHROME_DEVTOOLS_MCP_PORT`, the `url` in `mcp-servers.json`, and
  `CLAUDE_HOST_OUTBOUND_PORTS`.
- **Chrome flags** — the bridge launches with `--isolated` (clean throwaway profile) and
  `--no-usage-statistics` (no Google telemetry). Add others (`--channel`, `--executablePath`,
  `--no-performance-crux`) via space-separated `CHROME_DEVTOOLS_MCP_EXTRA_ARGS`; see
  `npx -y chrome-devtools-mcp@latest --help`.
- **Server command / version** — by default the bridge fetches the server per launch with
  `npx -y chrome-devtools-mcp@latest`. Pin with `CHROME_DEVTOOLS_MCP_VERSION`, or bypass `npx`
  entirely by pointing `CHROME_DEVTOOLS_MCP_CMD` at a pre-installed binary — which also skips the
  launch-time registry round-trip (see [Troubleshooting](#troubleshooting)).

## File outputs

Tools taking a `filePath` (`take_screenshot`, `performance_start_trace`, `take_heapsnapshot`,
`evaluate_script`) write to the **host** filesystem where the bridge runs, not the container
workspace, and unless the client negotiates the MCP `roots` capability those writes are confined to
the OS temp dir. Inline results (screenshots and snapshots returned in the tool response) flow back
to Claude normally; only explicit `filePath` saves land host-side.

## Security

Read this before enabling. Same caveats as [Host-Outbound
Ports](host-outbound-ports.md#caveats), amplified because the port carries browser automation:

- **Bypasses the egress allowlist entirely.** Traffic to `host.docker.internal` skips Squid, so
  `allowed-domains.txt` does **not** apply to port `9333`. The firewall port rule is the only control.
- **The port is a full browser-automation endpoint.** The host Chrome can navigate anywhere, execute
  arbitrary JavaScript, and read/screenshot pages. Exposing it hands the in-container agent an
  unfiltered egress and exfiltration channel (e.g. `https://attacker.example/?leak=<secret>`) outside
  this project's core control. A deliberate hole — enable it knowingly.
- **`--isolated` is not a network control.** It gives Chrome a clean profile with no logged-in
  accounts or cookies; it does not restrict which sites Chrome can reach.
- **Runs as the host user**, so Chrome can reach host-local and LAN services the container cannot.
- **No authentication.** The bridge accepts any `initialize` from anything that reaches port `9333`,
  and binds `0.0.0.0` by necessity. Contrast the [docker bridge](docker-bridge.md), which requires a
  per-project bearer token.
- **Telemetry leaves the host, unfiltered.** `chrome-devtools-mcp` sends usage statistics to Google
  and its performance tools send trace URLs to the CrUX API — host egress bypassing Squid. The bridge
  passes `--no-usage-statistics`; add `--no-performance-crux` via `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` to
  suppress the CrUX calls too.
- **Enable only when needed.** `launchctl bootout` the service (or drop the port) when not using it.

## Verification

1. Start the bridge; tail `/tmp/claude-chrome-devtools-mcp.log` for
   `streamable-HTTP bridge on 0.0.0.0:9333/mcp`.
2. Confirm it binds all interfaces, not loopback — expect `*:9333`; a `127.0.0.1:9333` result means
   the container cannot reach it:
   ```bash
   lsof -nP -iTCP:9333 -sTCP:LISTEN
   ```
3. Confirm the endpoint answers on the host. Any HTTP response proves it is up (a bare `GET` returns
   `404 no session`), versus connection-refused:
   ```bash
   curl -sv http://localhost:9333/mcp
   ```
   Or run the full handshake (initialize → `tools/list` → teardown) against the real server; it
   should print a session id and the tool list:
   ```bash
   ./chrome-devtools-mcp/smoke-test.sh
   ```
4. Add the `mcp-servers.json` entry, then launch `CLAUDE_HOST_OUTBOUND_PORTS="9333" ./run.sh`. The
   `init-firewall.sh` output should show an `OUTPUT` accept rule for `9333` alongside `4767`.
5. From a container shell, `curl -sv http://host.docker.internal:9333/mcp` should get a response.
6. In Claude Code, `/mcp` should list `chrome-devtools` as connected with its tools enumerated
   (Chrome launches on first tool use).
7. Ask Claude to navigate to `https://example.com` and take a snapshot; a real Chrome should appear
   on the host and the tool should return page content.

## Troubleshooting

### `npm error code E401` / auth failures with a private npm registry

**Symptom.** The bridge listens fine, but the first Chrome tool call fails and the log shows an npm
auth error such as `npm error code E401 Incorrect or missing password`.

**Cause.** By default the bridge runs `npx -y chrome-devtools-mcp@latest`, resolving through your
**default** npm registry. If `~/.npmrc` points at a private registry authenticating with a token from
an env var — e.g.

```
registry=https://registry.example.com/npm/
//registry.example.com/npm/:_authToken=${MY_NPM_TOKEN}
```

— then `${MY_NPM_TOKEN}` must exist in the environment npm runs in. It does in your interactive
shell, but **not under launchd**, which gives a minimal environment with no shell rc. Note `@latest`
re-resolves against the registry on **every** session start, so pre-warming the npx cache does not
avoid the auth round-trip.

**Fix A — pre-install the server, skip the registry at launch (recommended).** Install once from your
interactive shell, then point the bridge at the binary so it never invokes `npx`:

```sh
npm i -g chrome-devtools-mcp            # token comes from your shell env
which chrome-devtools-mcp               # e.g. ~/.nvm/versions/node/<ver>/bin/chrome-devtools-mcp
```

Add to the launchd plist's top-level `<dict>` (then `bootout` + `bootstrap` to reload):

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>CHROME_DEVTOOLS_MCP_CMD</key>
    <string>chrome-devtools-mcp</string>
</dict>
```

The bare name resolves because the wrapper sources nvm and puts that version's bin on `PATH`; use an
absolute path to avoid depending on the nvm default. Trade-off: you now update the server manually.

**Fix B — give the token to launchd, keep `@latest`.** Export it in the wrapper
`host-chrome-devtools-mcp.sh` before it `exec`s node, reading from the Keychain or a mode-`600` file:

```sh
export MY_NPM_TOKEN="$(security find-generic-password -s my-npm-token -w)"
```

Avoid the plist's `EnvironmentVariables` (world-readable plaintext) or `launchctl setenv` (leaks into
the whole launchd session).

The same cause and fixes apply to the [sound server](sound-effects.md) only if you give it private
package dependencies; by default it has none.
