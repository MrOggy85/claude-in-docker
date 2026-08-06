#!/usr/bin/env node
// Tiny HTTP daemon: container hits GET /play/<filename>, host plays it.
// Bound on 0.0.0.0 so host.docker.internal from the container can reach it.
// Filename whitelist: only files inside SOUNDS_DIR, no path separators.

const http = require('http');
const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = parseInt(process.env.SOUND_PORT || '4767', 10);
const SOUNDS_DIR = path.resolve(process.env.SOUNDS_DIR || path.join(__dirname, 'sounds'));

function commandExists(cmd) {
  try {
    execSync(`command -v ${cmd}`, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

// macOS ships afplay; Linux has no single standard player, so try the common
// ones in order (first one present on $PATH wins). Resolved once at startup,
// not per request.
function resolvePlayer() {
  if (process.platform === 'darwin') return ['afplay', []];
  const candidates = [
    ['paplay', []],
    ['ffplay', ['-nodisp', '-autoexit', '-loglevel', 'quiet']],
    ['aplay', []],
    ['mpg123', ['-q']],
  ];
  for (const [cmd, args] of candidates) {
    if (commandExists(cmd)) return [cmd, args];
  }
  return null;
}

const PLAYER = resolvePlayer();
if (!PLAYER) {
  console.warn('[claude-sound] no audio player found (tried paplay, ffplay, aplay, mpg123) — /play requests will fail');
} else {
  console.log(`[claude-sound] using player: ${PLAYER[0]}`);
}

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
  if (!PLAYER) {
    res.writeHead(500).end('no audio player available on host');
    return;
  }
  const [cmd, args] = PLAYER;
  spawn(cmd, [...args, filepath], { detached: true, stdio: 'ignore' }).unref();
  res.writeHead(204).end();
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[claude-sound] listening on 0.0.0.0:${PORT}, sounds=${SOUNDS_DIR}`);
});
