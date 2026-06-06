#!/usr/bin/env node
const { copyFileSync, existsSync, mkdirSync } = require('node:fs');
const { dirname, join } = require('node:path');
const { spawnSync } = require('node:child_process');

if (process.env.SITEED_CAPTURE_HELPER_SKIP_POSTINSTALL) {
  process.exit(0);
}

const root = join(__dirname, '..');

if (process.platform === 'linux') {
  buildLinuxGrabber(root);
  process.exit(0);
}

if (process.platform !== 'darwin') {
  console.warn('@siteed/capture-helper supports macOS and Linux only.');
  process.exit(0);
}

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

function buildLinuxGrabber(rootDir) {
  const out = join(rootDir, 'native', 'x11-grabber');
  const src = join(rootDir, 'src', 'linux', 'x11-grabber.c');
  if (existsSync(out)) return; // already built

  if (!existsSync(src)) {
    console.warn(`capture-helper: grabber source missing at ${src}; Linux capture unavailable.`);
    return;
  }
  if (spawnSync('gcc', ['--version'], { stdio: 'ignore' }).status !== 0) {
    console.warn('capture-helper: gcc not found. Install build deps:\n  sudo apt install -y gcc ffmpeg libx11-dev libxcomposite-dev libxdamage-dev libxfixes-dev libxext-dev');
    return;
  }
  const header = '/usr/include/X11/extensions/Xcomposite.h';
  if (!existsSync(header)) {
    console.warn('capture-helper: X11 development headers missing. Install:\n  sudo apt install -y libx11-dev libxcomposite-dev libxdamage-dev libxfixes-dev libxext-dev');
    return;
  }

  mkdirSync(dirname(out), { recursive: true });
  const build = spawnSync('gcc', ['-O2', '-o', out, src, '-lX11', '-lXcomposite', '-lXext'], { stdio: 'inherit' });
  if (build.status !== 0) {
    console.warn('capture-helper: failed to compile x11-grabber; Linux capture unavailable.');
    return;
  }
  if (spawnSync('ffmpeg', ['-version'], { stdio: 'ignore' }).status !== 0) {
    console.warn('capture-helper: ffmpeg not found (required on Linux). Install: sudo apt install -y ffmpeg');
  }
}
