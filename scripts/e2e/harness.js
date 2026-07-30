#!/usr/bin/env node
'use strict';

/*
 * Cross-platform end-to-end validation harness for capture-helper.
 *
 * Drives the actual CLI through every command and asserts real outputs (valid PNG,
 * non-empty MP4 with frames, framed H.264 packets with a keyframe). Works the same on
 * macOS and Linux — it only needs a capturable window to exist on the current display.
 *
 * It does NOT provision a window or a display; scripts/e2e/validate.sh does that per
 * platform (Xvfb sandbox on Linux, a foreground app on macOS) and then runs this.
 *
 * Resolution of the CLI:
 *   - CAPTURE_HELPER env: path to an executable (e.g. "/usr/local/bin/capture-helper");
 *     it is spawned directly, not shell-parsed, so no args/quoting.
 *   - otherwise: `node <repo>/bin/capture-helper.js`.
 *   - E2E_SKIP_STREAM=1 omits the independent framed-stream check.
 *
 * Target selection:
 *   - E2E_TARGET_APP + E2E_TARGET_NAME → --app-name/--window-name (+match)
 *   - E2E_TARGET_NAME                  → --window-name (+name)
 *   - otherwise                        → auto-pick the largest capturable window (--window-id/+id)
 *
 * Exit code 0 = all checks passed, 1 = a check failed.
 */

