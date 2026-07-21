#!/usr/bin/env node
// Bridges the stdio `chrome-devtools-mcp` server to MCP's Streamable HTTP
// transport so the container can reach it over HTTP via host.docker.internal.
// Zero dependencies (node http + child_process). Single active session: a new
// `initialize` replaces any previous one, so at most one Chrome runs at a time.
//
// Streamable HTTP <-> stdio mapping (all on the /mcp endpoint):
//   POST with request(s)            -> forward to child stdin, stream the
//                                       matching JSON-RPC responses back as SSE,
//                                       then close (correlated by JSON-RPC id).
//   POST with only notifications    -> forward to stdin, reply 202.
//   GET                             -> SSE stream for server-initiated
//                                       notifications/requests (progress, logs).
//   DELETE                          -> terminate the session (kill Chrome).

const http = require('http');
const { spawn } = require('child_process');
const crypto = require('crypto');

const PORT = parseInt(process.env.CHROME_DEVTOOLS_MCP_PORT || '9333', 10);
const EXTRA = (process.env.CHROME_DEVTOOLS_MCP_EXTRA_ARGS || '').split(' ').filter(Boolean);
// --isolated: clean throwaway Chrome profile (no logged-in accounts).
// --no-usage-statistics: don't send telemetry to Google (host egress bypasses
// Squid). Add --no-performance-crux via EXTRA_ARGS to also stop the perf tools
// hitting the CrUX API. Flags per `npx -y chrome-devtools-mcp@latest --help`.
const MCP_ARGS = ['-y', 'chrome-devtools-mcp@latest', '--isolated', '--no-usage-statistics', ...EXTRA];

let session = null; // { id, child, pending: Map<jsonrpcId, entry>, getStream, queue }

function sse(res, msg) {
  res.write(`event: message\ndata: ${JSON.stringify(msg)}\n\n`);
}

function keepAlive(res) {
  return setInterval(() => { try { res.write(': ping\n\n'); } catch { /* closed */ } }, 15000);
}

function endSession() {
  if (!session) return;
  const s = session;
  session = null;
  try { s.child.kill(); } catch { /* already gone */ }
  if (s.getStream) { clearInterval(s.getStream.ping); try { s.getStream.res.end(); } catch {} }
  for (const entry of new Set(s.pending.values())) { clearInterval(entry.ping); try { entry.res.end(); } catch {} }
}

function startSession() {
  endSession(); // enforce a single active session (one Chrome at a time)
  const id = crypto.randomUUID();
  const child = spawn('npx', MCP_ARGS, { stdio: ['pipe', 'pipe', 'inherit'] });
  const s = { id, child, pending: new Map(), getStream: null, queue: [] };
  session = s;

  child.on('error', (e) => console.error(`[chrome-devtools-mcp] spawn error: ${e.message}`));
  child.stdin.on('error', () => { /* EPIPE after kill */ });
  child.on('exit', () => { if (session === s) endSession(); });

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

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/mcp') { res.writeHead(404).end('not found'); return; }
  const sid = req.headers['mcp-session-id'];

  if (req.method === 'GET') {
    if (!session || (sid && sid !== session.id)) { res.writeHead(404).end('no session'); return; }
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    const stream = { res, ping: keepAlive(res) };
    session.getStream = stream;
    for (const m of session.queue.splice(0)) sse(res, m);
    // res (not req) 'close' — req 'close' fires as soon as the body is read.
    res.on('close', () => {
      clearInterval(stream.ping);
      if (session && session.getStream === stream) session.getStream = null;
    });
    return;
  }

  if (req.method === 'DELETE') { endSession(); res.writeHead(200).end(); return; }

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
    if (isInit) { s = startSession(); headers['Mcp-Session-Id'] = s.id; }
    if (!s || (!isInit && sid && sid !== s.id)) { res.writeHead(404).end('no session'); return; }

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

server.listen(PORT, '0.0.0.0', () =>
  console.log(`[chrome-devtools-mcp] streamable-HTTP bridge on 0.0.0.0:${PORT}/mcp`));
