const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { spawn } = require('node:child_process');

test('wrapper forwards termination signals to the dispatched binary', async () => {
  const root = mkdtempSync(join(tmpdir(), 'capture-helper-wrapper-'));
  try {
    mkdirSync(join(root, 'bin'), { recursive: true });
    mkdirSync(join(root, 'native'), { recursive: true });
    mkdirSync(join(root, 'scripts', 'lib'), { recursive: true });
    copyFileSync(join(__dirname, '..', '..', 'bin', 'capture-helper.js'), join(root, 'bin', 'capture-helper.js'));
    copyFileSync(
      join(__dirname, '..', 'lib', 'native-binary.js'),
      join(root, 'scripts', 'lib', 'native-binary.js'),
    );
    writeFileSync(
      join(root, 'package.json'),
      JSON.stringify({ name: '@siteed/capture-helper', version: '0.0.0-test' }),
    );

    const ready = join(root, 'ready');
    const terminated = join(root, 'terminated');
    if (process.platform === 'darwin') {
      const native = join(root, 'native', 'capture-helper');
      writeFileSync(
        native,
        `#!/bin/sh
if [ "\${1:-}" = version ]; then
  printf '%s\\n' '{"version":"0.0.0-test"}'
  exit 0
fi
printf ready > "$TEST_READY"
trap ':' TERM
trap 'printf terminated > "$TEST_TERMINATED"; exit 0' INT
while :; do sleep 1; done
`,
      );
      chmodSync(native, 0o755);
    } else {
      writeFileSync(
        join(root, 'bin', 'backend.js'),
        `const fs = require('node:fs');
fs.writeFileSync(process.env.TEST_READY, 'ready');
process.on('SIGTERM', () => {});
process.on('SIGINT', () => {
  fs.writeFileSync(process.env.TEST_TERMINATED, 'terminated');
  process.exit(0);
});
setInterval(() => {}, 1000);
`,
      );
    }

    const wrapper = spawn(
      process.execPath,
      [join(root, 'bin', 'capture-helper.js'), 'hold', '--no-update-check'],
      {
        env: { ...process.env, TEST_READY: ready, TEST_TERMINATED: terminated },
        stdio: 'ignore',
      },
    );
    await waitFor(() => existsSync(ready), 3000);
    wrapper.kill('SIGTERM');
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(wrapper.exitCode, null);
    wrapper.kill('SIGINT');
    const exit = await new Promise((resolve, reject) => {
      wrapper.once('error', reject);
      wrapper.once('exit', (code, signal) => resolve({ code, signal }));
    });

    assert.deepEqual(exit, { code: 130, signal: null });
    assert.equal(existsSync(terminated), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error(`Timed out after ${timeoutMs}ms.`);
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}
