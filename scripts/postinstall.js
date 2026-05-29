#!/usr/bin/env node
const { copyFileSync, existsSync, mkdirSync } = require('node:fs');
const { dirname, join } = require('node:path');
const { spawnSync } = require('node:child_process');

if (process.env.SITEED_CAPTURE_HELPER_SKIP_POSTINSTALL) {
  process.exit(0);
}

if (process.platform !== 'darwin') {
  console.warn('@siteed/capture-helper is only supported on macOS.');
  process.exit(0);
}

const root = join(__dirname, '..');
const nativeBin = join(root, 'native', 'capture-helper');
const releaseBin = join(root, '.build', 'release', 'capture-helper');

function binaryWorks(path) {
  if (!existsSync(path)) return false;
  const result = spawnSync(path, ['version'], { encoding: 'utf8' });
  return result.status === 0 && result.stdout.includes('"version"');
}

if (binaryWorks(nativeBin)) {
  process.exit(0);
}

const swift = spawnSync('swift', ['--version'], { stdio: 'ignore' });
if (swift.status !== 0) {
  console.warn('Swift toolchain not found; run `swift build -c release` manually before using capture-helper.');
  process.exit(0);
}

const build = spawnSync('swift', ['build', '-c', 'release'], { cwd: root, stdio: 'inherit' });
if (build.status !== 0) {
  console.warn('Failed to build native capture-helper binary during postinstall.');
  process.exit(0);
}

mkdirSync(dirname(nativeBin), { recursive: true });
copyFileSync(releaseBin, nativeBin);
