#!/usr/bin/env node
const { copyFileSync, existsSync, mkdirSync, writeFileSync } = require('node:fs');
const { dirname, join } = require('node:path');
const { spawnSync } = require('node:child_process');
const {
  assessNativeBinary,
  decidePostinstallOutcome,
  findSwiftBuildOutput,
  hasSwiftToolchain,
  sha256File,
  teachMessage,
} = require('./lib/native-binary');

if (process.env.SITEED_CAPTURE_HELPER_SKIP_POSTINSTALL) {
  process.exit(0);
}

const root = join(__dirname, '..');

if (process.platform === 'linux') {
  buildLinuxGrabber(root);
  process.exit(0);
}

if (process.platform !== 'darwin') {
  console.error('@siteed/capture-helper supports macOS and Linux only.');
  process.exit(1);
}

const nativeBin = join(root, 'native', 'capture-helper');
const nativeAssessment = assessNativeBinary(root, nativeBin);

if (nativeAssessment.ok) {
  process.exit(0);
}

const swiftAvailable = hasSwiftToolchain();
let buildSucceeded = false;

if (swiftAvailable) {
  const build = spawnSync(
    'swift',
    ['build', '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64'],
    { cwd: root, stdio: 'inherit' },
  );
  if (build.status === 0) {
    const releaseBin = findSwiftBuildOutput(root);
    if (releaseBin) {
      mkdirSync(dirname(nativeBin), { recursive: true });
      copyFileSync(releaseBin, nativeBin);
      try {
        spawnSync(join(root, 'scripts', 'sign-macos-binary.sh'), [nativeBin], { stdio: 'inherit' });
      } catch {
        spawnSync('codesign', ['-s', '-', '--force', '--options', 'runtime', nativeBin], { stdio: 'ignore' });
      }
      writeFileSync(join(root, 'native', 'capture-helper.sha256'), `${sha256File(nativeBin)}\n`);
      buildSucceeded = assessNativeBinary(root, nativeBin).ok;
    }
  }
}

const outcome = decidePostinstallOutcome({
  platform: process.platform,
  nativeAssessment: buildSucceeded ? { ok: true } : nativeAssessment,
  swiftAvailable,
  buildSucceeded,
});

if (outcome.action === 'ready' || outcome.action === 'built') {
  process.exit(0);
}

console.error(teachMessage(outcome.assessment || nativeAssessment));
process.exit(outcome.exitCode || 1);

function buildLinuxGrabber(rootDir) {
  const out = join(rootDir, 'native', 'x11-grabber');
  const src = join(rootDir, 'src', 'linux', 'x11-grabber.c');
  if (existsSync(out)) return;

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