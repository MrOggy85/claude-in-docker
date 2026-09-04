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
# Verbs:
#   start (default)  idempotent — start the daemon unless it is already running
#   stop             kill it
#   status           is it running, which notifier, where the records are
#   process          the classifier: access-log lines on stdin, alert lines on
#                    stdout. No docker, no notifications — this is what
#                    test/watch.bats drives.
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

PIDFILE="${CONFIG_DIR}/watcher.pid"
DAEMON_LOG="${CONFIG_DIR}/watcher.log"      # the watcher's own stdout/stderr
ALERT_LOG="${CONFIG_DIR}/egress-alerts.log" # one line per alert, written by notify()

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
  # Read by the system() call in record(): passing the path through the
  # environment means the shell expands it, so a config dir containing spaces or
  # quotes needs no escaping here.
  export CID_PROJECTS_DIR="${PROJECTS_DIR}"
  awk -v projdir="${PROJECTS_DIR}" -v cooldown="${COOLDOWN}" '
    function seenfile(key) { return projdir "/" key "/seen-hosts.txt" }

    # Load a project s recorded hosts on first sight of that project. getline
    # returns -1 when the file cannot be opened, which is how a brand-new project
    # (header still to write) is told apart from one with an empty list.
    function loadseen(key,   f, line, rc) {
      if (key in loaded) return
      loaded[key] = 1
      f = seenfile(key)
      while ((rc = (getline line < f)) > 0) {
        gsub(/[ \t\r]/, "", line)
        if (line != "" && substr(line, 1, 1) != "#") seen[key SUBSEP line] = 1
      }
      close(f)
      fresh[key] = (rc < 0)
    }

    # Append a host to the project s record. mkdir -p because a project that has
    # never run still has no config dir, and awk cannot create one. close() after
    # every write: it is the portable flush (fflush(file) is not universal).
    function record(key, host,   f) {
      f = seenfile(key)
      if (fresh[key]) {
        # key is guarded to [a-z0-9-] below, so it is safe unquoted; the dir
        # comes from the environment so the shell quotes it.
        system("mkdir -p \"$CID_PROJECTS_DIR/" key "\"")
        print "# Hosts this project has contacted, recorded by proxy/watch.sh." > f
        print "# Delete a line (or the file) to be alerted about it again: cid hosts forget" >> f
        fresh[key] = 0
      }
      print host >> f
      close(f)
      seen[key SUBSEP host] = 1
    }

    function alert(urgency, key, host, reason) {
      printf "%s\t%s\t%s\t%s\n", urgency, key, host, reason
      fflush()   # the reader is a pipe; without this a burst sits in the buffer
    }

    # Squid runs with -d1, so its own diagnostics share this stream. An
    # access-log line always has all ten fields.
    NF < 10 { next }
    {
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

      if (isnew) {
        record(key, host)
        if (byrule)     alert("alert", key, host, "denied-by-rule")
        else if (denied) alert("alert", key, host, "new-host-denied")
        else             alert("info",  key, host, "new-host")
        if (denied) lastdeny[key SUBSEP host] = ts
      } else if (denied) {
        if (!((key SUBSEP host) in lastdeny) || ts - lastdeny[key SUBSEP host] >= cooldown) {
          lastdeny[key SUBSEP host] = ts
          alert("alert", key, host, byrule ? "denied-by-rule" : "denied")
        }
      }

      # The origin refused it, not us — worth saying, since the failure looks
      # identical from inside the container, but it is not a security event and
      # never raises the urgency. Its OWN cooldown map: sharing lastdeny would let
      # a server that 403s constantly silence the alert for this project actually
      # being denied that host, which is the one that matters. Independent of the
      # isnew branch above, so a first contact that is refused says both things.
      if (upstream) {
        if (!((key SUBSEP host) in lastup) || ts - lastup[key SUBSEP host] >= cooldown) {
          lastup[key SUBSEP host] = ts
          alert("info", key, host, "upstream-403")
        }
      }
    }
  '
}

# ---------------------------------------------------------------------------
# notify loop — coalesce alert lines into notifications
# ---------------------------------------------------------------------------

# Buffer of pending "urgency<TAB>key<TAB>host<TAB>reason" lines. A global because
# bash 3.2 has no namerefs.
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
        hosts[k] = hosts[k] (hosts[k] == "" ? "" : ",") $3
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
  elif [[ "${urgency}" == alert ]]; then
    title="Egress DENIED: ${key}"
    # Name the host in the fix when there is exactly one — that is the command
    # to paste, not a template to fill in.
    if (( count == 1 )); then hint="Allow it: cid domains add ${csv}"
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
  local started fails=0
  while :; do
    started=${SECONDS}
    printf '[%s] attaching to %s\n' "$(date '+%F %T')" "${PROXY_NAME}"
    # --tail all, not a separate catch-up pass: one stream has no gap to lose
    # lines through, and replaying old lines is harmless because the seen-set is
    # persistent. Dropping stderr is deliberate — `docker logs` puts the
    # container's stderr there, which for the proxy is Squid's own -d1
    # diagnostics, not access-log lines.
    { docker logs -f --tail all "${PROXY_NAME}" 2>/dev/null | "${SELF}" process | _notify_loop; } || true
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
  local pid
  if pid="$(_alive)"; then
    kv "egress alert watcher already running" "pid ${pid}"
    return 0
  fi
  mkdir -p "${CONFIG_DIR}"
  nohup "${SELF}" _daemon >>"${DAEMON_LOG}" 2>&1 &
  local mypid=$!
  printf '%s\n' "${mypid}" > "${PIDFILE}"
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

_stop() {
  local pid
  if ! pid="$(_alive)"; then
    say "no egress alert watcher running"
    rm -f "${PIDFILE}"
    return 0
  fi
  kill "${pid}" 2>/dev/null || true
  rm -f "${PIDFILE}"
  ok "stopped the egress alert watcher" "pid ${pid}"
}

_status() {
  local pid
  if pid="$(_alive)"; then ok "egress alert watcher running" "pid ${pid}"
  else                     warn "egress alert watcher NOT running" "Start it: cid watch start"
  fi
  notify_init "${ALERT_LOG}"
  kv "notifier" "${NOTIFY_BACKEND}"
  kv "proxy" "${PROXY_NAME}"
  kv "alert log" "${ALERT_LOG}" "cid watch log"
  kv "watcher log" "${DAEMON_LOG}"
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
  _daemon)   _daemon ;;
  -h|--help) _usage ;;
  *) fail "unknown verb: $1" "expected: start | stop | status | process"; exit 2 ;;
esac
