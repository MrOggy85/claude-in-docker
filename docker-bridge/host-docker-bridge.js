#!/usr/bin/env node
// Read-only Docker inspection for the container, over MCP's Streamable HTTP
// transport (reachable via host.docker.internal). Zero dependencies.
//
// Unlike the chrome-devtools bridge this is not a stdio proxy: there is no
// upstream MCP server, so initialize/tools/list/tools/call are answered here and
// each tool call spawns one short-lived `docker` process. The transport half
// (POST/GET/DELETE on /mcp, SSE framing) mirrors
// chrome-devtools-mcp/host-chrome-devtools-mcp.js.
//
// The security model, in order of enforcement:
//   1. Bearer token, required. The token also IDENTIFIES the project: it is read
//      from <projects-dir>/<key>/docker-bridge.token, and the matching key
//      selects that project's container allowlist. Nothing is self-asserted by
//      the client.
//   2. Container allowlist. <projects-dir>/<key>/docker-containers.txt, same
//      format as allowed-domains.txt. Missing/empty = allow nothing.
//   3. Fixed argv. Every tool builds a literal argument array; the only
//      caller-supplied values are a container name (allowlisted, pattern-checked)
//      and two numeric/enumerated options. No shell, ever.
// Read-only by construction: there is no code path here that mutates Docker
// state. See docs/docker-bridge.md.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const crypto = require('crypto');

const PORT = parseInt(process.env.DOCKER_BRIDGE_PORT || '9334', 10);
// 0.0.0.0 by default: the container reaches the host over the Docker gateway, so
// a 127.0.0.1 bind is unreachable (see docs/host-outbound-ports.md). Narrow it to
// the gateway address with DOCKER_BRIDGE_BIND if you know it on your host.
const BIND = process.env.DOCKER_BRIDGE_BIND || '0.0.0.0';
// launchd's PATH is minimal and Docker Desktop installs outside it; the launcher
// script fixes PATH, this knob covers an unusual install location.
const DOCKER = process.env.DOCKER_BRIDGE_DOCKER_CMD || 'docker';

// Config locations. host-docker-bridge.sh exports these from scripts/paths.sh so
// the derivation lives in one place; the fallbacks keep `node host-docker-bridge.js`
// working when run directly.
const CONFIG_DIR = process.env.CID_CONFIG_DIR
  || process.env.CLAUDE_DOCKER_CONFIG_DIR
  || path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'claude-in-docker');
const PROJECTS_DIR = process.env.CID_PROJECTS_DIR
  || process.env.CLAUDE_PROJECTS_DIR
  || path.join(CONFIG_DIR, 'projects');

const CHILD_TIMEOUT_MS = 15000;   // SIGKILL a `docker` call that hangs
const MAX_OUTPUT_BYTES = 256 * 1024;
const MAX_CONCURRENT = 4;         // a looping agent must not fork-bomb the host
const RATE_LIMIT = 60;            // calls per project per RATE_WINDOW_MS
const RATE_WINDOW_MS = 60000;
const LOGS_TAIL_DEFAULT = 200;
const LOGS_TAIL_MAX = 5000;

// Container names Docker accepts, minus anything shell- or path-shaped. Applied
// before the allowlist, so a malformed name never reaches argv.
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
// `docker logs --since` takes a duration or a timestamp; allow only those shapes.
const SINCE_RE = /^(\d{1,9}[smhd]|\d{4}-\d{2}-\d{2}(T[\d:.]{1,15}Z?)?)$/;

const log = (msg) => console.log(`[docker-bridge] ${msg}`);

// ---------------------------------------------------------------------------
// Token -> project key -> allowlist
// ---------------------------------------------------------------------------

// Cached scan of <projects-dir>/*/docker-bridge.token, re-read on a short TTL.
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
    try { token = fs.readFileSync(path.join(PROJECTS_DIR, key, 'docker-bridge.token'), 'utf8').trim(); }
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

