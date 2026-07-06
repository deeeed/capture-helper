const { existsSync, readFileSync } = require('node:fs');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');

const TEACH_BREW = 'brew install deeeed/tap/capture-helper';
const TEACH_NPM = 'npm install -g @siteed/capture-helper';
const TEACH_BUILD = 'swift build -c release --arch arm64 --arch x86_64 && npm run build:native';

function binaryWorks(path) {
  if (!path || !existsSync(path)) {
    return { ok: false, reason: 'missing', path: path || null };
  }
  const result = spawnSync(path, ['version'], { encoding: 'utf8', timeout: 15000 });
  if (result.error) {
    const code = result.error.code;
    if (code === 'ENOENT') return { ok: false, reason: 'missing', path };
    const detail = result.error.message || String(result.error);
    if (/bad cpu type|not compatible|cannot execute binary/i.test(detail)) {
      return { ok: false, reason: 'arch_mismatch', path, detail };
    }
    return { ok: false, reason: 'exec_failed', path, detail };
  }
  const combined = `${result.stderr || ''}\n${result.stdout || ''}`;
  if (result.status !== 0) {
    if (/bad cpu type|not compatible|cannot execute binary/i.test(combined)) {
      return { ok: false, reason: 'arch_mismatch', path, detail: combined.trim() };
    }
    return { ok: false, reason: 'version_failed', path, detail: combined.trim() };
  }
  if (!result.stdout.includes('"version"')) {
    return { ok: false, reason: 'invalid_output', path };
  }
  return { ok: true, path };
}

function hasSwiftToolchain() {
  return spawnSync('swift', ['--version'], { stdio: 'ignore' }).status === 0;
}

function sha256File(path) {
  const data = readFileSync(path);
  return createHash('sha256').update(data).digest('hex');
}

function verifyBundledChecksum(root, binaryPath) {
  const checksumPath = join(root, 'native', 'capture-helper.sha256');
  if (!existsSync(checksumPath) || !existsSync(binaryPath)) return { ok: true, skipped: true };
  const expected = readFileSync(checksumPath, 'utf8').trim().split(/\s+/)[0];
  if (!/^[0-9a-f]{64}$/i.test(expected)) return { ok: true, skipped: true };
  const actual = sha256File(binaryPath);
  if (actual === expected) return { ok: true };
  return { ok: false, expected, actual };
}

function nativeBinaryDoctorCheck(assessment) {
  const reason = assessment?.reason || 'broken';
  const code = reason === 'missing' ? 'native_binary_missing' : 'native_binary_broken';
  let message = 'native binary is present but not executable or failed version check';
  if (reason === 'missing') message = 'native binary was not found';
  else if (reason === 'arch_mismatch') message = 'native binary architecture does not match this host';
  else if (reason === 'checksum_mismatch') message = 'native binary failed checksum verification';
  else if (reason === 'version_failed' || reason === 'invalid_output' || reason === 'exec_failed') {
    message = 'native binary failed version check';
  }
  return { code, message };
}

function teachMessage(assessment) {
  const { message } = nativeBinaryDoctorCheck(assessment);
  const lines = [`capture-helper install failed: ${message}.`];
  if (assessment?.detail) lines.push(`Detail: ${assessment.detail}`);
  lines.push('', 'Next:');
  lines.push(`  ${TEACH_BREW}`);
  lines.push(`  ${TEACH_NPM}`);
  lines.push(`  ${TEACH_BUILD}`);
  return lines.join('\n');
}

function wrapperDoctorHuman(assessment) {
  const { code, message } = nativeBinaryDoctorCheck(assessment);
  const lines = [
    'capture-helper doctor: FAILED',
    `[FAIL] native binary (${code}) — ${message}`,
  ];
  if (assessment?.path) lines.push(`  path: ${assessment.path}`);
  if (assessment?.detail) lines.push(`  detail: ${assessment.detail}`);
  lines.push('', 'To fix:');
  lines.push(`  - ${TEACH_BREW}`);
  lines.push(`  - ${TEACH_NPM}`);
  lines.push(`  - from source: ${TEACH_BUILD}`);
  lines.push('  - override: SITEED_CAPTURE_HELPER_BIN=/path/to/capture-helper');
  return `${lines.join('\n')}\n`;
}

function wrapperDoctorPayload(assessment, pkgVersion) {
  const { code, message } = nativeBinaryDoctorCheck(assessment);

  return {
    type: 'doctor',
    ok: false,
    build: {
      name: '@siteed/capture-helper',
      binary: 'capture-helper',
      version: pkgVersion,
      wrapper: true,
    },
    checks: [{
      id: 'native_binary',
      name: 'native binary',
      ok: false,
      code,
      required: true,
      message,
      value: assessment?.path || null,
      details: assessment?.detail ? { error: assessment.detail } : {},
    }],
    summary: {
      requiredFailureCount: 1,
      optionalFailureCount: 0,
      requiredFailureCodes: [code],
      optionalFailureCodes: [],
    },
    teach: {
      brew: TEACH_BREW,
      npm: TEACH_NPM,
      build: TEACH_BUILD,
    },
  };
}

function findSwiftBuildOutput(root) {
  const candidates = [
    join(root, '.build', 'apple', 'Products', 'Release', 'capture-helper'),
    join(root, '.build', 'release', 'capture-helper'),
  ];
  return candidates.find((candidate) => existsSync(candidate)) || null;
}

function assessNativeBinary(root, binaryPath) {
  const checksum = verifyBundledChecksum(root, binaryPath);
  if (!checksum.ok) {
    return { ok: false, reason: 'checksum_mismatch', path: binaryPath, detail: `expected ${checksum.expected}, got ${checksum.actual}` };
  }
  return binaryWorks(binaryPath);
}

function decidePostinstallOutcome({ platform, nativeAssessment, swiftAvailable, buildSucceeded }) {
  if (platform === 'linux') return { action: 'linux_handled' };
  if (platform !== 'darwin') return { action: 'unsupported', exitCode: 0 };
  if (nativeAssessment.ok) return { action: 'ready', exitCode: 0 };
  if (swiftAvailable && buildSucceeded) return { action: 'built', exitCode: 0 };
  if (swiftAvailable && !buildSucceeded) {
    return { action: 'fail', exitCode: 1, assessment: nativeAssessment, reason: 'build_failed' };
  }
  return { action: 'fail', exitCode: 1, assessment: nativeAssessment, reason: 'no_swift' };
}

module.exports = {
  TEACH_BREW,
  TEACH_NPM,
  TEACH_BUILD,
  binaryWorks,
  hasSwiftToolchain,
  sha256File,
  verifyBundledChecksum,
  nativeBinaryDoctorCheck,
  teachMessage,
  wrapperDoctorHuman,
  wrapperDoctorPayload,
  findSwiftBuildOutput,
  assessNativeBinary,
  decidePostinstallOutcome,
};