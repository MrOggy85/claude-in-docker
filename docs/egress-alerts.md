# Egress Alerts

The most likely compromise here is a malicious npm package that has to phone home. That step is
visible in the proxy's access log — but only to someone reading it. `proxy/watch.sh` reads it for
you and raises a desktop notification the moment a project reaches a host it never has before, or
is denied by the allowlist.

It runs on the **host**, watching `docker logs -f` on the proxy container. A compromised container
can neither see it, kill it, nor edit what it has recorded.

```
>> egress alerts: watching claude-egress-proxy  (pid 41983; cid watch status)
```

`run.sh` starts it alongside the proxy on every run, so it is up whenever a session is, and it
outlives the session. `CLAUDE_EGRESS_ALERTS=0` skips it.

## What fires

| Event | Notification |
| --- | --- |
| New host, allowed | `info` — a banner |
| New host, denied | `alert` — must be dismissed |
| Recorded host, denied again | `alert`, at most once per `CLAUDE_DENY_ALERT_COOLDOWN` (300s) |
| Request denied by a path/method rule | `alert`, titled *DENIED by rule* — same cooldown |
| Origin returned the 403, proxy allowed it | `info`, titled *Upstream refused* — its own cooldown |
| Recorded host, allowed | silent |
| Any of the above, host muted | silent — see [Muting a host](#muting-a-host) |

"New" means this project has never contacted it before.

### Why it was allowed

An allowed first-time host is reported with the allowlist entry that permitted it:

```
New egress host: myrepo-a1b2c3d4e5
cdn-metrics-7f3a.githubusercontent.com via .githubusercontent.com (baseline wildcard)
Review: cid hosts
```

That sorts alerts into two piles. An **exact** entry is a host you typed in yourself. A **wildcard**
(`.githubusercontent.com`) covers the apex and every subdomain, so nobody ever approved *this*
host — the only case where traffic left the box without a host-by-host authorisation behind it.
The source is one of `baseline`, `project`, `browser-baseline` or `browser-project`, matching the
four lists in [egress-proxy.md](egress-proxy.md#allowlists).

The answer comes from `proxy/ext-allowlist.sh --explain`, the same file and the same `match_in_file`
Squid asks for the allow/deny decision, so the grammar has one implementation and cannot drift into
reporting a wrong reason. `watch.sh` calls it on the host, once per newly-seen host: nothing is
added to the request path and `proxy/squid.conf` is untouched.

Three limits, all of them "say nothing" rather than "guess":

- **It is asked after the fact.** A log can be replayed days later, and `--explain` answers from the
  lists as they are *now*. If the entry has since been removed or its
  [`# expires=`](egress-proxy.md#temporary-entries) has lapsed, the alert names nothing.
- **It is host-level.** It reports what makes the host reachable at all. Where several entries cover
  one host, that is the first match in list order, which need not be the entry that authorised any
  particular request.
- **A denial carries none**, by definition — nothing matched.

With provenance available, the watcher could go quiet for exact-entry hosts and speak up only for
wildcard ones. It deliberately does not: that changes what fires, and is its own decision.

### Three 403s, three fixes

A `403` reaching the watcher is one of three things, and the suggested fix differs every time, so
the classifier separates them on two fields rather than on the status alone.

**Whose 403 is it.** Squid's own refusal carries a `DENIED` result code (`TCP_DENIED`,
`TCP_DENIED_ABORTED`) and reached no server, so its hierarchy is `NONE`/`HIER_NONE`. Any other 403
next to a hierarchy naming a real address was *relayed* from the origin: the allowlist passed the
request and the far end refused it — a VPN you are off, a WAF, an expired token. That is not an
egress event, so it notifies at `info` as *Upstream refused* and never mentions `cid domains`;
saying "denied" there sends you to widen an allowlist that was never in the way. An unrecognised
hierarchy counts as a denial, so a Squid format change over-reports rather than hides a real block.

**Which of ours.** Among Squid's own, a `403` on anything but the `CONNECT` is a denial *inside* an
established tunnel, which only a [path or method rule](egress-proxy.md#entry-syntax) produces — the
host itself cleared the CONNECT. That alert says so and points at `cid domains` instead of offering
`cid domains add <host>`, which would widen the entry the rule exists to narrow.

Each kind in one burst stays its own notification, since each carries one command. The upstream
cooldown is a separate map from the denial cooldown: a server that 403s constantly must not be able
to squelch the alert for this project being genuinely denied that same host.

Repeated denials keep alerting because probing the allowlist host by host is the loudest compromise
signal there is — see the fast-fail vector in [attack-vectors.md](attack-vectors.md). The cooldown
only stops a retry loop from flooding the desktop.

Alerts arriving within 2 seconds of each other are coalesced into one notification per project,
urgency and suggested fix, listing up to five hosts. Without that, the first session in a new project — which
legitimately contacts a dozen hosts — would fire a dozen banners.

## Muting a host

Some traffic is neither wanted nor stoppable: telemetry a tool sends with no way to turn it off. The
allowlist already has the right answer — keep denying it — but the denial repeats, and so does the
alert. `cid mute` silences the alert without touching the decision.

```bash
cid mute add http-intake.logs.us5.datadoghq.com   # this project
cid mute add -g .datadoghq.com                    # every project (baseline)
cid mute rm  http-intake.logs.us5.datadoghq.com   # alert about it again
cid mute                                          # the effective list
```

A muted host raises **no** notification of any kind — new, denied, denied by rule, or upstream 403.
What it does not change:

- **The proxy.** `muted-hosts.txt` never leaves the host; Squid does not read it and is not
  restarted. A muted host that was denied stays denied, and one that was allowed stays allowed.
  Muting is not allowing.
- **The record.** It is still appended to `seen-hosts.txt`, so `cid hosts` still shows every host the
  project reached.

One thing it does change: a muted denial is kept out of `denied-hosts.txt`, so
[`cid domains add --denied`](config-cli.md#domains-add--domains-rm) never offers to allow it. Muting
a host is the statement that you do not want it allowed.

The list is `<config-dir>/muted-hosts.txt` plus `projects/<key>/muted-hosts.txt`, one host per line,
a leading `.` matching the apex and every subdomain, `#` comments, and the same
[`# expires=`](egress-proxy.md#temporary-entries) annotation. The
[in-container browser](browser-vnc.md) shares its project's list — there is no separate browser mute
list, since there is nothing here to widen.

The matching is `proxy/ext-allowlist.sh --muted`, the same file and the same `match_in_file` as every
other list, asked once per host per cooldown. So an edit takes effect on a running watcher without a
restart, and a missing or broken helper reads as *not* muted: a failure costs a spurious alert, never
a silent one.

## Notifiers

| Platform | `info` | `alert` |
| --- | --- | --- |
| macOS | `display notification` | `display dialog`, which stays until clicked |
| Linux | `notify-send` | `notify-send -u critical`, which GNOME/KDE never auto-dismiss |

The first of `CLAUDE_NOTIFY_CMD`, `osascript`, `notify-send` wins; with none of them, alerts go only
to the log. `cid watch status` names the one in use.

- macOS may need notification permission for **Script Editor** the first time; a `display dialog`
  needs none.
- `notify-send` needs a session D-Bus. The watcher inherits `DBUS_SESSION_BUS_ADDRESS` from the
  `run.sh` that started it, so a watcher started over ssh has no way to reach your desktop — use
  `CLAUDE_NOTIFY_CMD` or read the log.

`CLAUDE_NOTIFY_CMD` is called as `<cmd> <urgency> <title> <body>`, which is enough for ntfy, Slack,
or `tmux display-message`:

```bash
export CLAUDE_NOTIFY_CMD="$HOME/bin/to-slack"     # $1=info|alert  $2=title  $3=body
```

Every alert is appended to `<config-dir>/egress-alerts.log` whichever notifier ran — that is the
audit trail, and on a headless host it is the whole feature.

```bash
cid watch              # running? which notifier? how many hosts recorded here?
cid watch log 50       # the last 50 alerts
cid watch stop         # ...and start
```

## The record

Each project's hosts live in `<config-dir>/projects/<key>/seen-hosts.txt`, one per line, with the
entry that permitted it as a trailing comment. The watcher appends to it; nothing else reads it.

```
api.anthropic.com                      # allowed by: api.anthropic.com (baseline exact)
cdn-metrics-7f3a.githubusercontent.com # allowed by: .githubusercontent.com (baseline wildcard)
169.254.169.254
```

A bare line is a host with no reason to give — denied, or recorded before this was added. Both forms
read the same, so an existing file keeps working and is never rewritten.

```bash
cid hosts              # what this project has contacted
cid hosts forget       # clear it — every host alerts again
```

Being listed means the host was *seen*, not that it is allowed: a denied host is recorded too, so
that the alert about it does not repeat forever. Use `cid domains` for what is permitted.

`run.sh` does not mount the config dir into the container, so a compromised session cannot read or
edit its own record.

## What this does not do

- **Muting is per host, not per reason.** A muted host is silent for every class of event above.
  There is no way to keep the denial alert and drop the upstream 403, or the reverse.
- **It notifies, it does not block.** The request has already been allowed or denied by the time you
  see the alert. Gating a first-time host on your approval would mean stalling a Squid ACL helper on
  human input — a different and riskier feature.
- **A gap while the watcher is down is silent.** It reattaches within seconds of the proxy being
  recreated, and `run.sh` restarts it every session, but the access log lives in the proxy
  container's writable layer: traffic in a proxy container destroyed before the next session was
  never seen. Persisting the log would close this, at the cost of a permanent record of every URL
  every session fetched.
- **It exits rather than retry forever.** Five attaches that fail immediately (no such container, no
  docker) and it gives up, logging why to `<config-dir>/watcher.log` — a watcher that cannot read
  the proxy is better reported absent by `cid watch status` than left spinning. `run.sh` starts a
  fresh one next session.
- **Provenance is best-effort.** It is derived when the alert fires, not when the request was made,
  so a lapsed or deleted entry leaves the host unexplained rather than misattributed. See [Why it
  was allowed](#why-it-was-allowed).
- **Attribution is self-asserted.** The project key in each log line is the proxy username the
  container sends, and `proxy/auth-ok.sh` accepts any credentials (see
  [egress-proxy.md](egress-proxy.md)). A container could tag its traffic as another project.

## Reading the log yourself

The classifier is a separate verb, so you can run it over any access-log text without Docker or
notifications:

```bash
docker logs claude-egress-proxy | proxy/watch.sh process
# info   myrepo-a1b2c3d4e5   cdn.assets.example.com   new-host   .example.com (baseline wildcard)
# alert  myrepo-a1b2c3d4e5   169.254.169.254          new-host-denied
# info   myrepo-a1b2c3d4e5   api.example.com          upstream-403
```

A fifth field appears only where an entry was named, so it reads the same as before for the rest.
Provenance comes from the host's own allowlists, so `CLAUDE_DOCKER_CONFIG_DIR` decides which ones a
hand-run reads.

It reads Squid's built-in log format positionally: timestamp, result/status, method, URL, username,
hierarchy. Adding a `logformat` directive to `proxy/squid.conf` would break it.

This records what it classifies, so a manual run silences those hosts for the running watcher too.
`cid hosts forget` undoes that.
