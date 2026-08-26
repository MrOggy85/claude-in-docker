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

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
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
// SingletonLock symlink -> "<hostname>-<pid>"; it runs on this host, so the pid
// is checkable. EPERM means alive but owned by another user. A stale lock left
// by a crash names a dead pid and so reads as free.
function chromeAlive(dir) {
  let target;
  try { target = fs.readlinkSync(path.join(dir, 'SingletonLock')); } catch { return false; }
  const pid = parseInt(target.slice(target.lastIndexOf('-') + 1), 10);
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
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
  const s = { id, projectKey, label: isolated ? null : label, child, pending: new Map(), getStream: null, queue: [] };
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
  const isResponse = msg.id != null && msg.method === undefined;
  if (isResponse && s.pending.has(msg.id)) {
    const entry = s.pending.get(msg.id);
    s.pending.delete(msg.id);
    entry.ids.delete(msg.id);
    sse(entry.res, msg);
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

    for (const m of msgs) s.child.stdin.write(JSON.stringify(m) + '\n');

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