function readEntries(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return []; }
  return text.split('\n')
    .map((l) => l.replace(/#.*$/, '').trim())
    .filter(Boolean);
}

// Allowlist for a project: the shared baseline plus the project's own list, same
// union as Squid applies to allowed-domains.txt. Re-read on every call so
// `cid containers add` takes effect immediately. An entry is an exact container
// name or a trailing-'*' prefix glob; '#' comments and blanks are ignored.
function allowlistFor(key) {
  return [
    ...readEntries(path.join(CONFIG_DIR, 'docker-containers.txt')),
    ...readEntries(path.join(PROJECTS_DIR, key, 'docker-containers.txt')),
  ];
}

function isAllowed(name, entries) {
  return entries.some((e) => (e.endsWith('*') ? name.startsWith(e.slice(0, -1)) : name === e));
}

// ---------------------------------------------------------------------------
// Rate limit / concurrency
// ---------------------------------------------------------------------------

const buckets = new Map(); // key -> { count, resetAt }
let inFlight = 0;

function rateLimited(key) {
  const now = Date.now();
  let b = buckets.get(key);
  if (!b || now >= b.resetAt) { b = { count: 0, resetAt: now + RATE_WINDOW_MS }; buckets.set(key, b); }
  b.count += 1;
  return b.count > RATE_LIMIT;
}

// ---------------------------------------------------------------------------
// Running docker
// ---------------------------------------------------------------------------

// Spawn `docker` with a literal argv (never a shell string). Resolves with the
// captured output, capped and marked when truncated.
function runDocker(args) {
  return new Promise((resolve) => {
    let child;
    try { child = spawn(DOCKER, args, { stdio: ['ignore', 'pipe', 'pipe'] }); }
    catch (e) { resolve({ ok: false, text: `failed to run docker: ${e.message}` }); return; }

    const chunks = [];
    let bytes = 0;
    let truncated = false;
    const collect = (chunk) => {
      if (truncated) return;
      bytes += chunk.length;
      if (bytes > MAX_OUTPUT_BYTES) {
        chunks.push(chunk.slice(0, chunk.length - (bytes - MAX_OUTPUT_BYTES)));
        truncated = true;
        return;
      }
      chunks.push(chunk);
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);

    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; try { child.kill('SIGKILL'); } catch {} }, CHILD_TIMEOUT_MS);

    child.on('error', (e) => {
      clearTimeout(timer);
      resolve({ ok: false, text: `failed to run docker: ${e.message}` });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      let text = Buffer.concat(chunks).toString('utf8');
      if (truncated) text += `\n[docker-bridge] output truncated at ${MAX_OUTPUT_BYTES} bytes`;
      if (timedOut) text += `\n[docker-bridge] killed after ${CHILD_TIMEOUT_MS}ms`;
      resolve({ ok: code === 0 && !timedOut, text });
    });
  });
}

// Parse `--format {{json .}}` output (one JSON object per line) and keep only
// the fields we expose. Labels and Mounts are dropped deliberately: they carry
// host filesystem paths (compose working_dir, bind sources).
const PS_FIELDS = ['Names', 'Image', 'State', 'Status', 'RunningFor', 'Ports', 'Command'];
const STATS_FIELDS = ['Name', 'CPUPerc', 'MemUsage', 'MemPerc', 'NetIO', 'BlockIO', 'PIDs'];

function parseJsonLines(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { out.push(JSON.parse(t)); } catch { /* a warning line, not a record */ }
  }
  return out;
}

function project(rows, fields) {
  return rows.map((r) => {
    const o = {};
    for (const f of fields) if (r[f] !== undefined) o[f] = r[f];
    return o;
  });
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'docker_ps',
    description: 'List the Docker containers this project is allowed to see. '
      + 'Containers outside the project allowlist are omitted, so an empty result '
      + 'means "not allowlisted" as often as it means "not running".',
    inputSchema: {
      type: 'object',
      properties: {
        all: { type: 'boolean', description: 'Include stopped containers (docker ps -a). Default false.' },
      },
    },
  },
  {
    name: 'docker_logs',
    description: 'Tail the logs of one allowlisted container (stdout and stderr combined).',
    inputSchema: {
      type: 'object',
      properties: {
        container: { type: 'string', description: 'Container name, as reported by docker_ps.' },
        tail: { type: 'integer', description: `Lines from the end. Default ${LOGS_TAIL_DEFAULT}, max ${LOGS_TAIL_MAX}.` },
        since: { type: 'string', description: 'Only logs newer than this: a duration (10m, 2h) or a date (2026-07-29).' },
        timestamps: { type: 'boolean', description: 'Prefix each line with its timestamp.' },
      },
      required: ['container'],
    },
  },
  {
    name: 'docker_stats',
    description: 'One-shot resource usage (CPU, memory, network, block IO) for allowlisted containers.',
    inputSchema: {
      type: 'object',
      properties: {
        container: { type: 'string', description: 'Limit to one container. Omit for all allowlisted running containers.' },
      },
    },
  },
];

