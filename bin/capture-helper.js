#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const { join } = require('node:path');

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

const result = spawnSync(binary, process.argv.slice(2), { stdio: 'inherit' });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 0);
