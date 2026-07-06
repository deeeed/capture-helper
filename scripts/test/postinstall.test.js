const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  decidePostinstallOutcome,
  teachMessage,
  wrapperDoctorHuman,
  wrapperDoctorPayload,
} = require('../lib/native-binary');

test('decidePostinstallOutcome returns ready when native binary works', () => {
  const outcome = decidePostinstallOutcome({
    platform: 'darwin',
    nativeAssessment: { ok: true },
    swiftAvailable: false,
    buildSucceeded: false,
  });
  assert.equal(outcome.action, 'ready');
  assert.equal(outcome.exitCode, 0);
});

test('decidePostinstallOutcome fails loudly without swift when native binary is broken', () => {
  const assessment = { ok: false, reason: 'version_failed', path: '/tmp/capture-helper' };
  const outcome = decidePostinstallOutcome({
    platform: 'darwin',
    nativeAssessment: assessment,
    swiftAvailable: false,
    buildSucceeded: false,
  });
  assert.equal(outcome.action, 'fail');
  assert.equal(outcome.exitCode, 1);
  assert.equal(outcome.reason, 'no_swift');
  assert.match(teachMessage(assessment), /brew install deeeed\/tap\/capture-helper/);
});

test('decidePostinstallOutcome fails when swift build does not recover binary', () => {
  const assessment = { ok: false, reason: 'arch_mismatch', path: '/tmp/capture-helper' };
  const outcome = decidePostinstallOutcome({
    platform: 'darwin',
    nativeAssessment: assessment,
    swiftAvailable: true,
    buildSucceeded: false,
  });
  assert.equal(outcome.action, 'fail');
  assert.equal(outcome.reason, 'build_failed');
});

test('wrapperDoctorPayload reports native_binary_missing for missing binary', () => {
  const payload = wrapperDoctorPayload({ reason: 'missing', path: null }, '0.2.2');
  assert.equal(payload.ok, false);
  assert.equal(payload.checks[0].code, 'native_binary_missing');
  assert.equal(payload.teach.brew, 'brew install deeeed/tap/capture-helper');
});

test('wrapperDoctorPayload reports native_binary_broken for arch mismatch', () => {
  const payload = wrapperDoctorPayload({ reason: 'arch_mismatch', path: '/tmp/bin' }, '0.2.2');
  assert.equal(payload.checks[0].code, 'native_binary_broken');
  assert.match(payload.checks[0].message, /architecture/);
});

test('wrapperDoctorHuman matches native doctor plain output shape', () => {
  const text = wrapperDoctorHuman({ reason: 'missing', path: '/tmp/native/capture-helper' });
  assert.match(text, /^capture-helper doctor: FAILED\n/);
  assert.match(text, /\[FAIL\] native binary \(native_binary_missing\)/);
  assert.match(text, /To fix:\n  - brew install deeeed\/tap\/capture-helper/);
});