const ok = (text) => ({ content: [{ type: 'text', text }] });
const fail = (text) => ({ content: [{ type: 'text', text }], isError: true });

// Validate a caller-supplied container name against the pattern AND the
// allowlist. Returns an error string, or null when the name is usable.
function checkName(name, entries) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) {
    return 'invalid container name (letters, digits, "_", ".", "-"; must start alphanumeric)';
  }
  if (!isAllowed(name, entries)) {
    return `container '${name}' is not in this project's allowlist. `
      + 'Ask the user to add it with `cid containers add ' + name + '`, or use docker_ps to see what is available.';
  }
  return null;
}

async function callTool(name, args, projectKey) {
  const entries = allowlistFor(projectKey);
  if (entries.length === 0) {
    return fail('this project has no Docker container allowlist yet — ask the user to run '
      + '`cid containers add <name>` and restart the session');
  }
  const a = args && typeof args === 'object' ? args : {};

  if (name === 'docker_ps') {
    const argv = ['ps', '--no-trunc', '--format', '{{json .}}'];
    if (a.all === true) argv.push('--all');
    const r = await runDocker(argv);
    if (!r.ok) return fail(r.text || 'docker ps failed');
    const rows = parseJsonLines(r.text).filter((row) => isAllowed(String(row.Names || '').split(',')[0], entries));
    return ok(JSON.stringify(project(rows, PS_FIELDS), null, 2));
  }

  if (name === 'docker_logs') {
    const err = checkName(a.container, entries);
    if (err) return fail(err);
    let tail = Number.isInteger(a.tail) ? a.tail : LOGS_TAIL_DEFAULT;
    if (tail < 1) tail = 1;
    if (tail > LOGS_TAIL_MAX) tail = LOGS_TAIL_MAX;
    const argv = ['logs', '--tail', String(tail)];
    if (a.since !== undefined) {
      if (typeof a.since !== 'string' || !SINCE_RE.test(a.since)) {
        return fail('invalid "since": use a duration (30s, 10m, 2h, 1d) or a date (2026-07-29[T12:00:00Z])');
      }
      argv.push('--since', a.since);
    }
    if (a.timestamps === true) argv.push('--timestamps');
    argv.push(a.container);
    const r = await runDocker(argv);
    // Non-zero here usually means "no such container" — surface docker's own
    // message, it is more useful than a generic failure.
    return r.ok ? ok(r.text || '(no log output)') : fail(r.text || 'docker logs failed');
  }

  if (name === 'docker_stats') {
    const argv = ['stats', '--no-stream', '--format', '{{json .}}'];
    if (a.container !== undefined) {
      const err = checkName(a.container, entries);
      if (err) return fail(err);
      argv.push(a.container);
    }
    const r = await runDocker(argv);
    if (!r.ok) return fail(r.text || 'docker stats failed');
    const rows = parseJsonLines(r.text).filter((row) => isAllowed(String(row.Name || ''), entries));
    return ok(JSON.stringify(project(rows, STATS_FIELDS), null, 2));
  }

  return fail(`unknown tool: ${name}`);
}

// ---------------------------------------------------------------------------
// MCP protocol
// ---------------------------------------------------------------------------

const PROTOCOL_VERSION = '2025-06-18';

// Handle one JSON-RPC message. Returns a response object, or null for
// notifications (nothing to send back).
async function handleMessage(msg, projectKey) {
  const { id, method } = msg;
  const reply = (result) => ({ jsonrpc: '2.0', id, result });

  if (method === 'initialize') {
    return reply({
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: 'docker-bridge', version: '1.0.0' },
    });
  }
  if (method === 'tools/list') return reply({ tools: TOOLS });
  if (method === 'ping') return reply({});
  if (method === 'tools/call') {
    if (rateLimited(projectKey)) {
      return reply(fail(`rate limit exceeded (${RATE_LIMIT} calls/min) — wait before retrying`));
    }
    if (inFlight >= MAX_CONCURRENT) {
      return reply(fail(`too many concurrent docker calls (${MAX_CONCURRENT}) — retry shortly`));
    }
    inFlight += 1;
    try {
      return reply(await callTool(msg.params && msg.params.name, msg.params && msg.params.arguments, projectKey));
    } finally {
      inFlight -= 1;
    }
  }
  if (id == null) return null; // an unknown notification: ignore
  return { jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } };
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport (shape mirrors the chrome-devtools bridge)
// ---------------------------------------------------------------------------

