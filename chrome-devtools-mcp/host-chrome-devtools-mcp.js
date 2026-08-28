#!/usr/bin/env node
// Bridges the stdio `chrome-devtools-mcp` server to MCP's Streamable HTTP
// transport so the container can reach it over HTTP via host.docker.internal.
// Zero dependencies (node http + child_process + fs).
//
// One session owns one Chrome, and several sessions run at once so concurrent
// containers each drive their own browser. Who gets which browser:
//   1. Bearer token, required. The token also IDENTIFIES the project: it is read
//      from <projects-dir>/<key>/chrome-devtools.token. Nothing is self-asserted.
//   2. Profile label (X-Claude-Profile, default "default"), which names a profile
//      INSIDE that project: <profile-root>/<key>/<label>. The token bounds the
//      namespace, so a client can only ever name its own profiles.
//   3. A live session already holding that label keeps it — the second session
//      gets a throwaway --isolated profile rather than evicting a running Chrome.
// See docs/chrome-devtools-mcp.md.
//
// Streamable HTTP <-> stdio mapping (all on the /mcp endpoint):
//   POST with request(s)            -> forward to the session's child stdin,
//                                       stream the matching JSON-RPC responses
//                                       back as SSE, then close (correlated by
//                                       JSON-RPC id).
//   POST with only notifications    -> forward to stdin, reply 202.
//   GET                             -> SSE stream for server-initiated
//                                       notifications/requests (progress, logs).
//   DELETE                          -> terminate the session (kill Chrome).
//
// One thing is not passed through: filesystem paths. The client is in a
// container and the server is not, so they spell shared directories
// differently. See "Path translation" below.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execFileSync } = require('child_process');
const { fileURLToPath, pathToFileURL } = require('url');
const crypto = require('crypto');

const PORT = parseInt(process.env.CHROME_DEVTOOLS_MCP_PORT || '9333', 10);
const EXTRA = (process.env.CHROME_DEVTOOLS_MCP_EXTRA_ARGS || '').split(' ').filter(Boolean);
// --no-usage-statistics: don't send telemetry to Google (host egress bypasses
// Squid). Add --no-performance-crux via EXTRA_ARGS to also stop the perf tools
// hitting the CrUX API. The profile flag is per session, so it is not here.
// Flags per `npx -y chrome-devtools-mcp@latest --help`.
const FLAGS = ['--no-usage-statistics', ...EXTRA];
// Default: fetch the server via npx at launch (@latest, pin with
// CHROME_DEVTOOLS_MCP_VERSION). Set CHROME_DEVTOOLS_MCP_CMD to a pre-installed
// binary (e.g. a global `chrome-devtools-mcp`) to skip npx and the registry
// round-trip entirely — no registry auth needed in launchd's bare environment.
const CMD = process.env.CHROME_DEVTOOLS_MCP_CMD;
const VERSION = process.env.CHROME_DEVTOOLS_MCP_VERSION || 'latest';

// Config locations. host-chrome-devtools-mcp.sh exports these from
// scripts/paths.sh so the derivation lives in one place; the fallbacks keep
// `node host-chrome-devtools-mcp.js` working when run directly.
const CONFIG_DIR = process.env.CID_CONFIG_DIR
  || process.env.CLAUDE_DOCKER_CONFIG_DIR
  || path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'claude-in-docker');
const PROJECTS_DIR = process.env.CID_PROJECTS_DIR
  || process.env.CLAUDE_PROJECTS_DIR
  || path.join(CONFIG_DIR, 'projects');

// Chrome profiles are churny multi-hundred-MB binary trees: cache, not config,
// so they live outside the config dir (which stays scannable and syncable).
const PROFILE_ROOT = process.env.CHROME_DEVTOOLS_MCP_PROFILE_ROOT
  || path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'),
               'claude-in-docker', 'chrome-profiles');
// CHROME_DEVTOOLS_MCP_PROFILE=off restores the old behaviour: every session gets
// a temporary profile, cleaned up when its Chrome closes.
const PROFILES_OFF = (process.env.CHROME_DEVTOOLS_MCP_PROFILE || '').toLowerCase() === 'off';

