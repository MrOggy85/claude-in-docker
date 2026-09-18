#!/usr/bin/env bash
#
# Egress alert watcher: notifies the moment a project contacts a host it has
# never contacted before, or is denied by the allowlist. Runs on the HOST, so a
# compromised container can neither see it nor silence it — the proxy's access
# log is the one channel a phone-home cannot avoid. See docs/egress-alerts.md.
#
# It reads `docker logs -f` on the proxy container (proxy/entrypoint.sh relays
# the Squid access log to stdout for exactly this) and needs no mount, no state
# inside the proxy and no code inside any container. Each line already names its
# project: run.sh authenticates to Squid as the project key, which Squid logs as
# the username field.
#
# A host on the project's mute list is classified exactly as before and recorded
# exactly as before, but raises no notification: the answer for telemetry that
# cannot be turned off at the source, and that the allowlist should keep refusing.
# See `cid mute` and docs/egress-alerts.md.
#
# Verbs:
#   start (default)  idempotent — start the daemon unless it is already running
#   stop             kill it
#   status           is it running, which notifier, where the records are
#   process          the classifier: access-log lines on stdin, alert lines on
#                    stdout. No docker, no notifications — this is what
#                    test/watch.bats drives.
#
# The daemon is long-lived on purpose: it outlives every session, so nothing else
# would ever replace one running superseded code. `start` therefore stamps the
# hash of the watcher's own files into the pidfile and restarts a watcher whose
# stamp no longer matches, and `stop` kills every daemon rather than only the one
# the pidfile names — an orphan is invisible to `status` and notifies forever.
#
# Env: CLAUDE_EGRESS_PROXY_NAME, CLAUDE_DENY_ALERT_COOLDOWN, CLAUDE_NOTIFY_CMD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/watch.sh"

# shellcheck source=../scripts/paths.sh disable=SC1091
source "${REPO_DIR}/scripts/paths.sh"
# shellcheck source=../scripts/colors.sh disable=SC1091
source "${REPO_DIR}/scripts/colors.sh"
# shellcheck source=../scripts/notify.sh disable=SC1091
source "${REPO_DIR}/scripts/notify.sh"
color_init 1

CONFIG_DIR="$(config_dir)"
PROJECTS_DIR="$(projects_dir)"
PROXY_NAME="${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}"

PIDFILE="${CONFIG_DIR}/watcher.pid"        # line 1 the pid, line 2 the code stamp
DAEMON_LOG="${CONFIG_DIR}/watcher.log"      # the watcher's own stdout/stderr
ALERT_LOG="${CONFIG_DIR}/egress-alerts.log" # one line per alert, written by notify()
# How far into the access log the daemon has got, so a restart resumes instead of
# replaying. Only the daemon sets CID_WATCH_POS; a hand-run `process` leaves this
# untouched and reads the whole stream, exactly as before.
POSFILE="${CONFIG_DIR}/watcher.pos"

# Passed as a trailing argument to every process of this watcher and carried in
# its awk's argv, so `ps` says which config dir a process serves. Nothing reads
# the value: it is there so that stopping one config dir's watcher cannot kill
# another's — including a real one running from this same checkout while the
# test suite drives a redirected config dir. See _watcher_procs.
WATCHER_TAG="@${CONFIG_DIR}"

# One alert per denied host per this many seconds. Repeated denials are the
# loudest compromise signal there is, so they are never squelched outright — but
# a tight retry loop must not be able to flood the desktop either.
COOLDOWN="${CLAUDE_DENY_ALERT_COOLDOWN:-300}"
# Seconds of silence that end a burst. The first session in a project legitimately
# contacts a dozen hosts; coalescing turns that into one notification instead of
# twelve, at the cost of this much delay on a lone event.
COALESCE=2