// Sessions are just ids here — no child process to own — but several may exist
// at once so concurrent Claude sessions both work. Clients are not required to
// DELETE on exit, so the map is capped and the oldest entry (Map iterates in
// insertion order) is evicted rather than left to grow in a KeepAlive daemon.
const sessions = new Map(); // id -> { projectKey, getStream }
const MAX_SESSIONS = 32;

function dropSession(id) {
  const s = sessions.get(id);
  if (!s) return;
  sessions.delete(id);
  if (s.getStream) {
    clearInterval(s.getStream.ping);
    try { s.getStream.res.end(); } catch { /* already closed */ }
  }
}

function newSession(projectKey) {
  while (sessions.size >= MAX_SESSIONS) dropSession(sessions.keys().next().value);
  const id = crypto.randomUUID();
  sessions.set(id, { projectKey, getStream: null });
  return id;
}

function sse(res, msg) {
  res.write(`event: message\ndata: ${JSON.stringify(msg)}\n\n`);
}

function keepAlive(res) {
  return setInterval(() => { try { res.write(': ping\n\n'); } catch { /* closed */ } }, 15000);
}

function bearer(req) {
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/mcp') { res.writeHead(404).end('not found'); return; }

  // Auth before anything else: an unauthenticated caller learns only that
  // something is listening, not whether a path or session exists.
  const projectKey = projectForToken(bearer(req));
  if (!projectKey) { res.writeHead(401, { 'WWW-Authenticate': 'Bearer' }).end(); return; }

  const sid = req.headers['mcp-session-id'];
  const session = sid ? sessions.get(sid) : null;
  // A session belongs to the project that created it.
  if (session && session.projectKey !== projectKey) { res.writeHead(404).end('no session'); return; }

  if (req.method === 'GET') {
    // Server-initiated stream. Nothing is ever pushed on it, but clients open it
    // and expect it to stay up.
    if (!session) { res.writeHead(404).end('no session'); return; }
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    const stream = { res, ping: keepAlive(res) };
    session.getStream = stream;
    // res (not req) 'close' — req 'close' fires as soon as the body is read.
    res.on('close', () => {
      clearInterval(stream.ping);
      if (session.getStream === stream) session.getStream = null;
    });
    return;
  }

  if (req.method === 'DELETE') {
    if (session) dropSession(sid);
    res.writeHead(200).end();
    return;
  }

  if (req.method !== 'POST') { res.writeHead(405).end('method not allowed'); return; }

  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', async () => {
    let parsed;
    try { parsed = JSON.parse(body); } catch { res.writeHead(400).end('bad json'); return; }
    const msgs = Array.isArray(parsed) ? parsed : [parsed];
    const isInit = msgs.some((m) => m.method === 'initialize');

    const headers = {};
    let s = session;
    if (isInit) {
      const id = newSession(projectKey);
      s = sessions.get(id);
      headers['Mcp-Session-Id'] = id;
    }
    // A POST without a session header is accepted (some clients omit it); one
    // naming an unknown or foreign session is not.
    if (!isInit && sid && !s) { res.writeHead(404).end('no session'); return; }

    const replies = [];
    for (const m of msgs) {
      const r = await handleMessage(m, projectKey);
      if (r) replies.push(r);
    }

    if (replies.length === 0) { res.writeHead(202, headers).end(); return; }

    res.writeHead(200, { ...headers, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    for (const r of replies) sse(res, r);
    res.end();
  });
});

server.listen(PORT, BIND, () => {
  log(`read-only docker bridge on ${BIND}:${PORT}/mcp`);
  log(`projects dir: ${PROJECTS_DIR}`);
  const n = loadTokens().length;
  if (n === 0) {
    log('warning: no project tokens found — run `CLAUDE_DOCKER_BRIDGE=1 ./run.sh` once to create one');
  } else {
    log(`${n} project token(s) loaded`);
  }
});