// Each session is a Chrome plus a Node server, so this cap is small — unlike the
// docker bridge, where a session is a bookkeeping record. Clients are not
// required to DELETE on exit, so the map is capped and the oldest entry (Map
// iterates in insertion order) is evicted rather than left to grow.
const MAX_SESSIONS = parseInt(process.env.CHROME_DEVTOOLS_MCP_MAX_SESSIONS || '4', 10);

// A profile label becomes a path segment, so it is validated before any join:
// "..", a slash or a NUL would otherwise escape the project's namespace.
const LABEL_RE = /^[A-Za-z0-9._-]{1,64}$/;
const DEFAULT_LABEL = 'default';

const log = (msg) => console.log(`[chrome-devtools-mcp] ${msg}`);

// ---------------------------------------------------------------------------
// Token -> project key
// ---------------------------------------------------------------------------

// Cached scan of <projects-dir>/*/chrome-devtools.token, re-read on a short TTL.
// Deliberately NOT keyed on the projects dir's mtime: that only moves when a
// project dir is added, and enabling this bridge on a project that already has
// one mints the token INSIDE it, leaving the parent untouched. Keying on mtime
// makes such a token invisible until the bridge restarts — a 401 with no
// explanation. A readdir per second, only while requests arrive, is cheaper than
// that failure mode.
const TOKEN_TTL_MS = 1000;
let tokenCache = { at: -Infinity, entries: [] };

function loadTokens() {
  const now = Date.now();
  if (now - tokenCache.at < TOKEN_TTL_MS) return tokenCache.entries;

  const entries = [];
  let keys;
  try { keys = fs.readdirSync(PROJECTS_DIR); } catch { keys = []; }
  for (const key of keys) {
    let token;
    try { token = fs.readFileSync(path.join(PROJECTS_DIR, key, 'chrome-devtools.token'), 'utf8').trim(); }
    catch { continue; }
    if (token) entries.push({ key, token });
  }
  tokenCache = { at: now, entries };
  return entries;
}

// The project whose token matches, or null. Compared in constant time; the
// length check is unavoidable (timingSafeEqual requires equal lengths) and leaks
// only the token length.
function projectForToken(presented) {
  if (!presented) return null;
  const a = Buffer.from(presented);
  let match = null;
  for (const e of loadTokens()) {
    const b = Buffer.from(e.token);
    if (a.length === b.length && crypto.timingSafeEqual(a, b)) match = e.key;
  }
  return match;
}