const { spawnSync, spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO = path.join(__dirname, '..', '..');
const CLI = (() => {
  if (process.env.CAPTURE_HELPER) return { cmd: process.env.CAPTURE_HELPER, base: [] };
  return { cmd: process.execPath, base: [path.join(REPO, 'bin', 'capture-helper.js')] };
})();

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ch-e2e-'));
const results = [];
let targetDesc = '(auto)';

function run(args, opts = {}) {
  return spawnSync(CLI.cmd, [...CLI.base, ...args], { encoding: opts.encoding ?? 'utf8', maxBuffer: 64 * 1024 * 1024, ...opts });
}

function check(name, fn) {
  try {
    const detail = fn();
    results.push({ name, ok: true, detail: detail || '' });
    console.log(`  \x1b[32mPASS\x1b[0m  ${name}${detail ? ' — ' + detail : ''}`);
  } catch (e) {
    results.push({ name, ok: false, detail: e.message });
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name} — ${e.message}`);
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }
function parseEvents(s) { return (s || '').split('\n').map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean); }
function which(bin) {
  for (const d of (process.env.PATH || '').split(path.delimiter)) {
    const p = path.join(d, bin);
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch { /* next */ }
  }
  return null;
}
function parseLastJson(s) {
  const t = (s || '').trim();
  if (!t) throw new Error('empty output');
  try { return JSON.parse(t); } catch { /* not a single (pretty) object — try json-lines */ }
  const lines = t.split('\n').filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) { try { return JSON.parse(lines[i]); } catch { /* keep looking */ } }
  throw new Error('no JSON in output');
}

// ---- target resolution ----

function pickTarget() {
  if (process.env.E2E_TARGET_APP && process.env.E2E_TARGET_NAME) {
    const app = process.env.E2E_TARGET_APP, name = process.env.E2E_TARGET_NAME;
    targetDesc = `app="${app}" name="${name}"`;
    return { args: ['--app-name', app, '--window-name', name], add: `+match ${app}\t${name}` };
  }
  if (process.env.E2E_TARGET_NAME) {
    const name = process.env.E2E_TARGET_NAME;
    targetDesc = `name="${name}"`;
    return { args: ['--window-name', name], add: `+name ${name}` };
  }
  const res = run(['list', '--json']);
  const j = parseLastJson(res.stdout);
  const capturable = (j.windows || [])
    .filter((w) => w.onScreen === true && w.width > 100 && w.height > 100 && w.layer === 0 && (w.width / Math.max(w.height, 1)) < 10)
    .sort((a, b) => b.width * b.height - a.width * a.height);
  assert(capturable.length > 0, 'no capturable window found to target (open an app window first)');
  const w = capturable[0];
  targetDesc = `id=${w.id} app="${w.app}" "${w.title}" ${w.width}x${w.height}`;
  return { args: ['--window-id', String(w.id)], add: `+id ${w.id}` };
}

// ---- framed stream collection ----

function collectFramedStream(addCmd, ms) {
  return new Promise((resolve) => {
    const p = spawn(CLI.cmd, [...CLI.base, 'stream', '--framed', '--max-fps', '10', '--max-size', '360'],
      { stdio: ['pipe', 'pipe', 'pipe'] });
    const out = [];
    let stderr = '';
    p.stdout.on('data', (c) => out.push(c));
    p.stderr.on('data', (c) => { stderr += c.toString(); });
    p.stdin.write(addCmd + '\n');
    setTimeout(() => {
      try { p.stdin.write('-0\n'); } catch { /* */ }
      try { p.stdin.end(); } catch { /* */ }
    }, ms);
    p.on('exit', (code) => resolve({ buf: Buffer.concat(out), stderr, code }));
    p.on('error', (e) => resolve({ buf: Buffer.alloc(0), stderr, code: null, error: e }));
    setTimeout(() => { try { p.kill('SIGTERM'); } catch { /* */ } }, ms + 4000);
  });
}

function parseFramed(buf) {
  let off = 0, packets = 0, keyframes = 0, badFlags = 0;
  let truncated = false;
  const indexes = new Set();
  const annexb = new Map(); // index -> concatenated Annex B payloads
  while (off + 6 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const flags = buf[off + 4];
    const idx = buf[off + 5];
    off += 6;
    if (off + len > buf.length) { truncated = true; break; } // partial payload
    const payload = Buffer.from(buf.subarray(off, off + len)); // copy out of the view
    off += len;
    packets++;
    if (flags & 1) keyframes++;
    if (flags & ~1) badFlags++; // only bit 0 (keyframe) is defined; rest reserved 0
    indexes.add(idx);
    annexb.set(idx, annexb.has(idx) ? Buffer.concat([annexb.get(idx), payload]) : payload);
  }
  if (off !== buf.length) truncated = true; // trailing bytes that aren't a full packet
  return { packets, keyframes, indexes: [...indexes], annexb, truncated, badFlags };
}

// ---- main ----

async function main() {
  console.log(`capture-helper e2e validation`);
  console.log(`  CLI: ${CLI.cmd} ${CLI.base.join(' ')}`.trim());
  console.log(`  platform: ${process.platform}  tmp: ${TMP}\n`);

  check('version reports build info', () => {
    const j = parseLastJson(run(['version', '--json']).stdout);
    assert(j.version, 'no version');
    assert(j.os, 'no os field');
    return `v${j.version} os=${j.os} arch=${j.architecture}`;
  });

  check('doctor passes (no required failures)', () => {
    const r = run(['doctor', '--json']);
    const j = parseLastJson(r.stdout);
    assert(j.summary, 'no doctor summary');
    assert(j.summary.requiredFailureCount === 0, `required failures: ${JSON.stringify(j.summary.requiredFailureCodes)}`);
    return 'ok';
  });

  let target;
  check('list + target selection', () => {
    target = pickTarget();
    return targetDesc;
  });
  if (!target) { finish(); return; }

  check('resolve selects the target', () => {
    const j = parseLastJson(run(['resolve', ...target.args]).stdout);
    assert(j.selected && j.selected.id != null, 'no selected window');
    return `selector=${j.selector}`;
  });

  check('snapshot writes a valid PNG', () => {
    const out = path.join(TMP, 'shot.png');
    const r = run(['snapshot', ...target.args, '-o', out]);
    assert(r.status === 0, `exit ${r.status}: ${(r.stderr || '').trim()}`);
    const b = fs.readFileSync(out);
    assert(b.length > 0, 'empty file');
    assert(b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47, 'not a PNG (bad magic)');
    return `${b.length} bytes`;
  });

  check('record writes a non-empty MP4 with frames', () => {
    const out = path.join(TMP, 'rec.mp4');
    const r = run(['record', ...target.args, '--duration', '2', '--max-size', '480', '-o', out]);
    assert(r.status === 0, `exit ${r.status}: ${(r.stderr || '').trim().split('\n').pop()}`);
    const ev = (r.stderr || '').split('\n').map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    const done = ev.find((e) => e.type === 'record_complete');
    assert(done, 'no record_complete event');
    const sz = fs.statSync(out).size;
    assert(sz > 1000, `suspiciously small MP4 (${sz} bytes)`);
    if (done.frames != null) assert(done.frames > 0, `record_complete reported ${done.frames} frames`);
    return `${sz} bytes${done.frames != null ? ', ' + done.frames + ' frames' : ''}`;
  });

  if (process.env.E2E_SKIP_STREAM !== '1') {
    await new Promise((res) => {
      collectFramedStream(target.add, 2500).then(({ buf, stderr, code, error }) => {
        check('stream --framed yields decodable H.264', () => {
          assert(!error, `stream process error: ${error && error.message}`);
          const events = parseEvents(stderr);
          assert(events.some((e) => e.type === 'added'), `no 'added' event (stderr: ${stderr.trim().split('\n').pop()})`);
          const failures = events.filter((e) => e.type === 'add_failed' || e.type === 'stream_stopped' || (e.type === 'error'));
          assert(failures.length === 0, `stream reported errors: ${JSON.stringify(failures[0])}`);
          assert(code === 0, `stream exited with code ${code} (expected clean 0 after -0/EOF)`);
          const added = new Set(events.filter((e) => e.type === 'added').map((e) => e.index));
          const f = parseFramed(buf);
          assert(!f.truncated, 'framed output has trailing/partial bytes (incomplete packet framing)');
          assert(f.badFlags === 0, 'framed packets set reserved flag bits (only bit 0 = keyframe is defined)');
          assert(f.indexes.every((i) => added.has(i)), `framed packet index not in 'added' set: got ${f.indexes} added ${[...added]}`);
          assert(f.packets > 0, 'no framed packets');
          assert(f.keyframes > 0, 'no keyframe in stream');
          // Best-effort: actually decode the extracted Annex B to prove the bytes are real H.264.
          let decoded = 'DECODE NOT VALIDATED (ffprobe not found — install ffmpeg for full validation)';
          const probe = which('ffprobe');
          if (probe) {
            const idx = f.indexes[0];
            const h264 = path.join(TMP, 'framed.h264');
            fs.writeFileSync(h264, f.annexb.get(idx));
            const r = spawnSync(probe, ['-v', 'error', '-count_frames', '-select_streams', 'v:0',
              '-show_entries', 'stream=nb_read_frames', '-of', 'default=nokey=1:noprint_wrappers=1', h264], { encoding: 'utf8' });
            const n = parseInt((r.stdout || '').trim(), 10);
            assert(Number.isFinite(n) && n > 0, `ffprobe could not decode the framed stream: ${(r.stderr || '').trim() || 'no frames'}`);
            decoded = `${n} frames decoded`;
          }
          return `${f.packets} packets, ${f.keyframes} keyframes, ${decoded}`;
        });
        res();
      });
    });
  }

  finish();
}

function finish() {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* */ }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed.`);
  process.exit(failed.length ? 1 : 0);
}

main();
