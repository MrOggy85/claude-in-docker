# In-Container Browser

`CLAUDE_BROWSER=1` puts a real Chromium, `playwright-cli` and an X server inside the container, and
`cid vnc` shows you what the session is doing with them.

```bash
CLAUDE_BROWSER=1 run.sh
# in the session:  playwright-cli open http://localhost:3000 --headed
# on the host:     cid vnc          -> opens http://127.0.0.1:49155/vnc.html?...
```

Off by default: the layer adds roughly 700 MB, and most sessions never need a browser.

## Why in the container

The [chrome-devtools MCP bridge](chrome-devtools-mcp.md) runs Chrome on the **host**. It is still
supported and unchanged, but it is no longer the default: use it when the task needs your real
profile, a host-only service, or your own visible window. For project work, running the browser
here buys three things:

- **The allowlist applies.** Browser traffic goes through Squid under this project's Squid login,
  like every other request. The host bridge's port 9333 bypasses Squid entirely.
- **Files land where the session can see them.** `playwright-cli screenshot --filename=x.png`
  writes into the repo mount, with no path translation across
  [`mounts.txt`](chrome-devtools-mcp.md#file-outputs).
- **It works on Linux hosts.** The host bridge ships a macOS launchd plist.

The cost is image size, and the egress noise described under [Caveats](#caveats).

## Driving it

`playwright-cli` is [`@playwright/cli`](https://github.com/microsoft/playwright-cli).
`entrypoint.sh` runs `playwright-cli install --skills` on first start so the session gets upstream's
own reference guides. It runs it **from `$HOME`**, because the installer writes to
`./.claude/skills` relative to the current directory — from the default workdir that would drop
untracked files into your project. `$HOME/.claude` is the session volume, so they persist there.

`run.sh` claims `$HOME/.claude/skills` for the host UID first, in a throwaway root container. The
sandbox skill's bind mount sits under that directory, so docker creates it as `root:root` in the
volume, and the installer runs as you; without the claim it fails with `EACCES`. A failed claim is
a warning, not a fatal: it costs the reference guides, not the browser.

The install runs **in the background**, and its exit status is ignored. `playwright-cli install
--skills` finishes its work in about 0.2s and then never exits, so in the foreground it holds the
session at `[firewall] ready` until the timeout expires — on every start, because `timeout` then
reports a failure for a run that actually succeeded and the sentinel is never written. Success is
therefore judged by `~/.claude/skills/playwright-cli` existing, not by the exit code.

The CLI is chosen over `@playwright/mcp` deliberately: an MCP server costs a tool schema in every
context window, and upstream recommends the CLI for coding agents on that basis. Nothing stops you
adding the MCP server to `mcp-servers.json` as well; it is not wired up here.

## Egress

Squid requires proxy authentication and the **username selects the allowlist**
(`proxy/squid.conf`). Chromium cannot carry credentials in `--proxy-server`, and would sit at a 407
with no one to answer it. Playwright answers the 407 itself when given `proxy.username`/`password`,
and its JSON config file is the only place those can be expressed — no environment variable covers
them.

So `run.sh` generates `<projects-dir>/<key>/playwright-cli.config.json` each run, mounts it at
`/etc/claude/playwright-cli.config.json`, and [`scripts/playwright-cli.sh`](../scripts/playwright-cli.sh),
installed as `/usr/local/claude-bin/playwright-cli`, injects `--config`. That directory is ahead of
npm's global bin on `PATH`, which is why the wrapper is not simply in `/usr/local/bin`. The file
holds no secret: the password is the literal `x`, as in `run.sh`'s own `PROXY_URL` — the username is
what carries identity.

The wrapper injects the flag on **`open` and `attach` only**. `--config` is not a global option:
every other subcommand exits with `Unknown option: --config`. Those two are also the only ones that
launch a browser (`goto` on a closed session answers "please run open first"), so narrowing to them
loses nothing.

`PLAYWRIGHT_MCP_CONFIG` would be tidier and does work, but a project's own
`.playwright/cli.config.json` in the working directory **wins over it** — which would silently drop
the proxy settings and leave the browser unable to reach anything, since direct egress is dropped by
`init-firewall.sh`. An explicit `--config` outranks that file, so the flag is the only mechanism the
repo being worked on cannot override. It is appended rather than prepended, so it also outranks a
`--config` the session passes itself.

`localhost`, `127.0.0.1` and `::1` are in Playwright's `proxy.bypass`, so the project's own dev
server is always reachable without costing an allowlist entry. Playwright does not read `NO_PROXY`,
hence the separate list.

### The browser has its own list

The username is `<project-key>-browser`, not the plain key. `proxy/ext-allowlist.sh` strips the
suffix to find the project directory and adds two more files to the ones it consults:

| Login | Lists consulted |
| --- | --- |
| `<key>` (the agent) | baseline `allowed-domains.txt` + the project's `allowed-domains.txt` |
| `<key>-browser` | those two, **plus** baseline `browser-domains.txt` + the project's `browser-domains.txt` |

Strictly additive, so the agent's reach is always a subset of the browser's. This is the point: a
page needs dozens of CDN, font and telemetry hosts, and without the split every one you allowed to
make it render would also become reachable by the agent's own `curl`, `npm` and `uv`. No real
project can claim the suffix, because `project_key()` always ends in 10 hex characters.

```bash
cid domains --browser add cdn.jsdelivr.net   # browser only
cid domains --browser                        # all four lists, agent's marked as shared
cid domains -g --browser add fonts.gstatic.com   # shared browser baseline
```

`--browser` is orthogonal to `-g`: one picks the consumer, the other the scope, and all four
combinations work.

### Adding what a page actually needs

One page is dozens of denials, so `proxy/watch.sh` records every host it refused to
`<projects-dir>/<key>-browser/denied-hosts.txt` and `--denied` adds them in one go:

```bash
cid hosts                                # what was refused, agent and browser separately
cid domains --browser add --denied       # allow all of it
cid domains --browser add --denied --for 2h   # ...and let it lapse
```

The alert log distinguishes the two identities by login, so a denial reads as the browser's or the
agent's without guessing. `cid hosts forget` clears both records for both identities.

### Methods

`cid domains --browser add` defaults entries to `GET,HEAD`, which `cid domains add` does not.
Browsing is read-shaped, and the hosts a page needs are exactly the ones not to hand a request body
to: a wildcard CDN domain is attacker-registrable, and a telemetry endpoint accepts arbitrary
payloads by design. Pass `--method ALL` for an entry that genuinely needs to POST, or name the
methods yourself.

Squid enforces method rules only on decrypted requests, so a host in `skip-decryption.txt` cannot
carry one. The helper already refuses to splice a host reachable *only* through a scoped entry,
rather than letting the rule degrade to host-level.

## TLS

Chromium reads the NSS database at `~/.pki/nssdb`, not `/etc/ssl/certs/ca-certificates.crt`, so the
image seeds the egress CA there with `certutil` in addition to the system store. That layer sits
below the CA install in the `Dockerfile`, so [rotating the CA](tls-inspection.md) re-seeds it.

If a bumped host still fails with `ERR_CERT_AUTHORITY_INVALID`, add
`--ignore-certificate-errors-spki-list=<base64 SHA-256 of the CA SPKI>` to `launchOptions.args`,
which trusts exactly that CA. Never `ignoreHTTPSErrors` or a bare `--ignore-certificate-errors`:
those disable validation for every host, including the ones the proxy is not intercepting.

## Watching it: `cid vnc`

| Command | Effect |
| --- | --- |
| `cid vnc` / `cid vnc start` | start x11vnc + websockify in the container, print and open the URL |
| `cid vnc stop` | stop both; the display and the browser keep running |
| `cid vnc status` | is the display up, is noVNC up, what is the URL |
| `cid vnc url` | print the URL only |

`-C <dir>` picks the project; `--container <name>` picks between concurrent sessions and
tab-completes from the containers actually running (zsh, via `completions/_cid`). The suffix in
each name is what the [status line](host-path-statusline.md) shows as `⬢`, so you can match a
terminal to a container by eye.

### Which session am I looking at?

`cid vnc` resolves from the working directory: `project_key(cwd)` → `docker ps --filter
label=cid.project-key=<key>`. With several containers on one project it refuses and lists them
rather than guessing. `start` and `status` both print what they resolved, because the container
name is random and the URL is a bare port, so neither identifies the session on its own:

```
>> noVNC is up  (display :99)
>> project: my-app-3f9c1ab2de  (from /Users/you/code/my-app)
>> container: claude-my-app-1a2b3c4d
>> url: http://127.0.0.1:49155/vnc.html?autoconnect=1&...
```

### The screen is blank

That is the normal idle state, not a fault. `entrypoint.sh` starts Xvfb and a window manager with
the container, but **nothing is drawn until a browser is launched**. `cid vnc` says so when it sees
an empty display:

```
>> the screen will be blank: no browser is open on that display yet
  Ask the session to open a page, or run in the container:
    playwright-cli open <url>
```

`cid vnc status` reports the same thing as a separate line from the display and noVNC checks, so
"the plumbing works" and "there is something to see" are never confused.

The split is not arbitrary. Xvfb starts with the container because Chromium inherits `DISPLAY` at
launch, so it cannot be deferred. x11vnc and websockify only attach to an existing display, so they
start on demand and cost nothing in a session nobody watches. The **port** is reserved at container
start either way — Docker cannot publish a port on a running container.

`cid` itself never calls `docker`; all of it lives in [`scripts/vnc.sh`](../scripts/vnc.sh), the
same split `cid watch` makes with `proxy/watch.sh`.

### Finding the container

`run.sh` gives every container a random name suffix and records it nowhere, so it now also sets
`--label cid.project-key=<key>` and `scripts/vnc.sh` resolves through `docker ps --filter`. `--rm`
makes the label self-cleaning.

### The password

`cid vnc start` generates `<projects-dir>/<key>/vnc.pass` (mode 600) on first use and loads it into
x11vnc with `-storepasswd`, so the plaintext never appears in the container's argv. noVNC hands over
full keyboard and mouse control of a browser holding whatever the session logged into; loopback-only
publishing is not enough on its own. x11vnc binds `127.0.0.1:5900` inside the container, so
websockify on the published `6080` is the only way in.

## Caveats

- **Egress is still noisy, just contained.** A real page is dozens of denials the first time.
  `cid domains --browser add --denied` is the answer, and the separate list means none of it
  reaches the agent. Driving your own `localhost` dev server avoids the whole cycle.
- **A redirect crosses a host boundary, and each hop needs allowlisting.** Allowing
  `cdn.jsdelivr.net` and loading it gives a Squid 403, because it `301`s to `www.jsdelivr.com` —
  a different host, so a different allowlist decision. The browser shows the error page for the
  *second* hop while the address bar shows the first, which reads like the entry did not work. Add
  the destination too, or check `cid hosts` for what was actually refused.
- **An old proxy container has no browser baseline mount.** `proxy/up.sh` adds it, so a proxy
  started before this feature will ignore `browser-domains.txt` until you run
  `make proxy-down && make proxy-up`. Per-project lists are unaffected: those come from the
  `projects/` mount, which already exists.
- **`--no-sandbox`.** Chromium's renderer sandbox needs user namespaces this container does not
  have. The container is the boundary instead.
- **Pinning `CLAUDE_VNC_PORT` blocks concurrent sessions.** The default is `0`, meaning Docker
  assigns a free host port, because a fixed one makes the *second* browser-enabled container
  anywhere on the machine die with `Bind for 127.0.0.1:6080 failed: port is already allocated` —
  not just a second session on the same project. `cid vnc` asks `docker port` for the real number,
  so nothing needs to know it in advance. Pin it only for a stable URL, one session at a time; the
  guard warns when you do.
- **Memory.** Chromium is hungry against the 25%-of-host default. Exit 137 or a bare `Killed` means
  the cap — raise `CLAUDE_MEMORY`, see [Resource Limits](resource-limits.md). `--shm-size=512m` is
  set automatically because Docker's 64 MB `/dev/shm` crashes Chromium on its own.
- **`--init`.** Added with the browser: `entrypoint.sh` `exec`s, so `claude` is PID 1 and reaps
  nothing, and a browser's orphans would accumulate against `CLAUDE_PIDS_LIMIT`.

## Verification

```bash
CLAUDE_BROWSER=1 run.sh
```

In the session, confirm the wrapper and the display, then load an allowlisted page:

```bash
command -v playwright-cli          # -> /usr/local/claude-bin/playwright-cli
echo "$DISPLAY"                    # -> :99
playwright-cli open https://registry.npmjs.org --headed && playwright-cli snapshot
```

On the host, `cid vnc` should open noVNC showing that page. A host that is *not* allowlisted should
fail and raise the usual [egress alert](egress-alerts.md) — that is the proof the browser is
behind Squid rather than beside it.

## Troubleshooting

### `cid vnc` says no session is running

Nothing `run.sh` started is up in that directory. The label is set on **every** container it starts,
browser or not, so this never means "the browser was left off" — a container started by hand is
also invisible, since it carries no label.

### `<container> was started without CLAUDE_BROWSER=1`

`cid vnc` found this project's session and it simply has no browser. Relaunch it with the flag;
nothing is broken. This is distinct from the Xvfb failure below, which `cid vnc` tells apart by
reading `CLAUDE_BROWSER_ON` out of the container.

### The session hangs after `[firewall] ready`

Fixed, but the symptom of an image built before that fix: `playwright-cli install --skills` ran in
the foreground and never exits on its own, so startup stalled for the full timeout every time.
Rebuild. To confirm that is what you are seeing, the install log will end with
`✅ Skill installed` while the sentinel `~/.claude/.playwright-skills-installed` is still absent —
success that was recorded as failure. Touching that file by hand suppresses it until you rebuild.

### `could not install the playwright-cli skills`

Non-fatal: the browser works, you just lack upstream's reference guides for driving it.
`entrypoint.sh` runs `playwright-cli install --skills` once per session volume, bounded so it can
never wedge startup. The reason is in `~/.claude/playwright-skills-install.log` inside the
container. Retry by hand with `playwright-cli install --skills`; the sentinel
`~/.claude/.playwright-skills-installed` is what stops it re-running once it succeeds.

An `EACCES: permission denied, mkdir '/home/dev/.claude/skills/...'` in that log is the root-owned
parent described above. Relaunching the session fixes it: `run.sh` makes the claim on every
browser-enabled run. To repair it without one, using the volume name `run.sh` prints as
`session volume`:

```sh
docker run --rm --user 0:0 --entrypoint sh -v "<session volume>:/v" claude-code:local \
  -c "chown -R $(id -u):$(id -g) /v/skills"
```

### `Owner of /tmp/.X11-unix should be set to root`

Cosmetic, and only on an image built before that directory was baked in. Xvfb prefers its socket
directory root-owned but continues regardless, so the display is fine. A rebuild removes the
message. Not to be confused with the fatal version below.

### `no X display on :99`

Xvfb failed at container start. `entrypoint.sh` warns and continues rather than costing you the
session, so the warning is in the session's first few lines. Usually the image predates the
browser layer — check `CLAUDE_BROWSER=1` was set for the run that *built* it, since the flag is
part of the context hash.

The older form of this was `_XSERVTransmkdir: ERROR: euid != 0, directory /tmp/.X11-unix will not
be created`: Xvfb refuses to create its own socket directory as a non-root user, and nothing else
had. Both the image and `entrypoint.sh` now create it, so this needs a rebuild rather than a fix.

### Every page fails, but `curl` works

Two causes, in order of likelihood.

**A stale proxy.** Squid execs `ext-allowlist.sh` once, at container start, so a proxy running from
before the browser feature is still deciding with the old helper — which does not know the
`-browser` login and refuses everything the shared baseline grants. Compare the two identities from
inside the container:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -x "http://<key>:x@squid:3128"         https://registry.npmjs.org/
curl -s -o /dev/null -w '%{http_code}\n' -x "http://<key>-browser:x@squid:3128" https://registry.npmjs.org/
```

`200` then `403` is exactly this. Fix with `make proxy-down && make proxy-up`.

**The config is not reaching the browser.** Check `command -v playwright-cli` resolves to
`/usr/local/claude-bin/playwright-cli`, and that `open` was not passed a `--proxy-server` of its
own. A `--config` passed by the session is harmless, since the wrapper appends its own after it.

### `ERR_CERT_AUTHORITY_INVALID`

The NSS seeding did not take. See [TLS](#tls) for the SPKI-pin fallback.