# ---------------------------------------------------------------------------
# process — classify access-log lines
# ---------------------------------------------------------------------------
#
# Squid has no logformat directive (proxy/squid.conf), so its built-in `squid`
# format applies:
#   %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt
# The fields that matter: 1 timestamp, 4 result/status, 7 URL, 8 username.
#
# awk rather than bash: this needs associative arrays for the seen-set and the
# per-host deny cooldown, and macOS ships bash 3.2 (no `declare -A`). The clock
# is field 1, the log's own timestamp — systime() is a gawk extension absent from
# mawk and BSD awk, and a log-derived clock also makes the tests deterministic.
_process() {
  # Read by the system() call in record() and the pipe in explain(): passing the
  # path through the environment means the shell expands it, so a config dir
  # containing spaces or quotes needs no escaping here.
  export CID_PROJECTS_DIR="${PROJECTS_DIR}"
  # The same files proxy/up.sh mounts into the proxy, named on this side. up.sh
  # fails outright without the first and creates the second, so both exist
  # whenever a proxy is up. CID_HELPER is a test-only override, like the helper's
  # own BASELINE/PROJECTS_DIR — deliberately undocumented in `cid env`.
  export CID_BASELINE="${CONFIG_DIR}/allowed-domains.txt"
  export CID_BROWSER_BASELINE="${CONFIG_DIR}/browser-domains.txt"
  # The one list nothing in the proxy reads: muting is a property of the ALERT,
  # not of the decision, so it never leaves the host. Absent = nothing is muted.
  export CID_MUTED_BASELINE="${CONFIG_DIR}/muted-hosts.txt"
  export CID_HELPER="${CID_HELPER:-${SCRIPT_DIR}/ext-allowlist.sh}"
  # `watcher` is never read by the program: it is there so that this awk — which
  # outlives its own `watch.sh process` parent, since bash waits on it rather
  # than exec'ing it — can still be recognised as part of a watcher in ps output.
  # See _watcher_procs.
  awk -v projdir="${PROJECTS_DIR}" -v cooldown="${COOLDOWN}" \
      -v posfile="${CID_WATCH_POS:-}" -v watcher="${SELF} ${WATCHER_TAG}" '
    # The resume point: the log timestamp everything up to and including which
    # has already been classified. `docker logs --tail all` replays the whole log
    # on every attach, and while the persistent seen-set makes that harmless for
    # a first-time host, a DENIAL has only the in-memory cooldown behind it — so
    # without this a restart re-notifies every denial in the log, one per host per
    # cooldown of log time. Empty posfile (any hand-run) disables it entirely.
    BEGIN { if (posfile != "" && (getline resume < posfile) > 0) resume += 0; close(posfile) }

    # Record it. Written on every alert and, failing that, every POS_EVERY
    # seconds of log time — cheap, since both are rare next to the line rate. A
    # line sharing the recorded millisecond is NOT reprocessed, which is the one
    # thing this trades away for never repeating an alert.
    function savepos(t) {
      if (posfile == "" || t <= saved) return
      printf "%.3f\n", t > posfile
      close(posfile)   # the portable flush, as in record()
      saved = t
    }

    function seenfile(key) { return projdir "/" key "/seen-hosts.txt" }

    # Load a project s recorded hosts on first sight of that project. getline
    # returns -1 when the file cannot be opened, which is how a brand-new project
    # (header still to write) is told apart from one with an empty list.
    function loadseen(key,   f, line, rc) {
      if (key in loaded) return
      loaded[key] = 1
      f = seenfile(key)
      while ((rc = (getline line < f)) > 0) {
        # Strip the comment FIRST: a recorded host carries its provenance as a
        # trailing one, and squeezing that into the key would make every host
        # read as unseen and alert forever. Doing it here also handles the
        # whole-line comments in the header, so no substr() test is needed.
        sub(/#.*/, "", line)
        gsub(/[ \t\r]/, "", line)
        if (line != "") seen[key SUBSEP line] = 1
      }
      close(f)
      fresh[key] = (rc < 0)
    }

    # Append a host to the project s record. mkdir -p because a project that has
    # never run still has no config dir, and awk cannot create one. close() after
    # every write: it is the portable flush (fflush(file) is not universal).
    function record(key, host, why,   f) {
      f = seenfile(key)
      if (fresh[key]) {
        # key is guarded to [a-z0-9-] below, so it is safe unquoted; the dir
        # comes from the environment so the shell quotes it.
        system("mkdir -p \"$CID_PROJECTS_DIR/" key "\"")
        print "# Hosts this project has contacted, recorded by proxy/watch.sh." > f
        print "# Delete a line (or the file) to be alerted about it again: cid hosts forget" >> f
        fresh[key] = 0
      }
      # With no provenance, a bare host — byte-identical to what this wrote
      # before the entry was ever reported, so old files and new ones interleave.
      if (why == "") print host >> f
      else           printf "%-38s # allowed by: %s\n", host, why >> f
      close(f)
      seen[key SUBSEP host] = 1
    }

    # WHICH allowlist entry makes this host reachable, for the alert below. Asks
    # proxy/ext-allowlist.sh rather than matching anything here: the leading-dot
    # wildcard, "# expires=" and the method/path grammar all live in its
    # match_in_file, and a second copy would drift into reporting the WRONG
    # reason — worse than reporting none. Fills two globals because awk cannot
    # return a pair, and that keeps it to one fork per host.
    #
    # Only the paths travel through the environment, so the shell quotes them;
    # key and host are interpolated, safe because both cleared the charset gates
    # below before anything used them. The helper reads the printf, never awk s
    # own stdin — which is the docker logs stream, so dropping that prefix would
    # silently eat the log.
    function explain(key, host,   cmd, line, n, a) {
      EXPLAIN_WHY = ""
      EXPLAIN_FULL = ""
      # echo, not printf: this whole awk program is single-quoted in the shell,
      # so a literal quote here would end it. key and host cleared the charset
      # gates below, so neither can carry a $, a backtick or a backslash out of
      # these double quotes.
      cmd = "echo \"" key " CONNECT " host " - -\" | " \
            "BASELINE=\"$CID_BASELINE\" BROWSER_BASELINE=\"$CID_BROWSER_BASELINE\" " \
            "PROJECTS_DIR=\"$CID_PROJECTS_DIR\" sh \"$CID_HELPER\" --explain 2>/dev/null"
      if ((cmd | getline line) <= 0) line = ""
      close(cmd)   # unconditional: mawk and BSD awk cap concurrently open pipes
      # A missing, old or broken helper lands here as an empty or short line, and
      # "none" means the lists no longer explain the host (it may have been
      # allowed by an entry since removed or expired). All of them report NO
      # reason rather than a wrong one, which leaves the output byte-identical
      # to a watcher without this feature.
      n = split(line, a, "\t")
      if (n < 4 || a[1] == "none" || a[1] == "") return
      EXPLAIN_FULL = a[4] " (" a[1] " " a[2] ")"
      # The alert gets the entry s HOST, not the whole entry: _flush joins hosts
      # with commas and a method list carries its own. It is also why no "*" can
      # reach notify() — that lives in the path half, which stays in the file.
      EXPLAIN_WHY = a[3] " (" a[1] " " a[2] ")"
      gsub(/[,\t]/, " ", EXPLAIN_WHY)
    }

    # Has the user muted this host — "I know, stop telling me"? Same helper and
    # the same match_in_file as everything else, so the wildcard and expiry
    # grammar keeps one implementation here too. Only a clean "muted" counts: a
    # missing, old or broken helper reads as NOT muted, so a failure costs a
    # spurious alert rather than a silent one. See docs/egress-alerts.md.
    #
    # Guarded by the same gates that decide whether anything is said at all (see
    # mayalert below), so a retry loop forks this once per cooldown, not once per
    # request — and asking per alert rather than caching is what lets `cid mute
    # add` take effect on a running watcher.
    function muted(key, host,   cmd, line) {
      cmd = "echo \"" key " CONNECT " host " - -\" | " \
            "MUTED_BASELINE=\"$CID_MUTED_BASELINE\" " \
            "PROJECTS_DIR=\"$CID_PROJECTS_DIR\" sh \"$CID_HELPER\" --muted 2>/dev/null"
      if ((cmd | getline line) <= 0) line = ""
      close(cmd)
      return (line ~ /^muted\t/)
    }

    # Is <map>[k] past its cooldown (or unset)? The three per-host rate limits
    # below all ask this; the caller stamps the map, because a muted host must be
    # stamped without alerting.
    function due(map, k, now) {
      return (!(k in map) || now - map[k] >= cooldown)
    }

    # The hosts WE refused, kept apart from seen-hosts.txt so `cid domains add
    # --denied` has an exact list to work from. The alert log cannot serve: it
    # coalesces to five hosts plus a count, which is lossy exactly when a bulk
    # add is wanted. Deduped in memory, so a retry loop appends once per run.
    # Bare hosts ONLY, unlike seen-hosts.txt: cid feeds these lines straight to
    # `domains add`, so a trailing comment would corrupt the entry written. A
    # denial has no permitting entry to name anyway.
    function record_denied(key, host,   f) {
      if ((key SUBSEP host) in wrotedeny) return
      wrotedeny[key SUBSEP host] = 1
      f = projdir "/" key "/denied-hosts.txt"
      system("mkdir -p \"$CID_PROJECTS_DIR/" key "\"")
      print host >> f
      close(f)
    }

    # The 5th field is present only when an entry was named. Keeping it optional
    # rather than writing "-" means every line this produced before still looks
    # exactly the same, hand-run or piped.
    function alert(urgency, key, host, reason, why) {
      if (why == "") printf "%s\t%s\t%s\t%s\n", urgency, key, host, reason
      else           printf "%s\t%s\t%s\t%s\t%s\n", urgency, key, host, reason, why
      fflush()   # the reader is a pipe; without this a burst sits in the buffer
      savepos(TS)   # never say this twice, whatever happens to the daemon next
    }

    # Squid runs with -d1, so its own diagnostics share this stream. An
    # access-log line always has all ten fields.
    NF < 10 { next }
    {
      if (posfile != "" && $1 + 0 <= resume) next   # handled before a restart
      key = $8
      if (key == "-") next                      # the 407 challenge, before auth
      if (key !~ /^[a-z0-9][a-z0-9-]*$/) next   # same key guard as ext-allowlist.sh

      host = $7
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", host)   # scheme
      sub(/\/.*$/, "", host)                            # path (bumped requests)
      sub(/:[0-9]+$/, "", host)                         # port (CONNECT lines)
      sub(/\.$/, "", host)                              # FQDN root
      host = tolower(host)
      # Must look like a host. Rejects Squid placeholders such as
      # "error:transaction-end-before-headers", and is the first of two gates on
      # what can reach the notifier.
      if (host !~ /^[a-z0-9][a-z0-9._-]*$/) next

      status = $4
      if (status ~ /\/407$/) next               # auth challenge, not a decision
      TS = $1 + 0                               # what savepos() records

      # A 403 is OURS only if Squid produced it. TCP_DENIED (and
      # TCP_DENIED_ABORTED) is the result code for its own refusal, and such a
      # line reached no upstream, so its hierarchy is NONE/HIER_NONE. Any other
      # 403 was RELAYED from the origin: the allowlist passed the request and the
      # server at the far end refused it — a VPN, a WAF, an expired token. Those
      # must not be reported as an egress block, which sends the user to widen an
      # allowlist that was never in the way. An unrecognised hierarchy falls to
      # the denial side, so a Squid format change over-reports rather than hides
      # a real block.
      hier = $9
      sub(/\/.*$/, "", hier)
      contacted = (hier != "" && hier != "-" && hier != "NONE" && hier != "HIER_NONE")
      is403    = (status ~ /\/403$/)
      denied   = (is403 && (status ~ /DENIED/ || !contacted))
      upstream = (is403 && !denied)
      # A denial on anything but the CONNECT is one INSIDE an established tunnel,
      # which only a path or method rule produces (the host cleared the CONNECT).
      # The two need opposite fixes, so they are told apart here rather than both
      # suggesting "allow this host" — which for a rule denial would widen the
      # entry the rule exists to narrow. See docs/egress-proxy.md.
      byrule = (denied && $6 != "CONNECT")
      ts = $1 + 0

      loadseen(key)
      isnew = !((key SUBSEP host) in seen)
      # Would this line produce anything at all — an alert, or a first record of
      # a refusal? Only then is the mute list worth a fork, and only then does
      # the answer change what happens. Every arm here is itself rate-limited, so
      # a tight retry loop asks once per cooldown.
      mayalert = isnew \
        || (denied && !((key SUBSEP host) in wrotedeny)) \
        || (denied && due(lastdeny, key SUBSEP host, ts)) \
        || (upstream && due(lastup, key SUBSEP host, ts))
      ismuted = mayalert ? muted(key, host) : 0
      # Independent of the isnew/cooldown branches below: those decide whether to
      # NOTIFY, this records the fact. A denial squelched by the cooldown is
      # still a host the user may want to allow. A MUTED one is not — this file
      # is what `cid domains add --denied` reads, and the user muting a host is
      # the statement that they do not want it allowed.
      if (denied && !ismuted) record_denied(key, host)

      if (isnew) {
        # Only the allowed case: a denial has no matching entry by definition, so
        # asking would be a guaranteed-empty fork on the noisy path.
        EXPLAIN_WHY = ""; EXPLAIN_FULL = ""
        if (!denied) explain(key, host)
        # Recorded even when muted: seen-hosts.txt is the record of what was
        # contacted, not of what was reported. Muting silences the alert, it does
        # not edit the history.
        record(key, host, EXPLAIN_FULL)
        if (!ismuted) {
          if (byrule)      alert("alert", key, host, "denied-by-rule")
          else if (denied) alert("alert", key, host, "new-host-denied")
          else             alert("info",  key, host, "new-host", EXPLAIN_WHY)
        }
        if (denied) lastdeny[key SUBSEP host] = ts
      } else if (denied) {
        # Stamped before the mute test, so a muted host in a retry loop asks the
        # helper once per cooldown rather than once per request.
        if (due(lastdeny, key SUBSEP host, ts)) {
          lastdeny[key SUBSEP host] = ts
          if (!ismuted) alert("alert", key, host, byrule ? "denied-by-rule" : "denied")
        }
      }

      # The origin refused it, not us — worth saying, since the failure looks
      # identical from inside the container, but it is not a security event and
      # never raises the urgency. Its OWN cooldown map: sharing lastdeny would let
      # a server that 403s constantly silence the alert for this project actually
      # being denied that host, which is the one that matters. Independent of the
      # isnew branch above, so a first contact that is refused says both things.
      if (upstream) {
        if (due(lastup, key SUBSEP host, ts)) {
          lastup[key SUBSEP host] = ts
          if (!ismuted) alert("info", key, host, "upstream-403")
        }
      }

      # Nothing was said about this line, so nothing needs re-saying — but a
      # quiet stretch should still not be replayed. 5 seconds of log time, so an
      # idle watcher writes almost never and a busy one writes once in thousands
      # of lines.
      if (ts - saved >= 5) savepos(ts)
    }
  '
}

# ---------------------------------------------------------------------------
# notify loop — coalesce alert lines into notifications
# ---------------------------------------------------------------------------

# Buffer of pending "urgency<TAB>key<TAB>host<TAB>reason[<TAB>why]" lines. A
# global because bash 3.2 has no namerefs.
_BUF=()

# Turn the buffer into one notification per (project, urgency, fix), listing the
# distinct hosts. "fix" splits the three reasons that carry different advice
# apart — a host denial, a rule denial, and an origin's own 403 — since one
# notification carries one suggested command. Every other reason shares the
# "host" fix, so this groups exactly as before for them.
_flush() {
  (( ${#_BUF[@]} )) || return 0
  local grouped
  grouped="$(printf '%s\n' "${_BUF[@]}" | awk -F'\t' '
    { fix = "host"
      if ($4 == "denied-by-rule")    fix = "rule"
      else if ($4 == "upstream-403") fix = "upstream"
      k = $1 "\t" $2 "\t" fix
      if (!((k SUBSEP $3) in seen)) {
        seen[k SUBSEP $3] = 1
        # Provenance rides with its host, NOT in the grouping key: a first
        # session legitimately reaches a dozen hosts through a dozen entries, and
        # grouping on it would bring back the banner storm coalescing prevents.
        item = $3
        if ($5 != "") item = item " via " $5
        hosts[k] = hosts[k] (hosts[k] == "" ? "" : ",") item
        n[k]++
      } }
    END { for (k in hosts) printf "%s\t%d\t%s\n", k, n[k], hosts[k] }')"
  _BUF=()

  local urgency key fix count hosts
  while IFS=$'\t' read -r urgency key fix count hosts; do
    [[ -n "${urgency}" ]] || continue
    _emit "${urgency}" "${key}" "${fix}" "${count}" "${hosts}"
  done <<< "${grouped}"
}

# Titles and hints stay inside notify()'s charset (ASCII, no angle brackets or
# dashes it would strip), so what the user reads is what is written here.
_emit() {  # <urgency> <key> <fix: host|rule|upstream> <count> <csv-hosts>
  local urgency="$1" key="$2" fix="$3" count="$4" csv="$5" title body hint suffix=''
  if [[ "${fix}" == upstream ]]; then
    # Squid relayed the origin's own 403. Nothing was blocked here, so this must
    # not read as a denial or point at `cid domains` — the allowlist is not the
    # thing to change. Note the missing apostrophes: notify() strips them.
    title="Upstream refused: ${key}"
    hint="The proxy allowed this. The server refused it. Check VPN, credentials, or the rules at the far end."
    suffix=' 403'
  elif [[ "${urgency}" == alert && "${fix}" == rule ]]; then
    # The host IS allowed — a path or method rule refused the request inside the
    # tunnel. Suggesting `domains add HOST` here would undo that rule, so don't.
    title="Egress DENIED by rule: ${key}"
    hint="The host is allowed, a path or method rule refused it. Review: cid domains"
    (( count == 1 )) && hint="${hint} (or silence it: cid mute add ${csv})"
  elif [[ "${urgency}" == alert ]]; then
    title="Egress DENIED: ${key}"
    # Name the host in the fix when there is exactly one — that is the command
    # to paste, not a template to fill in. The second half is the other answer to
    # a repeating denial: keep denying it, stop saying so. Only on the two alert
    # classes — an info banner is not what anyone wants silenced.
    if (( count == 1 )); then hint="Allow it: cid domains add ${csv} (or silence it: cid mute add ${csv})"
    else                      hint="Allow one: cid domains add HOST"
    fi
  elif (( count > 1 )); then
    title="${count} new egress hosts: ${key}"
    hint="Review: cid hosts"
  else
    title="New egress host: ${key}"
    hint="Review: cid hosts"
  fi
  # ${suffix} is the status for the classes where "why" is not in the title.
  body="$(printf '%s' "${csv}" | tr ',' '\n' | head -5 | awk -v s="${suffix}" '{print $0 s}')"
  (( count > 5 )) && body="${body}"$'\n'"...and $((count - 5)) more"
  notify "${urgency}" "${title}" "${body}"$'\n'"${hint}"
}

# Read alert lines from stdin until the producer closes, flushing after COALESCE
# seconds of quiet. read -t returns >128 on timeout and 1 at EOF — the only
# signal telling "burst over" apart from "log stream gone". The timeout applies
# only while something is buffered, so an idle watcher blocks instead of waking
# every COALESCE seconds.
_notify_loop() {
  local line rc
  local -a targs=()
  while :; do
    if (( ${#_BUF[@]} )); then targs=(-t "${COALESCE}"); else targs=(); fi
    if IFS= read -r ${targs[@]+"${targs[@]}"} line; then
      _BUF+=("${line}")
      # Cap the buffer so a sustained flood still notifies rather than growing.
      (( ${#_BUF[@]} >= 100 )) && _flush
    else
      rc=$?
      _flush
      (( rc > 128 )) || return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# daemon / lifecycle
# ---------------------------------------------------------------------------

# How many attaches may fail immediately before giving up. A watcher that cannot
# read the proxy after this many tries is broken, and one that retries forever is
# worse than one that is honestly absent: `cid watch status` would keep saying it
# is running while nothing is watched, and every run would leave another of them
# behind.
DAEMON_MAX_FAST_FAILS=5

_daemon() {
  command -v docker >/dev/null 2>&1 || { fail "docker not found — cannot watch the proxy"; exit 1; }
  notify_init "${ALERT_LOG}"
  # Turns on the resume point in `process` (see POSFILE). Only here: a hand-run
  # classifier must keep reading whatever it is given.
  export CID_WATCH_POS="${POSFILE}"
  local started fails=0
  while :; do
    started=${SECONDS}
    printf '[%s] attaching to %s\n' "$(date '+%F %T')" "${PROXY_NAME}"
    # --tail all, not a separate catch-up pass: one stream has no gap to lose
    # lines through, and the resume point above means the replay costs a scan
    # rather than a second notification. Dropping stderr is deliberate — `docker
    # logs` puts the
    # container's stderr there, which for the proxy is Squid's own -d1
    # diagnostics, not access-log lines.
    { docker logs -f --tail all "${PROXY_NAME}" 2>/dev/null \
        | "${SELF}" process "${WATCHER_TAG}" | _notify_loop; } || true
    # docker logs exits when the proxy is recreated (proxy/up.sh always does), so
    # reattach promptly. Exiting inside a second means it was never there — back
    # off, and give up rather than spin forever.
    if (( SECONDS - started < 2 )); then
      fails=$((fails + 1))
      if (( fails >= DAEMON_MAX_FAST_FAILS )); then
        printf '[%s] giving up: %s unreadable after %d tries\n' \
          "$(date '+%F %T')" "${PROXY_NAME}" "${fails}"
        rm -f "${PIDFILE}"
        return 1
      fi
      sleep 15
    else
      fails=0
      sleep 2
    fi
  done
}

# The files a running daemon's behaviour comes from: this script, the helper it
# forks per host, and the three it sources. Hashed into the pidfile at start, so
# `_start` can tell "already running" from "running the code you just replaced".
# CID_CODE_STAMP is a test-only override, like CID_HELPER.
_code_stamp() {
  if [[ -n "${CID_CODE_STAMP:-}" ]]; then printf '%s' "${CID_CODE_STAMP}"; return 0; fi
  local files=() f
  for f in "${SELF}" "${SCRIPT_DIR}/ext-allowlist.sh" "${REPO_DIR}/scripts/notify.sh" \
           "${REPO_DIR}/scripts/colors.sh" "${REPO_DIR}/scripts/paths.sh"; do
    [[ -f "${f}" ]] && files+=("${f}")
  done
  (( ${#files[@]} )) || { printf 'unknown'; return 0; }
  sha256_ "${files[@]}" | sha256_ - | cut -c1-12
}

# The stamp the running watcher was started with, or nothing.
_pidfile_stamp() {
  [[ -f "${PIDFILE}" ]] || return 0
  sed -n '2p' "${PIDFILE}" 2>/dev/null || true
}

# One "<role> <pid>" line per process belonging to a watcher of THIS watch.sh,
# from a single ps scan taken while the parent links are still intact:
#
#   root     one per running watcher: the daemon, or whatever is left of it
#   member   everything else in its tree — the subshell it forks for the notify
#            half of its pipeline (which carries the daemon's own args), the
#            `process` child, that child's awk, and `docker logs` itself
#
# `stop` kills every one of them, and has to. None of these die with their
# parent: the notify subshell is the end of the pipe and keeps notifying;
# `process` only takes SIGPIPE when it next writes, so on an idle proxy it sits
# there for hours still recording hosts into seen-hosts.txt — which would make
# the replacement watcher treat them as already seen and stay silent about them;
# and its awk and `docker logs` outlive it in turn.
#
# Membership is the tree closure of a seed, so a pipeline is caught whole. A seed
# is a daemon, or a `process`/awk whose parent is already gone — the shape a
# half-killed watcher leaves behind. A `process` still attached to a live shell
# is a hand-run classifier (docs/egress-alerts.md) and is no part of this.
#
# Everything is matched twice: once with WATCHER_TAG, once without. The untagged
# form is a daemon started before the tag existed, which has no config dir in its
# argv to scope it by — and which is exactly the stale daemon most in need of
# being stopped, so it counts as ours.
_watcher_procs() {
  ps ax -o pid=,ppid=,args= 2>/dev/null \
    | awk -v self="${SELF}" -v tag="${WATCHER_TAG}" -v me="$$" '
    # Literal suffix test: self is a filesystem path, and a path is not a regex.
    function ends(s, t) {
      return (length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t)
    }
    function is(s, verb) {
      return (ends(s, self " " verb " " tag) || ends(s, self " " verb))
    }
    {
      pid = $1; ppid = $2
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "")   # leave args in $0
      if (pid == me) next
      A[pid] = $0; P[pid] = ppid
      if (is($0, "_daemon"))      K[pid] = "daemon"
      else if (is($0, "process")) K[pid] = "process"
      else if (index($0, "watcher=" self " " tag) || index($0, "watcher=" self)) K[pid] = "awk"
    }
    END {
      for (pid in A) {
        if (K[pid] == "daemon") S[pid] = 1
        # Orphaned by an earlier partial kill: parent is init, or gone entirely.
        else if (K[pid] != "" && (P[pid] == "1" || !(P[pid] in A))) S[pid] = 1
      }
      # Then everything descended from a seed, whatever it is.
      changed = 1
      while (changed) {
        changed = 0
        for (pid in A) if (!(pid in S) && (P[pid] in S)) { S[pid] = 1; changed = 1 }
      }
      for (pid in S)
        print ((K[pid] == "daemon" && K[P[pid]] != "daemon") ? "root" : "member"), pid
    }
  '
  return 0
}

# One pid per running watcher, for counting. A watcher whose daemon has died but
# whose notify subshell has not — reparented, still notifying — reads as its own
# root, which is exactly the state worth reporting.
_daemon_roots() {
  _watcher_procs | awk '$1 == "root" { print $2 }'
  return 0
}

# Everything stop has to kill.
_watcher_pids() {
  _watcher_procs | awk '{ print $2 }'
  return 0
}

# The pid of a live watcher, or non-zero. Asking `ps` what the process IS rather
# than only whether the pid exists: a recycled pid otherwise reads as a running
# watcher forever (the bug commit 6026478 fixed for Chrome). `args=` and not
# `comm=` because comm is just "bash" here.
_alive() {
  [[ -f "${PIDFILE}" ]] || return 1
  local pid args
  pid="$(head -n1 "${PIDFILE}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  args="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
  [[ "${args}" == *watch.sh* ]] || return 1
  printf '%s' "${pid}"
}

_start() {
  local pid stamp
  stamp="$(_code_stamp)"
  if pid="$(_alive)"; then
    if [[ "$(_pidfile_stamp)" == "${stamp}" ]]; then
      kv "egress alert watcher already running" "pid ${pid}"
      _warn_orphans "${pid}"
      return 0
    fi
    # The watcher outlives sessions, so without this an edit to the classifier
    # takes effect only after a manual stop/start — and silently, since the old
    # daemon keeps notifying by the old rules. Restarting is cheap now that the
    # resume point stops a fresh daemon replaying the log.
    say "egress alert watcher is running superseded code — restarting it"
    _stop >/dev/null
  fi
  mkdir -p "${CONFIG_DIR}"
  nohup "${SELF}" _daemon "${WATCHER_TAG}" >>"${DAEMON_LOG}" 2>&1 &
  local mypid=$!
  printf '%s\n%s\n' "${mypid}" "${stamp}" > "${PIDFILE}"
  # Confirm it survived its own startup — a missing docker CLI exits immediately,
  # and a watcher that is not running is a security control that is not there.
  sleep 1
  # Two sessions starting at once can both have seen no watcher, and the loser's
  # daemon would be unreachable forever (nothing records its pid). The pidfile is
  # the arbiter: whoever wrote it last keeps its daemon, the other kills its own.
  if [[ "$(head -n1 "${PIDFILE}" 2>/dev/null || true)" != "${mypid}" ]]; then
    kill "${mypid}" 2>/dev/null || true
    kv "egress alert watcher already running" "started concurrently"
    return 0
  fi
  if ! pid="$(_alive)"; then
    fail "egress alert watcher did not stay up" "Last lines of ${DAEMON_LOG}:"
    tail -n 5 "${DAEMON_LOG}" 2>/dev/null | while IFS= read -r l; do cont "  ${l}"; done
    return 1
  fi
  kv "egress alerts" "watching ${PROXY_NAME}" "pid ${pid}; cid watch status"
}

# Warn about daemons the pidfile does not name. Not killed here: `_start` runs on
# every session, possibly two at once, and the pid of a daemon that has just been
# spawned but not yet recorded is indistinguishable from an orphan.
_warn_orphans() {  # <recorded pid>
  local recorded="$1" pid extra=()
  while IFS= read -r pid; do
    [[ -n "${pid}" && "${pid}" != "${recorded}" ]] && extra+=("${pid}")
  done < <(_daemon_roots)
  (( ${#extra[@]} )) || return 0
  warn "${#extra[@]} other egress watcher process(es) are running" \
    "pids ${extra[*]}; they notify too and 'cid watch status' cannot see them." \
    "Clear them: cid watch stop && cid watch start"
}

_stop() {
  local pid pids=()
  while IFS= read -r pid; do [[ -n "${pid}" ]] && pids+=("${pid}"); done < <(_watcher_pids)
  if (( ${#pids[@]} == 0 )); then
    say "no egress alert watcher running"
    rm -f "${PIDFILE}"
    return 0
  fi
  # Every one of them, not just the pidfile's: stop has to mean stop, or the
  # orphan this exists for survives the very command meant to clear it.
  for pid in "${pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
  rm -f "${PIDFILE}"
  ok "stopped the egress alert watcher" "killed ${#pids[@]} process(es)"
}

_status() {
  local pid
  if pid="$(_alive)"; then
    ok "egress alert watcher running" "pid ${pid}"
    _warn_orphans "${pid}"
  else
    warn "egress alert watcher NOT running" "Start it: cid watch start"
    # With no recorded pid every daemon is an orphan, and this is the state in
    # which one is most likely to be notifying unnoticed.
    _warn_orphans ''
  fi
  notify_init "${ALERT_LOG}"
  kv "notifier" "${NOTIFY_BACKEND}"
  kv "proxy" "${PROXY_NAME}"
  kv "alert log" "${ALERT_LOG}" "cid watch log"
  kv "watcher log" "${DAEMON_LOG}"
  if [[ -f "${POSFILE}" ]]; then
    kv "resumes the log at" "$(head -n1 "${POSFILE}" 2>/dev/null)" "${POSFILE}"
  fi
  # This project's record, since that is the one the user is standing in.
  local key seenf n
  key="$(project_key "${PWD}")"
  seenf="${PROJECTS_DIR}/${key}/seen-hosts.txt"
  if [[ -f "${seenf}" ]]; then
    n="$(grep -c '^[a-z0-9]' "${seenf}" 2>/dev/null || true)"
    kv "hosts recorded for ${key}" "${n:-0}" "cid hosts"
  else
    kv "hosts recorded for ${key}" "none yet" "cid hosts"
  fi
}

_usage() {
  cat <<EOF
proxy/watch.sh — alert when a project contacts a host it never has before.

  start      start the watcher unless it is already running (default)
  stop       stop it
  status     running? which notifier? where are the records?
  process    classify access-log lines from stdin (used by the daemon and tests)

start restarts a watcher whose code has changed since it started; stop kills
every daemon, including one the pidfile has lost track of.

Runs on the host. See docs/egress-alerts.md.
EOF
}

case "${1:-start}" in
  start|"")  _start ;;
  stop)      _stop ;;
  status)    _status ;;
  process)   _process ;;
  # Internal: the two halves the daemon pipes together, exposed so test/watch.bats
  # can drive each without docker.
  notify)    notify_init "${ALERT_LOG}"; _notify_loop ;;
  # The trailing WATCHER_TAG on these two is read by nothing: it is argv so that
  # ps can say which config dir the process belongs to.
  _daemon)   _daemon ;;
  _stamp)    _code_stamp; printf '\n' ;;
  _procs)    _watcher_procs ;;
  -h|--help) _usage ;;
  *) fail "unknown verb: $1" "expected: start | stop | status | process"; exit 2 ;;
esac