function bearer(req) {
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

// ---------------------------------------------------------------------------
// Path translation
// ---------------------------------------------------------------------------

// The client runs in a container, this server does not, and both touch the same
// bind-mounted directories under different names: /home/dev/repo here is
// /Users/you/code/thing there. chrome-devtools-mcp confines every filePath write
// to a workspace root, so an untranslated container root resolves to nothing on
// this host, gets skipped, and leaves the OS temp dir as the only writable
// place — a screenshot the container then cannot read back.
//
// So paths are rewritten in both directions and the container's spelling is the
// only one anybody outside sees. run.sh writes the map to
// <projects-dir>/<key>/mounts.txt, one "<container>\t<host>" line per
// READ-WRITE mount (see run.sh step 3c-d for why ro mounts are excluded).
const MOUNTS_TTL_MS = 1000;
const mountsCache = new Map();  // projectKey -> { at, byContainer, byHost }

const trimSlash = (p) => p.replace(/\/+$/, '') || '/';

function loadMounts(projectKey) {
  const now = Date.now();
  const hit = mountsCache.get(projectKey);
  if (hit && now - hit.at < MOUNTS_TTL_MS) return hit;

  let text = '';
  try { text = fs.readFileSync(path.join(PROJECTS_DIR, projectKey, 'mounts.txt'), 'utf8'); }
  catch { /* bridge enabled but no run yet, or an old run.sh */ }

  const pairs = text.split('\n')
    .map((line) => line.split('\t'))
    .filter((p) => p.length === 2 && p[0].startsWith('/') && p[1].startsWith('/'))
    .map(([container, host]) => ({ container: trimSlash(container), host: trimSlash(host) }));
  // Longest prefix first, per direction: a mount nested inside another must win.
  const entry = {
    at: now,
    byContainer: [...pairs].sort((a, b) => b.container.length - a.container.length),
    byHost: [...pairs].sort((a, b) => b.host.length - a.host.length),
  };
  mountsCache.set(projectKey, entry);
  return entry;
}

// One absolute path across the mount, or null if none covers it. Exact match or
// a '/'-delimited prefix only, so /home/dev/repo never swallows /home/dev/repo2.
function mapPath(list, p, from, to) {
  if (typeof p !== 'string' || !p.startsWith('/')) return null;
  const norm = trimSlash(p);
  for (const m of list) {
    if (norm === m[from]) return m[to];
    if (norm.startsWith(m[from] + '/')) return m[to] + norm.slice(m[from].length);
  }
  return null;
}

// Host paths embedded in free text (tools report where they saved a file), put
// back into the container's spelling. Prefix + '/' only, and a plain
// split/join so nothing in the path is read as a pattern.
function containerize(byHost, text) {
  let out = text;
  for (const m of byHost) out = out.split(m.host + '/').join(m.container + '/');
  return out;
}

// Client -> server. Two carriers of a container path:
//   * the roots/list answer, whose ids `routeFromServer` recorded
//   * a tools/call filePath (take_screenshot, performance_start_trace,
//     take_heapsnapshot, evaluate_script)
// A root with no mount behind it is DROPPED, not passed through: the server can
// only log an ENOENT and skip it, so forwarding it just adds noise.
function fromClient(s, m) {
  const { byContainer } = loadMounts(s.projectKey);
  if (!byContainer.length) return m;

  if (m.id != null && m.method === undefined && s.rootsRequests.has(m.id)) {
    s.rootsRequests.delete(m.id);
    const roots = m.result && m.result.roots;
    if (Array.isArray(roots)) {
      m.result.roots = roots.flatMap((r) => {
        let p;
        try { p = fileURLToPath(r.uri); } catch { return []; }
        const host = mapPath(byContainer, p, 'container', 'host');
        return host ? [{ ...r, uri: pathToFileURL(host).href }] : [];
      });
      log(`session ${s.id.slice(0, 8)} roots -> ${m.result.roots.length}/${roots.length} mapped`);
    }
    return m;
  }

  if (m.method === 'tools/call' && m.params && m.params.arguments) {
    const host = mapPath(byContainer, m.params.arguments.filePath, 'container', 'host');
    if (host) m.params.arguments.filePath = host;
  }
  return m;
}

// Server -> client: the reverse, over the text parts of a tool result ("Saved
// screenshot to <path>."), so the agent is handed a path it can actually open.
function toClient(s, msg) {
  const { byHost } = loadMounts(s.projectKey);
  if (!byHost.length) return msg;
  const content = msg.result && msg.result.content;
  if (!Array.isArray(content)) return msg;
  for (const part of content) {
    if (part && part.type === 'text' && typeof part.text === 'string') {
      part.text = containerize(byHost, part.text);
    }
  }
  return msg;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

const sessions = new Map(); // id -> { id, projectKey, label, child, pending, getStream, queue }

function sse(res, msg) {
  res.write(`event: message\ndata: ${JSON.stringify(msg)}\n\n`);
}

function keepAlive(res) {
  return setInterval(() => { try { res.write(': ping\n\n'); } catch { /* closed */ } }, 15000);
}

function dropSession(id) {
  const s = sessions.get(id);
  if (!s) return;
  sessions.delete(id);
  try { s.child.kill(); } catch { /* already gone */ }
  if (s.getStream) { clearInterval(s.getStream.ping); try { s.getStream.res.end(); } catch {} }
  for (const entry of new Set(s.pending.values())) { clearInterval(entry.ping); try { entry.res.end(); } catch {} }
}

function sessionFor(projectKey, label) {
  for (const s of sessions.values()) {
    if (s.projectKey === projectKey && s.label === label) return s;
  }
  return null;
}

// Is a Chrome actually using this profile? Chrome locks a user-data-dir with a
// SingletonLock symlink -> "<hostname>-<pid>", and it runs on this host, so the
// pid is checkable.
//
// "Is that pid alive" is NOT enough. Chrome removes the lock only on a clean
// exit, and dropSession kills the server out from under its browser — so a
// leftover lock is the normal case here, not a crash artifact. Any process that
// later inherits the pid then reads as a live Chrome and the profile is
// unreachable forever. (Worse for a root-owned pid: kill(pid, 0) raises EPERM,
// which says "exists, not yours".) So ask what the process actually IS. `ps`
// exits non-zero once the pid is gone, which covers both questions at once.
function chromeAlive(dir) {
  let target;
  try { target = fs.readlinkSync(path.join(dir, 'SingletonLock')); } catch { return false; }
  const pid = parseInt(target.slice(target.lastIndexOf('-') + 1), 10);
  if (!Number.isInteger(pid) || pid <= 0) return false;

  let comm;
  try {
    comm = execFileSync('ps', ['-p', String(pid), '-o', 'comm='],
                        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch { return false; }   // no such pid
  // macOS prints the executable's full path here, Linux the (truncated) name.
  return /chrom(e|ium)/i.test(comm);
}

// The profile flags for a new session: a named directory, or --isolated. Never
// both.
//
// "In use" cannot mean "a session object exists". The server is spawned at
// initialize but Chrome only launches on first tool use, so a session can hold a
// label for a long time with no browser behind it — and a client that reconnects
// (its old session lingering, browser closed) would then be pushed onto a temp
// profile and silently lose everything it did there. So a claim counts only
// while a browser is running or a client is still connected on its GET stream;
// anything else is stale and gets reclaimed, killing the abandoned server so it
// can never launch Chrome onto the directory we just handed over.
function profileArgs(projectKey, label) {
  if (PROFILES_OFF) return ['--isolated'];
  const dir = path.join(PROFILE_ROOT, projectKey, label);
  const holder = sessionFor(projectKey, label);

  if (chromeAlive(dir) || (holder && holder.getStream)) {
    log(`profile '${label}' in use by an active session; using a temp profile. ` +
        'Set CLAUDE_CHROME_PROFILE to keep state.');
    return ['--isolated'];
  }
  if (holder) {
    log(`reclaiming profile '${label}' from a session with no running browser`);
    dropSession(holder.id);
  }

  try { fs.mkdirSync(dir, { recursive: true }); }
  catch (e) {
    log(`cannot create profile dir ${dir}: ${e.message} — using a temp profile`);
    return ['--isolated'];
  }
  return [`--user-data-dir=${dir}`];
}

function startSession(projectKey, label) {
  while (sessions.size >= MAX_SESSIONS) {
    const oldest = sessions.keys().next().value;
    log(`session cap (${MAX_SESSIONS}) reached — closing the oldest browser`);
    dropSession(oldest);
  }

  const args = [...profileArgs(projectKey, label), ...FLAGS];
  const isolated = args[0] === '--isolated';
  const [bin, argv] = CMD ? [CMD, args] : ['npx', ['-y', `chrome-devtools-mcp@${VERSION}`, ...args]];

  const id = crypto.randomUUID();
  const child = spawn(bin, argv, { stdio: ['pipe', 'pipe', 'inherit'] });
  // An isolated session holds no label, so it never blocks the real profile.
  const s = { id, projectKey, label: isolated ? null : label, child, pending: new Map(),
              getStream: null, queue: [], rootsRequests: new Set() };
  sessions.set(id, s);
  // One line per session naming what it actually got: "why is my profile empty"
  // is otherwise only answerable when something went wrong enough to log.
  log(`session ${id.slice(0, 8)} project=${projectKey} ` +
      `profile=${isolated ? 'temp (--isolated)' : label} — ${sessions.size} live`);

  child.on('error', (e) => log(`spawn error: ${e.message}`));
  child.stdin.on('error', () => { /* EPIPE after kill */ });
  child.on('exit', () => dropSession(id));

  let buf = '';
  child.stdout.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      routeFromServer(s, msg);
    }
  });
  return s;
}

// A server->client message: a response (id, no method) goes back on the POST
// stream that carried its request; everything else goes on the GET stream.
function routeFromServer(s, msg) {
  // Remember a roots/list so the client's answer is recognisable on the way
  // back — that is the one client message carrying container paths to rewrite.
  if (msg.method === 'roots/list' && msg.id != null) s.rootsRequests.add(msg.id);

  const isResponse = msg.id != null && msg.method === undefined;
  if (isResponse && s.pending.has(msg.id)) {
    const entry = s.pending.get(msg.id);
    s.pending.delete(msg.id);
    entry.ids.delete(msg.id);
    sse(entry.res, toClient(s, msg));
    if (entry.ids.size === 0) { clearInterval(entry.ping); try { entry.res.end(); } catch {} }
    return;
  }
  if (s.getStream) sse(s.getStream.res, msg);
  else s.queue.push(msg); // buffer until the client opens its GET stream
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/mcp') { res.writeHead(404).end('not found'); return; }

  // Auth before any session work: without a token a caller learns only that
  // something is listening, not whether a session exists.
  const projectKey = projectForToken(bearer(req));
  if (!projectKey) { res.writeHead(401, { 'WWW-Authenticate': 'Bearer' }).end(); return; }

  const sid = req.headers['mcp-session-id'];
  const session = sid ? sessions.get(sid) : null;
  // A session belongs to the project that created it.
  if (session && session.projectKey !== projectKey) { res.writeHead(404).end('no session'); return; }

  if (req.method === 'GET') {
    if (!session) { res.writeHead(404).end('no session'); return; }
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    const stream = { res, ping: keepAlive(res) };
    session.getStream = stream;
    for (const m of session.queue.splice(0)) sse(res, m);
    // res (not req) 'close' — req 'close' fires as soon as the body is read.
    res.on('close', () => {
      clearInterval(stream.ping);
      if (session.getStream === stream) session.getStream = null;
    });
    return;
  }

  if (req.method === 'DELETE') {
    if (session) dropSession(session.id);
    res.writeHead(200).end();
    return;
  }

  if (req.method !== 'POST') { res.writeHead(405).end('method not allowed'); return; }

  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    let parsed;
    try { parsed = JSON.parse(body); } catch { res.writeHead(400).end('bad json'); return; }
    const msgs = Array.isArray(parsed) ? parsed : [parsed];
    const requestIds = msgs.filter((m) => m.method !== undefined && m.id != null).map((m) => m.id);
    const isInit = msgs.some((m) => m.method === 'initialize');

    const headers = {};
    let s = session;
    if (isInit) {
      const label = (req.headers['x-claude-profile'] || DEFAULT_LABEL).trim();
      if (!LABEL_RE.test(label) || label === '.' || label === '..') {
        res.writeHead(400).end('bad profile label');
        return;
      }
      // A client re-initializing on its own session id is replacing it, not
      // competing with itself — free the old one (and its label) first.
      if (session) dropSession(session.id);
      s = startSession(projectKey, label);
      headers['Mcp-Session-Id'] = s.id;
    }
    if (!s) { res.writeHead(404).end('no session'); return; }

    for (const m of msgs) s.child.stdin.write(JSON.stringify(fromClient(s, m)) + '\n');

    if (requestIds.length === 0) { res.writeHead(202, headers).end(); return; }

    res.writeHead(200, { ...headers, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    const entry = { res, ids: new Set(requestIds), ping: keepAlive(res) };
    for (const id of requestIds) s.pending.set(id, entry);
    // res (not req) 'close' — req 'close' fires as soon as the body is read,
    // which would drop the pending entry before the response comes back.
    res.on('close', () => {
      clearInterval(entry.ping);
      for (const id of entry.ids) s.pending.delete(id);
    });
  });
});

server.listen(PORT, '0.0.0.0', () => {
  log(`streamable-HTTP bridge on 0.0.0.0:${PORT}/mcp`);
  const n = loadTokens().length;
  if (n === 0) log('warning: no project tokens found — run `CLAUDE_CHROME_DEVTOOLS=1 ./run.sh` once to create one');
  else log(`${n} project token(s) loaded, profiles under ${PROFILE_ROOT}`);
});
