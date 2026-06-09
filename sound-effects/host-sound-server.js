#!/usr/bin/env node
// Tiny HTTP daemon: container hits GET /play/<filename>, host runs afplay.
// Bound on 0.0.0.0 so host.docker.internal from the container can reach it.
// Filename whitelist: only files inside SOUNDS_DIR, no path separators.

const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = parseInt(process.env.SOUND_PORT || '4767', 10);
const SOUNDS_DIR = path.resolve(process.env.SOUNDS_DIR || path.join(__dirname, 'sounds'));

const server = http.createServer((req, res) => {
  const m = req.url.match(/^\/play\/([A-Za-z0-9._-]+)$/);
  if (!m) {
    res.writeHead(404).end('not found');
    return;
  }
  const filepath = path.resolve(SOUNDS_DIR, m[1]);
  if (!filepath.startsWith(SOUNDS_DIR + path.sep) || !fs.existsSync(filepath)) {
    res.writeHead(404).end('no such sound');
    return;
  }
  spawn('afplay', [filepath], { detached: true, stdio: 'ignore' }).unref();
  res.writeHead(204).end();
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[claude-sound] listening on 0.0.0.0:${PORT}, sounds=${SOUNDS_DIR}`);
});
