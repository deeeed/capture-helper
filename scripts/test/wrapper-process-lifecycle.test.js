const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { spawn } = require('node:child_process');

test('wrapper forwards termination signals to the dispatched binary', async () => {
  const root = mkdtempSync(join(tmpdir(), 'capture-helper-wrapper-'));
  let wrapper;
  let childPid;
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
    if (process.platform === 'darwin') {
      const native = join(root, 'native', 'capture-helper');
      writeFileSync(
        native,
        `#!/bin/sh
if [ "\${1:-}" = version ]; then
  printf '%s\\n' '{"version":"0.0.0-test"}'
  exit 0
fi
printf '%s' "$$" > "$TEST_READY"
trap ':' TERM
trap ':' INT
while :; do sleep 1; done
`,
      );
      chmodSync(native, 0o755);
    } else {
      writeFileSync(
        join(root, 'bin', 'backend.js'),
        `const fs = require('node:fs');
fs.writeFileSync(process.env.TEST_READY, String(process.pid));
process.on('SIGTERM', () => {});
process.on('SIGINT', () => {});
setInterval(() => {}, 1000);
`,
      );
    }

    wrapper = spawn(
      process.execPath,
      [join(root, 'bin', 'capture-helper.js'), 'hold', '--no-update-check'],
      {
        env: { ...process.env, TEST_READY: ready },
        stdio: 'ignore',
      },
    );
    await waitFor(() => existsSync(ready), 3000);
    childPid = Number(readFileSync(ready, 'utf8'));
    wrapper.kill('SIGTERM');
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(wrapper.exitCode, null);
    wrapper.kill('SIGINT');
    const exit = await waitForExit(wrapper, 3000);

    assert.deepEqual(exit, { code: 130, signal: null });
    await waitFor(() => !isProcessAlive(childPid), 3000);
  } finally {
    if (wrapper && wrapper.exitCode === null && wrapper.signalCode === null) {
      wrapper.kill('SIGKILL');
    }
    if (childPid && isProcessAlive(childPid)) {
      try {
        process.kill(childPid, 'SIGKILL');
      } catch {}
    }
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

function waitForExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error(`Timed out waiting ${timeoutMs}ms for wrapper exit.`)),
      timeoutMs,
    );
    child.once('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      resolve({ code, signal });
    });
  });
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
