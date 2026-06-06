#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { existsSync, readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const os = require('node:os');
const https = require('node:https');

const PKG = require('../package.json');
const args = process.argv.slice(2);
// `--no-update-check` is a wrapper-only flag: consume it so the native binary never sees it.
const UPDATE_CHECK_DISABLED = args.includes('--no-update-check');
const childArgs = args.filter((a) => a !== '--no-update-check');

// macOS uses the native Swift binary (ScreenCaptureKit). Other platforms use the
// generic Node backend (bin/backend.js), which loads a per-platform adapter +
// native grabber. All speak the same CLI/protocol contract (docs/protocol.md).
// win32 is wired as the Windows-ready seam: until bin/platforms/windows.js ships it
// exits with a clear `unsupported_platform` error (and package.json `os` keeps npm
// from installing on Windows), rather than falling through to the macOS binary path.
const NODE_BACKEND_PLATFORMS = new Set(['linux', 'win32']);
if (NODE_BACKEND_PLATFORMS.has(process.platform)) {
  const backend = join(__dirname, 'backend.js');
  const result = spawnSync(process.execPath, [backend, ...childArgs], { stdio: 'inherit' });
  if (result.error) { console.error(result.error.message); process.exit(1); }
  finish(result.status);
} else {
  const candidates = [
    process.env.SITEED_CAPTURE_HELPER_BIN,
    join(__dirname, '..', 'native', 'capture-helper'),
    join(__dirname, '..', '.build', 'release', 'capture-helper'),
    '/opt/homebrew/bin/capture-helper',
    '/usr/local/bin/capture-helper',
  ].filter(Boolean);

  const binary = candidates.find((candidate) => existsSync(candidate));
  if (!binary) {
    console.error([
      'capture-helper native binary was not found.',
      'Run `swift build -c release` or `npm run build:native`, then retry.',
      'You can also set SITEED_CAPTURE_HELPER_BIN=/path/to/capture-helper.',
    ].join('\n'));
    process.exit(127);
  }

  const result = spawnSync(binary, childArgs, { stdio: 'inherit' });
  if (result.error) { console.error(result.error.message); process.exit(1); }
  finish(result.status);
}

// Exit, but first surface a one-line upgrade hint for diagnostic commands. The check is
// best-effort and never blocks: it only runs for `doctor`/`version`, uses a 24h cache, a
// short network timeout, and a hard cap so it can never hang the CLI.
function finish(status) {
  const code = status ?? 0;
  const cap = setTimeout(() => process.exit(code), 2500);
  if (typeof cap.unref === 'function') cap.unref();
  maybeNotifyUpdate().finally(() => process.exit(code));
}

async function maybeNotifyUpdate() {
  try {
    if (process.env.CAPTURE_HELPER_SKIP_UPDATE_CHECK || UPDATE_CHECK_DISABLED) return;
    const cmd = childArgs.find((a) => !a.startsWith('-'));
    if (cmd !== 'doctor' && cmd !== 'version') return; // only diagnostic commands; never hot paths
    const latest = await latestVersion(PKG.name);
    if (latest && isNewer(latest, PKG.version)) {
      process.stderr.write(`\ncapture-helper: update available ${PKG.version} -> ${latest}. Upgrade: npm i -g ${PKG.name}\n`);
    }
  } catch { /* never let the update check affect the command */ }
}

function cacheFile() {
  const uid = process.getuid ? process.getuid() : 'x';
  return join(os.tmpdir(), `siteed-capture-helper-update-${uid}.json`);
}

function latestVersion(name) {
  return new Promise((resolve) => {
    try {
      const c = JSON.parse(readFileSync(cacheFile(), 'utf8'));
      if (c && c.latest && Date.now() - c.checkedAt < 24 * 3600 * 1000) return resolve(c.latest);
    } catch { /* no/expired cache */ }
    const url = `https://registry.npmjs.org/-/package/${encodeURIComponent(name)}/dist-tags`;
    const req = https.get(url, { timeout: 1500, headers: { accept: 'application/json' } }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return resolve(null); }
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => {
        try {
          const latest = JSON.parse(body).latest || null;
          try { writeFileSync(cacheFile(), JSON.stringify({ checkedAt: Date.now(), latest })); } catch { /* cache best-effort */ }
          resolve(latest);
        } catch { resolve(null); }
      });
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}

// Compare release cores (ignores prerelease tags) — returns true if `a` > `b`.
function isNewer(a, b) {
  const pa = String(a).split('-')[0].split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('-')[0].split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) { if ((pa[i] || 0) > (pb[i] || 0)) return true; if ((pa[i] || 0) < (pb[i] || 0)) return false; }
  return false;
}
