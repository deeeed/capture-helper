#!/usr/bin/env node
'use strict';

/*
 * Generic (platform-agnostic) backend for capture-helper.
 *
 * Reproduces the macOS CLI/protocol contract (see docs/protocol.md) using a native
 * per-window grabber plus ffmpeg for encoding. Everything platform-specific (the
 * grabber binary, capture environment, display discovery, readiness checks) lives in
 * a platform adapter under bin/platforms/<platform>.js. This core is shared across
 * platforms; adding Windows means adding one adapter + a Windows.Graphics.Capture
 * grabber that honours the same grabber CLI contract — the core does not change.
 *
 * The macOS Swift binary remains the implementation on darwin; bin/capture-helper.js
 * dispatches here for the Node-backed platforms.
 *
 * Commands: list, resolve, snapshot, record, capture, stream (--framed),
 *           doctor, permissions, version.
 */

const { spawn, spawnSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const fs = require('node:fs');
const path = require('node:path');

const PKG = require('../package.json');

/* ---- output helpers (mirror JSONEvents.swift) ------------------------- */

function writeStdout(buf) {
  // synchronous write to fd 1 keeps binary media ordering correct
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(1, buf, off, buf.length - off);
    } catch (e) {
      if (e.code === 'EAGAIN') continue;
      if (e.code === 'EPIPE') process.exit(0);
      throw e;
    }
  }
}

function emitJsonLine(obj, toStderr = true) {
  const line = JSON.stringify(sortKeys(obj)) + '\n';
  if (toStderr) process.stderr.write(line);
  else process.stdout.write(line);
}

function emitJsonObject(obj, toStderr = false) {
  const text = JSON.stringify(sortKeys(obj), null, 2) + '\n';
  if (toStderr) process.stderr.write(text);
  else process.stdout.write(text);
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value).sort()) out[k] = sortKeys(value[k]);
    return out;
  }
  return value;
}

function logEvent(obj) { emitJsonLine(obj, true); }
function log(type, msg) { emitJsonLine({ type, msg }, true); }
function logError(code, message, context) {
  emitJsonLine(Object.assign({ type: 'error', code, message }, context || {}), true);
}

class CaptureError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

/* ---- platform adapter ------------------------------------------------- */

function adapterNameFor(platform) {
  if (platform === 'linux') return 'linux';
  if (platform === 'win32') return 'windows';
  return null;
}

function loadAdapter() {
  const name = adapterNameFor(process.platform);
  if (!name) { logError('unsupported_platform', `no capture-helper backend for platform '${process.platform}'`); process.exit(1); }
  // Resolve the adapter module first: only a missing adapter FILE is "unsupported platform".
  let resolved;
  try {
    resolved = require.resolve('./platforms/' + name);
  } catch {
    logError('unsupported_platform', `platform '${name}' backend is not available yet`);
    process.exit(1);
  }
  // A real error thrown *inside* the adapter (incl. its own missing deps) is a true failure.
  try {
    return require(resolved);
  } catch (e) {
    logError('unexpected_error', `failed to load ${name} adapter: ${e && e.stack ? e.stack : e}`);
    process.exit(1);
  }
}

const adapter = loadAdapter();

/* ---- arg parsing (mirror CLI.swift parseArgs) ------------------------- */

function parseArgs(argv) {
  const cfg = {
    command: 'capture',
    initialNames: [],
    initialAppName: null,
    initialPid: null,
    initialWindowId: null,
    maxFps: 15,
    maxSize: 720,
    framed: false,
    json: true,
    legacyJsonLines: false,
    outputPath: null,
    durationSeconds: null,
    ffmpegPath: null,
    encoder: process.env.CAPTURE_HELPER_ENCODER || adapter.defaultEncoder,
    openOutput: false,
    listOnScreenOnly: false,
    listCapturableOnly: false,
    listAll: false,
    openPermissions: false,
    requestPermissions: false,
  };

  let sawCommand = false;
  let i = 0;
  const usage = () => { printUsage(); process.exit(0); };

  if (i < argv.length) {
    switch (argv[i]) {
      case 'capture': cfg.command = 'capture'; sawCommand = true; i++; break;
      case 'stream': cfg.command = 'capture'; cfg.framed = true; sawCommand = true; i++; break;
      case 'list': case 'windows': cfg.command = 'list'; sawCommand = true; i++; break;
      case 'doctor': cfg.command = 'doctor'; sawCommand = true; i++; break;
      case 'record': cfg.command = 'record'; sawCommand = true; i++; break;
      case 'resolve': cfg.command = 'resolve'; sawCommand = true; i++; break;
      case 'snapshot': cfg.command = 'snapshot'; sawCommand = true; i++; break;
      case 'permissions':
        cfg.command = 'permissions'; cfg.openPermissions = true; cfg.requestPermissions = true; sawCommand = true; i++; break;
      case 'version': cfg.command = 'version'; sawCommand = true; i++; break;
      case 'help': usage(); break;
      default: break;
    }
  }

  const need = () => { if (i + 1 >= argv.length) usage(); return argv[++i]; };
  for (; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--window-name': case '--name': cfg.initialNames.push(need()); break;
      case '--window-names': cfg.initialNames.push(...need().split(',')); break;
      case '--app-name': case '--app': cfg.initialAppName = need(); break;
      case '--pid': { const v = parseInt(need(), 10); if (!Number.isFinite(v)) usage(); cfg.initialPid = v; break; }
      case '--window-id': { const v = parseInt(need(), 10); if (!Number.isFinite(v)) usage(); cfg.initialWindowId = v >>> 0; break; }
      case '--max-fps': { const v = parseInt(need(), 10); if (!(v > 0)) usage(); cfg.maxFps = Math.min(v, 1000); break; } // grabber caps interval at 1000fps
      case '--max-size': { const v = parseInt(need(), 10); if (!(v > 0)) usage(); cfg.maxSize = v; break; }
      case '--output': case '-o': cfg.outputPath = need(); break;
      case '--duration': { const v = parseFloat(need()); if (!(v > 0)) usage(); cfg.durationSeconds = v; break; }
      case '--ffmpeg': cfg.ffmpegPath = need(); break;
      case '--encoder': cfg.encoder = need(); break;
      case '--open': cfg.openOutput = true; break;
      case '--on-screen': cfg.listOnScreenOnly = true; break;
      case '--capturable': cfg.listCapturableOnly = true; break;
      case '--all': cfg.listAll = true; cfg.listOnScreenOnly = false; cfg.listCapturableOnly = false; break;
      case '--open-permissions': cfg.openPermissions = true; break;
      case '--request-permission': case '--request-permissions': cfg.requestPermissions = true; break;
      case '--status-only': cfg.openPermissions = false; cfg.requestPermissions = false; break;
      case '--framed': cfg.framed = true; break;
      case '--json': cfg.json = true; break;
      case '--human': case '--text': case '-H': cfg.json = false; break;
      case '--json-lines': case '--jsonl': cfg.legacyJsonLines = true; break;
      case '-l': cfg.command = 'list'; cfg.json = false; break;
      case '--list-windows': cfg.command = 'list'; cfg.legacyJsonLines = true; sawCommand = true; break;
      case '--version': case '-v': cfg.command = 'version'; break;
      case '--help': usage(); break;
      case '-h':
        if (['list', 'doctor', 'permissions', 'version'].includes(cfg.command)) cfg.json = false;
        else usage();
        break;
      default:
        process.stderr.write(`unknown argument: ${arg}\n`);
        usage();
    }
  }

  if (!sawCommand && cfg.command === 'capture' &&
      cfg.initialWindowId == null && cfg.initialPid == null && cfg.initialNames.length === 0) {
    cfg.command = 'list';
    if (argv.length === 0) cfg.json = false;
  }
  if (cfg.command === 'list' && !cfg.json && !cfg.listAll) {
    cfg.listOnScreenOnly = true;
    cfg.listCapturableOnly = true;
  }
  return cfg;
}

function printUsage() {
  process.stderr.write(`capture-helper — per-window capture for agents and automation (${adapter.platform})

Usage:
  capture-helper
  capture-helper capture [target options] [--max-fps N] [--max-size N]
  capture-helper stream [target options] [--framed]
  capture-helper record [target options] --output PATH [--duration seconds]
  capture-helper resolve [target options] [--json]
  capture-helper snapshot [target options] --output PATH
  capture-helper list [--json | --json-lines | --human]
  capture-helper doctor [--json]
  capture-helper version

Target options:
  --window-id <id>        Native window id from \`list\`
  --window-name <string>  Window title substring. Can repeat.
  --app-name <string>     Restrict title matching to exact app/class name.
  --pid <int>             Capture largest suitable window owned by PID.

Capture options:
  --max-fps <int>         Max frame rate (default: 15)
  --max-size <int>        Max dimension in pixels (default: 720)
  --framed                Framed output with stdin commands
  --encoder <name>        ffmpeg encoder (default: ${adapter.defaultEncoder}; e.g. h264_nvenc)

Framed stdin commands:
  +name <substring>       Add window by title substring
  +match <app>\\t<title>   Add window by app name + title substring
  +pid <int>              Add largest window owned by PID
  +id <int>               Add exact window id
  -<index>                Remove window at index
`);
}

/* ---- tool discovery + grabber contract -------------------------------- */

function findExecutable(nameOrPath) {
  if (!nameOrPath) return null;
  const ok = (p) => { try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; } };
  // Explicit path (contains a separator) — use as-is.
  if (nameOrPath.includes('/') || nameOrPath.includes(path.sep)) return ok(nameOrPath) ? nameOrPath : null;
  // Bare name — search PATH, honouring PATHEXT on Windows.
  const exts = process.platform === 'win32'
    ? ['', ...(process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';').filter(Boolean)]
    : [''];
  for (const d of (process.env.PATH || '').split(path.delimiter)) {
    if (!d) continue;
    for (const ext of exts) {
      const p = path.join(d, nameOrPath + ext);
      if (ok(p)) return p;
    }
  }
  return null;
}

function ffmpegPath(cfg) {
  return findExecutable(cfg.ffmpegPath || 'ffmpeg');
}

// Resolve ffmpeg or fail with the protocol's stable dependency error (never spawn(null)).
function requireFfmpeg(cfg) {
  const p = ffmpegPath(cfg);
  if (!p) throw new CaptureError('dependency_missing', 'ffmpeg not found (required); install ffmpeg and retry');
  return p;
}

// Count encoded video frames in a finished file (for record_complete `frames`, matching
// the macOS contract). Best-effort via ffprobe; returns null if unavailable.
function countVideoFrames(ffmpegBin, file) {
  const probe = findExecutable('ffprobe') || (ffmpegBin ? ffmpegBin.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1') : null);
  if (!probe || !existsSync(probe)) return null;
  try {
    const res = spawnSync(probe, ['-v', 'error', '-select_streams', 'v:0', '-count_frames',
      '-show_entries', 'stream=nb_read_frames', '-of', 'default=nokey=1:noprint_wrappers=1', file], { encoding: 'utf8' });
    const n = parseInt((res.stdout || '').trim(), 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch { return null; }
}

function requireGrabber() {
  if (!adapter.grabberBin) {
    throw new CaptureError('dependency_missing', adapter.grabberMissingHint || 'native grabber not found; run scripts/postinstall.js');
  }
  return adapter.grabberBin;
}

// Grabber CLI contract (same across platforms): enumerate | check | capture <id> [--fps N|--frames K].
function grabberCaptureArgv(windowId, fps) { return ['capture', String(windowId), '--fps', String(fps)]; }
function grabberSnapshotArgv(windowId) { return ['capture', String(windowId), '--frames', '1']; }

// The grabber's authoritative capture size, from its grab_start stderr line. Returns null if absent.
function parseGrabStart(stderr) {
  for (const line of (stderr || '').toString().split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { const ev = JSON.parse(t); if (ev.type === 'grab_start') return { width: ev.width, height: ev.height }; } catch { /* not JSON */ }
  }
  return null;
}

/* ---- window enumeration + target resolution --------------------------- */

function enumerateWindows() {
  const grabber = requireGrabber();
  const res = spawnSync(grabber, ['enumerate'], { env: adapter.env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (res.status !== 0) {
    const detail = (res.stderr || '').trim();
    throw new CaptureError('window_enumeration_failed', `window enumeration failed: ${detail || 'grabber exit ' + res.status}`);
  }
  const windows = [];
  for (const line of res.stdout.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { windows.push(JSON.parse(t)); }
    catch { log('warn', `skipping unparseable grabber enumerate line: ${t.slice(0, 120)}`); }
  }
  return windows;
}

function isLikelyCapturable(w) {
  const ratio = w.width / Math.max(w.height, 1);
  return w.width > 100 && w.height > 100 && w.layer === 0 && ratio < 10;
}

function rankedPidCandidates(windows, pid) {
  return windows
    .filter((w) => w.pid === pid && w.width > 100 && w.height > 100 && w.layer === 0 && (w.width / Math.max(w.height, 1)) < 10)
    .sort((a, b) => b.width * b.height - a.width * a.height);
}

function filteredByName(windows, appName, titleSub) {
  return windows
    .filter((w) => (w.title || '').toLowerCase().includes(titleSub.toLowerCase()) && (appName == null || w.app === appName))
    .sort((a, b) => b.width * b.height - a.width * a.height);
}

// mirror TargetResolver.swift
function resolveTarget(cfg) {
  if (cfg.initialWindowId == null && cfg.initialPid == null && cfg.initialNames.length === 0) {
    throw new CaptureError('target_required', 'target selector required: --window-id, --pid, or --window-name');
  }
  const all = enumerateWindows();
  const onScreen = all.filter((w) => w.onScreen);

  if (cfg.initialWindowId != null) {
    const candidates = all.filter((w) => (w.id >>> 0) === (cfg.initialWindowId >>> 0));
    if (!candidates.length) throw new CaptureError('window_not_found', `no window found for id ${cfg.initialWindowId}`);
    return { window: candidates[0], selector: 'window-id', candidates };
  }
  if (cfg.initialPid != null) {
    const candidates = rankedPidCandidates(all, cfg.initialPid);
    if (!candidates.length) throw new CaptureError('window_not_found', `no window found for PID ${cfg.initialPid}`);
    return { window: candidates[0], selector: 'pid', candidates };
  }
  const name = cfg.initialNames[0];
  const onCand = filteredByName(onScreen, cfg.initialAppName, name);
  if (onCand.length) return { window: onCand[0], selector: cfg.initialAppName == null ? 'window-name' : 'app-name+window-name', candidates: onCand };
  const allCand = filteredByName(all, cfg.initialAppName, name);
  if (allCand.length) return { window: allCand[0], selector: cfg.initialAppName == null ? 'window-name-offscreen' : 'app-name+window-name-offscreen', candidates: allCand };

  const appLabel = cfg.initialAppName || 'any app';
  const visible = onScreen.map((w) => w.title).filter(Boolean).join(', ');
  throw new CaptureError('window_not_found', `no window matching '${name}' in ${appLabel} (visible: ${visible})`);
}

/* ---- output sizing + ffmpeg command ----------------------------------- */

function outputSize(srcW, srcH, maxSize) {
  const scale = Math.min(maxSize / Math.max(srcW, srcH), 1.0);
  const outW = Math.max(2, Math.floor(srcW * scale) & ~1);
  const outH = Math.max(2, Math.floor(srcH * scale) & ~1);
  return { outW, outH };
}

// Build the ffmpeg argv. mode: 'annexb' (stdout H.264) or 'mp4' (file) or 'png' (file).
// Input is always raw BGRA from the grabber, so the encode path is platform-agnostic.
function ffmpegArgs(cfg, { srcW, srcH, outW, outH, mode, outputPath }) {
  const fps = cfg.maxFps;
  const a = ['-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'bgra', '-s', `${srcW}x${srcH}`, '-framerate', String(fps), '-i', '-'];
  a.push('-an');
  if (outW !== srcW || outH !== srcH) a.push('-vf', `scale=${outW}:${outH}`);

  if (mode === 'png') { a.push('-frames:v', '1', '-y', outputPath); return a; }

  const enc = cfg.encoder;
  const gop = String(fps * 2);
  if (enc === 'h264_nvenc') {
    a.push('-c:v', 'h264_nvenc', '-profile:v', 'baseline', '-preset', 'p4', '-tune', 'll',
      '-rc', 'cbr', '-b:v', mode === 'mp4' ? String(Math.max(outW * outH * 6, 500000)) : '500k',
      '-g', gop, '-bf', '0', '-forced-idr', '1', '-force_key_frames', 'expr:gte(t,n_forced*2)');
  } else {
    // NB: `-tune zerolatency` makes x264/ffmpeg duplicate frames 5x on a paced raw
    // source (CFR padding). We get the same low latency via rc-lookahead/sync-lookahead=0
    // plus `-bf 0`, without the duplication.
    a.push('-c:v', 'libx264', '-profile:v', 'baseline', '-preset', 'veryfast',
      '-pix_fmt', 'yuv420p', '-b:v', mode === 'mp4' ? String(Math.max(outW * outH * 6, 500000)) : '500k',
      '-g', gop, '-keyint_min', gop, '-bf', '0',
      '-x264-params', 'repeat-headers=1:scenecut=0:rc-lookahead=0:sync-lookahead=0',
      '-force_key_frames', 'expr:gte(t,n_forced*2)');
  }

  if (mode === 'mp4') { a.push('-movflags', '+faststart'); if (cfg.durationSeconds != null) a.push('-t', String(cfg.durationSeconds)); a.push('-y', outputPath); }
  else { a.push('-f', 'h264', 'pipe:1'); }
  return a;
}

/* ---- Annex B access-unit splitter (framed mode) ----------------------- */

class AnnexBSplitter {
  constructor(windowIndex, onPacket) {
    this.buf = Buffer.alloc(0);
    this.au = [];
    this.auHasVcl = false;
    this.auKey = false;
    this.windowIndex = windowIndex;
    this.onPacket = onPacket;
  }

  static findStart(buf, from) {
    for (let i = from; i + 3 <= buf.length; i++) {
      if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 1) return i;
    }
    return -1;
  }

  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    let start = AnnexBSplitter.findStart(this.buf, 0);
    if (start < 0) { if (this.buf.length > 3) this.buf = this.buf.subarray(this.buf.length - 3); return; }
    let next;
    while ((next = AnnexBSplitter.findStart(this.buf, start + 3)) >= 0) {
      this.handleNal(this.buf.subarray(start, next));
      start = next;
    }
    this.buf = this.buf.subarray(start);
  }

  handleNal(nal) {
    const type = nal[3] & 0x1f;
    const isVcl = type >= 1 && type <= 5;
    const startsNewAu = this.auHasVcl && (isVcl || type === 6 || type === 7 || type === 8 || type === 9);
    if (startsNewAu) this.flush();
    this.au.push(nal);
    if (isVcl) this.auHasVcl = true;
    if (type === 5) this.auKey = true;
  }

  flush() {
    if (!this.au.length) return;
    const payload = this.au.length === 1 ? this.au[0] : Buffer.concat(this.au);
    const header = Buffer.alloc(6);
    header.writeUInt32BE(payload.length >>> 0, 0);
    header[4] = this.auKey ? 1 : 0;
    header[5] = this.windowIndex;
    this.onPacket(header, payload);
    this.au = [];
    this.auHasVcl = false;
    this.auKey = false;
  }

  end() {
    if (this.buf.length >= 4 && AnnexBSplitter.findStart(this.buf, 0) === 0) this.handleNal(this.buf);
    this.flush();
  }
}

/* ---- capture slot (grabber | ffmpeg) ---------------------------------- */

class Slot {
  constructor(index, name, window, cfg) {
    this.index = index;
    this.name = name;
    this.window = window;
    this.cfg = cfg;
    this.grabber = null;
    this.ffmpeg = null;
    this.splitter = null;
    this.stopping = false;
    this.announced = false; // emitted 'added' once ffmpeg started at the real size
    this.epoch = 0; // bumped each (re)start so stale child-exit handlers are ignored
    this.outW = 0;
    this.outH = 0;
  }

  start() {
    const { window: w, cfg } = this;
    const epoch = ++this.epoch; // child handlers from a previous start become stale
    const grabberBin = requireGrabber();
    const ffmpegBin = requireFfmpeg(cfg); // throws dependency_missing rather than spawn(null)

    this.grabber = spawn(grabberBin, grabberCaptureArgv(w.id, cfg.maxFps),
      { env: adapter.env, stdio: ['ignore', 'pipe', 'pipe'] });

    const onChildExit = (which, code, signal, isError) => {
      if (epoch !== this.epoch || this.stopping) return; // stale (post-restart) or already stopping
      // grabber resize (exit 75): rebuild this slot at the new geometry, keep the index.
      if (which === 'grabber' && code === 75 && cfg.framed) { this.restart(); return; }
      this.stopping = true;
      this.cleanup();
      // We only reach here for an UNSOLICITED exit (intentional stop/restart sets `stopping`
      // first and is filtered above). So a signal kill (SIGSEGV/SIGKILL) is a failure; 0 =
      // downstream closed cleanly; 76 = window gone (expected end).
      const failed = isError || signal != null || (code != null && code !== 0 && code !== 76);
      const detail = isError ? `${which} failed to spawn (${signal || 'error'})`
        : (signal != null ? `${which} killed by ${signal}` : `${which} exited (code ${code})`);
      if (cfg.framed) {
        if (!this.announced) {
          // died before capture started -> the add itself failed
          logEvent({ type: 'add_failed', name: this.name, error: failed ? detail : `${which} exited before capture started` });
        } else {
          if (failed) logError('stream_stopped', `window[${this.index}] ${detail}`, { windowIndex: this.index });
          logEvent({ type: 'removed', index: this.index });
        }
        onSlotClosed(this.index);
      } else if (failed || !this.announced) {
        logError('setup_failed', this.announced ? detail : `${detail} before capture started`, { windowIndex: this.index });
        process.exit(1);
      } else {
        process.exit(0);
      }
    };
    this.grabber.on('exit', (code, signal) => onChildExit('grabber', code, signal, false));
    this.grabber.on('error', (e) => onChildExit('grabber', null, e && e.code, true));

    // Start ffmpeg only after the grabber reports its authoritative capture size (grab_start),
    // so a resize between enumeration and grabber startup cannot misframe the raw BGRA.
    let stderrBuf = '';
    let ffmpegStarted = false;
    this.grabber.stderr.on('data', (c) => {
      stderrBuf += c.toString();
      let nl;
      while ((nl = stderrBuf.indexOf('\n')) >= 0) {
        const line = stderrBuf.slice(0, nl); stderrBuf = stderrBuf.slice(nl + 1);
        if (!line.trim()) continue;
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (epoch !== this.epoch) continue;
        if (ev.type === 'grab_start' && !ffmpegStarted) { ffmpegStarted = true; this.startEncoder(ffmpegBin, ev.width, ev.height, epoch, onChildExit); }
        else if (ev.type === 'resized') log('info', `window ${w.id} resized to ${ev.width}x${ev.height}`);
        else if (ev.type === 'error') logError('setup_failed', ev.msg, { windowIndex: this.index });
      }
    });
  }

  // Spawn ffmpeg at the grabber's authoritative source size and wire the pipe/framing.
  startEncoder(ffmpegBin, srcW, srcH, epoch, onChildExit) {
    if (epoch !== this.epoch || this.stopping) return;
    const { cfg } = this;
    const { outW, outH } = outputSize(srcW, srcH, cfg.maxSize);
    this.outW = outW; this.outH = outH;

    this.ffmpeg = spawn(ffmpegBin, ffmpegArgs(cfg, { srcW, srcH, outW, outH, mode: 'annexb' }),
      { stdio: ['pipe', 'pipe', 'inherit'] });
    this.grabber.stdout.pipe(this.ffmpeg.stdin);
    // ffmpeg may exit before the grabber stops; swallow the resulting EPIPE on its stdin.
    this.ffmpeg.stdin.on('error', (e) => { if (e && e.code !== 'EPIPE') log('warn', `window=${this.index} ffmpeg stdin error: ${e.message}`); });
    this.grabber.stdout.on('error', () => { /* broken pipe during teardown */ });

    if (cfg.framed) {
      // Bind splitter + epoch into the closures so a restart()'s old ffmpeg can't push stale
      // bytes into the new epoch's splitter (or emit stale framed packets).
      const splitter = new AnnexBSplitter(this.index, (header, payload) => writeStdout(Buffer.concat([header, payload])));
      this.splitter = splitter;
      this.ffmpeg.stdout.on('data', (c) => { if (epoch === this.epoch) splitter.push(c); });
      this.ffmpeg.stdout.on('end', () => { if (epoch === this.epoch) splitter.end(); });
    } else {
      this.ffmpeg.stdout.on('data', (c) => { if (epoch === this.epoch) writeStdout(c); });
    }

    this.ffmpeg.on('exit', (code, signal) => onChildExit('ffmpeg', code, signal, false));
    this.ffmpeg.on('error', (e) => onChildExit('ffmpeg', null, e && e.code, true));

    if (!this.announced) {
      this.announced = true;
      logEvent({ type: 'added', index: this.index, name: this.name, width: outW, height: outH, windowId: this.window.id });
    } else {
      logEvent({ type: 'resized', index: this.index, width: outW, height: outH }); // after a resize-restart
    }
  }

  // Re-resolve the window by id (size changed) and respawn the pipe, keeping the slot index.
  restart() {
    this.cleanup();
    let w = null;
    try { w = enumerateWindows().find((x) => (x.id >>> 0) === (this.window.id >>> 0)); } catch { /* gone */ }
    if (!w) {
      this.stopping = true;
      logEvent({ type: 'removed', index: this.index });
      onSlotClosed(this.index);
      return;
    }
    this.window = w;
    try {
      this.start(); // startEncoder emits 'resized' on the next grab_start (already announced)
    } catch (e) {
      this.stopping = true;
      logError('stream_stopped', `window[${this.index}] restart failed: ${e.message}`, { windowIndex: this.index });
      logEvent({ type: 'removed', index: this.index });
      onSlotClosed(this.index);
    }
  }

  cleanup() {
    try { if (this.ffmpeg && this.ffmpeg.stdin && !this.ffmpeg.stdin.destroyed) this.ffmpeg.stdin.end(); } catch { /* */ }
    try { if (this.grabber) this.grabber.kill('SIGTERM'); } catch { /* */ }
    try { if (this.ffmpeg) this.ffmpeg.kill('SIGTERM'); } catch { /* */ }
  }

  stop() {
    this.stopping = true;
    this.cleanup();
  }
}

/* ---- slot table (framed multi-window) --------------------------------- */

const slots = [];

function allocateIndex() {
  const free = slots.findIndex((s) => s == null);
  if (free >= 0) return free;
  if (slots.length >= 256) return -1; // the framed header window index is a single byte
  slots.push(null);
  return slots.length - 1;
}

function onSlotClosed(index) {
  if (index < slots.length) slots[index] = null;
}

function addWindow(name, window, cfg) {
  const index = allocateIndex();
  if (index < 0) throw new CaptureError('setup_failed', 'maximum of 256 concurrent windows reached');
  const slot = new Slot(index, window.title || name, window, cfg);
  slots[index] = slot;               // reserve the index
  try { slot.start(); }
  catch (e) { slots[index] = null; throw e; } // failed start must not leave a dead occupied slot
  return slot; // the slot emits 'added' once the grabber reports grab_start (real size)
}

function addFromSelector(name, resolver, cfg) {
  try {
    const target = resolver();
    addWindow(name, target.window, cfg);
  } catch (e) {
    logEvent({ type: 'add_failed', name, error: e.message });
  }
}

function removeAllSlots() {
  for (let i = 0; i < slots.length; i++) { if (slots[i]) { slots[i].stop(); slots[i] = null; } }
}

function handleStdinCommand(cmd, cfg) {
  if (cmd.startsWith('+name ')) {
    const name = cmd.slice(6);
    addFromSelector(name, () => resolveTarget(Object.assign({}, cfg, { initialNames: [name], initialAppName: null, initialPid: null, initialWindowId: null })), cfg);
  } else if (cmd.startsWith('+match ')) {
    const payload = cmd.slice(7);
    const tab = payload.indexOf('\t'); // split on the FIRST tab only (titles may contain tabs), matching Swift
    if (tab < 0) { logEvent({ type: 'add_failed', name: payload, error: 'expected +match <app>\\t<title>' }); return; }
    const appName = payload.slice(0, tab); const title = payload.slice(tab + 1);
    addFromSelector(`${appName}:${title}`, () => resolveTarget(Object.assign({}, cfg, { initialNames: [title], initialAppName: appName, initialPid: null, initialWindowId: null })), cfg);
  } else if (cmd.startsWith('+pid ')) {
    const pid = parseInt(cmd.slice(5), 10);
    if (!Number.isFinite(pid)) { logEvent({ type: 'add_failed', name: `pid:${cmd.slice(5)}`, error: 'invalid PID' }); return; }
    addFromSelector(`pid:${pid}`, () => resolveTarget(Object.assign({}, cfg, { initialPid: pid, initialNames: [], initialAppName: null, initialWindowId: null })), cfg);
  } else if (cmd.startsWith('+id ')) {
    const id = parseInt(cmd.slice(4), 10);
    if (!Number.isFinite(id)) { logEvent({ type: 'add_failed', name: `id:${cmd.slice(4)}`, error: 'invalid window id' }); return; }
    addFromSelector(`id:${id}`, () => resolveTarget(Object.assign({}, cfg, { initialWindowId: id >>> 0, initialNames: [], initialAppName: null, initialPid: null })), cfg);
  } else if (cmd.startsWith('-')) {
    const index = parseInt(cmd.slice(1), 10);
    if (!Number.isFinite(index)) { logError('invalid_index', `invalid index: ${cmd.slice(1)}`); return; }
    if (index >= slots.length || !slots[index]) { logError('window_slot_not_found', `no window at index ${index}`, { index }); return; }
    slots[index].stop(); slots[index] = null;
    logEvent({ type: 'removed', index });
  } else {
    logError('unknown_command', `unknown command: ${cmd}`);
  }
}

/* ---- commands --------------------------------------------------------- */

function buildInfo() {
  return {
    name: PKG.name,
    binary: 'capture-helper',
    version: PKG.version,
    architecture: process.arch === 'x64' ? 'x86_64' : process.arch,
    os: adapter.platform,
    osVersion: require('node:os').release(),
  };
}

function cmdVersion(cfg) {
  if (cfg.json) emitJsonObject(buildInfo());
  else process.stdout.write(`capture-helper ${PKG.version}\n`);
}

function cmdList(cfg) {
  let windows = enumerateWindows();
  windows = windows.filter((w) => {
    if (cfg.listOnScreenOnly && w.onScreen !== true) return false;
    if (cfg.listCapturableOnly && !isLikelyCapturable(w)) return false;
    if (cfg.initialAppName && w.app !== cfg.initialAppName) return false;
    if (cfg.initialNames.length && !cfg.initialNames.some((n) => (w.title || '').toLowerCase().includes(n.toLowerCase()))) return false;
    return true;
  });
  if (!cfg.json) printWindowTable(windows);
  else if (cfg.legacyJsonLines) windows.forEach((w) => emitJsonLine(w, false));
  else emitJsonObject({ type: 'windows', windows, count: windows.length });
}

function printWindowTable(windows) {
  const capturable = windows.filter(isLikelyCapturable).sort((a, b) => {
    if (a.onScreen !== b.onScreen) return a.onScreen ? -1 : 1;
    return b.width * b.height - a.width * a.height;
  });
  const pad = (s, n) => (String(s).length >= n ? String(s) : String(s) + ' '.repeat(n - String(s).length));
  const trunc = (s, n) => (s.length <= n ? s : s.slice(0, n - 1) + '…');
  process.stdout.write(`capture-helper windows: ${windows.length} total, ${capturable.length} likely capturable\n`);
  process.stdout.write('ID        PID       SCREEN  SIZE        APP                         TITLE\n');
  process.stdout.write('--------  --------  ------  ----------  --------------------------  ------------------------------\n');
  for (const w of capturable.slice(0, 80)) {
    process.stdout.write(`${pad(w.id, 8)}  ${pad(w.pid, 8)}  ${pad(w.onScreen ? 'yes' : 'no', 6)}  ${pad(`${w.width}x${w.height}`, 10)}  ${pad(trunc(w.app || '', 26), 26)}  ${trunc(w.title || '', 60)}\n`);
  }
  process.stdout.write('\nTips: capture-helper record --window-id <ID> --duration 5 -o evidence.mp4\n');
}

function cmdResolve(cfg) {
  const r = resolveTarget(cfg);
  emitJsonObject({ type: 'resolve', selector: r.selector, selected: r.window, candidates: r.candidates, candidateCount: r.candidates.length });
}

function cmdPermissions() {
  // Linux/X11 (and Windows) have no per-app screen-recording permission model (TCC).
  // Mirror the macOS stable fields so consumers parse one shape.
  emitJsonObject({
    type: 'permissions',
    permission: 'screen_recording',
    grantedBefore: true,
    grantedAfter: true,
    requestAttempted: false,
    settingsOpenAttempted: false,
    platform: adapter.platform,
    remediation: [],
    message: `${adapter.platform} has no screen-recording permission gate; access is controlled by the windowing system.`,
  });
}

function ensureParentDir(outputPath) {
  const dir = path.dirname(path.resolve(outputPath));
  if (!existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function cmdSnapshot(cfg) {
  if (!cfg.outputPath) throw new CaptureError('target_required', 'snapshot requires --output PATH');
  const r = resolveTarget(cfg);
  ensureParentDir(cfg.outputPath);

  const grabberBin = requireGrabber();
  const ffmpegBin = requireFfmpeg(cfg); // validate before running the grabber
  const grab = spawnSync(grabberBin, grabberSnapshotArgv(r.window.id),
    { env: adapter.env, maxBuffer: 256 * 1024 * 1024 });
  if (grab.status !== 0 || !grab.stdout || !grab.stdout.length) {
    throw new CaptureError('snapshot_failed', `grabber failed: ${(grab.stderr || '').toString().trim() || 'status ' + grab.status}`);
  }
  // Size ffmpeg from the grabber's authoritative grab_start dims, not stale enumeration.
  const gs = parseGrabStart(grab.stderr) || { width: r.window.width, height: r.window.height };
  const { outW, outH } = outputSize(gs.width, gs.height, cfg.maxSize);
  const ff = spawnSync(ffmpegBin, ffmpegArgs(cfg, { srcW: gs.width, srcH: gs.height, outW, outH, mode: 'png', outputPath: cfg.outputPath }),
    { input: grab.stdout });
  const size = existsSync(cfg.outputPath) ? fs.statSync(cfg.outputPath).size : 0;
  if (ff.status !== 0 || size <= 0) throw new CaptureError('snapshot_failed', `ffmpeg failed: ${(ff.stderr || '').toString().trim()}`);
  emitJsonObject({ type: 'snapshot', output: cfg.outputPath, bytes: size, selector: r.selector, selected: r.window });
}

function cmdRecord(cfg) {
  if (!cfg.outputPath) throw new CaptureError('target_required', 'record requires --output PATH');
  const r = resolveTarget(cfg);
  if (!r.window.onScreen) {
    logError('offscreen_window_warning', 'selected window is off-screen; recording may produce no frames.', { windowId: r.window.id });
  }
  // Resolve both binaries up front so a missing ffmpeg throws dependency_missing
  // *before* we spawn (and orphan) the grabber.
  const grabberBin = requireGrabber();
  const ffmpegBin = requireFfmpeg(cfg);
  ensureParentDir(cfg.outputPath);
  if (existsSync(cfg.outputPath)) fs.rmSync(cfg.outputPath);

  const grab = spawn(grabberBin, grabberCaptureArgv(r.window.id, cfg.maxFps), { env: adapter.env, stdio: ['ignore', 'pipe', 'pipe'] });

  let userStopped = false;      // SIGINT/SIGTERM to us
  let grabberTeardown = false;  // we killed the grabber AFTER ffmpeg finished its duration
  let ff = null;
  let ffmpegStarted = false;
  const grabState = { done: false, code: null, signal: null, spawnError: null };
  const ffState = { done: false, code: null };
  let finalized = false;

  const stop = () => { userStopped = true; try { grab.kill('SIGTERM'); } catch { /* */ } };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  // Decide success only once BOTH children have exited — otherwise ffmpeg can exit 0 on the
  // grabber's stdout-EOF before we learn the grabber died (window gone / crash), and we'd
  // report record_complete for a truncated file. macOS fails record on stream stop; match that.
  const finalize = () => {
    if (finalized || !grabState.done || !ffState.done) return;
    finalized = true;
    const size = existsSync(cfg.outputPath) ? fs.statSync(cfg.outputPath).size : 0;
    // The grabber failed if it died UNSOLICITED — not our user stop, and not the intentional
    // teardown after ffmpeg completed its duration — via any signal or nonzero exit code.
    const grabberFailed = grabState.spawnError != null
      || (!userStopped && !grabberTeardown && (grabState.signal != null || (grabState.code != null && grabState.code !== 0)));
    if (grabberFailed) {
      logError('record_failed', `grabber exited abnormally (${grabState.spawnError || grabState.signal || grabState.code}); recording is incomplete`, { output: cfg.outputPath });
      process.exit(1);
    }
    if (!ffmpegStarted || ffState.code !== 0 || size <= 0) {
      logError('record_failed', `recording produced no output (ffmpeg exit ${ffState.code}, ${size} bytes)`, { output: cfg.outputPath });
      process.exit(1);
    }
    const frames = countVideoFrames(ffmpegBin, cfg.outputPath);
    logEvent(Object.assign({ type: 'record_complete', engine: 'native', output: cfg.outputPath, bytes: size }, frames != null ? { frames } : {}));
    if (cfg.openOutput && adapter.openFile) adapter.openFile(cfg.outputPath);
    process.exit(0);
  };

  // Start ffmpeg only after the grabber reports its authoritative capture size (grab_start),
  // so a resize between enumeration and grabber startup cannot misframe the raw BGRA.
  function startRecordEncoder(srcW, srcH) {
    const { outW, outH } = outputSize(srcW, srcH, cfg.maxSize);
    ff = spawn(ffmpegBin, ffmpegArgs(cfg, { srcW, srcH, outW, outH, mode: 'mp4', outputPath: cfg.outputPath }), { stdio: ['pipe', 'inherit', 'inherit'] });
    grab.stdout.pipe(ff.stdin);
    ff.stdin.on('error', (e) => { if (e && e.code !== 'EPIPE') log('warn', `record ffmpeg stdin error: ${e.message}`); });
    grab.stdout.on('error', () => { /* broken pipe during teardown */ });
    logEvent({ type: 'record_start', engine: 'native', output: cfg.outputPath, selector: r.selector, windowId: r.window.id, width: outW, height: outH });
    if (cfg.durationSeconds == null) logEvent({ type: 'record_waiting', message: 'Recording; press Ctrl-C to stop' });
    ff.on('error', (e) => { logError('record_failed', `ffmpeg failed to start: ${e.message}`, { output: cfg.outputPath }); process.exit(1); });
    ff.on('exit', (code) => {
      ffState.done = true; ffState.code = code;
      if (!grabState.done) { grabberTeardown = true; try { grab.kill('SIGTERM'); } catch { /* */ } } // ffmpeg finished its duration
      finalize();
    });
  }

  let stderrBuf = '';
  grab.stderr.on('data', (c) => {
    stderrBuf += c.toString();
    let nl;
    while ((nl = stderrBuf.indexOf('\n')) >= 0) {
      const line = stderrBuf.slice(0, nl); stderrBuf = stderrBuf.slice(nl + 1);
      if (!line.trim()) continue;
      let ev; try { ev = JSON.parse(line); } catch { continue; }
      if (ev.type === 'grab_start' && !ffmpegStarted) { ffmpegStarted = true; startRecordEncoder(ev.width, ev.height); }
    }
  });

  grab.on('exit', (code, signal) => {
    grabState.done = true; grabState.code = code; grabState.signal = signal;
    if (ff) { try { ff.stdin.end(); } catch { /* */ } }
    if (!ffmpegStarted) ffState.done = true; // grabber died before capture even started
    finalize();
  });
  grab.on('error', (e) => {
    grabState.done = true; grabState.spawnError = (e && e.code) || 'spawn_error';
    if (!ffmpegStarted) ffState.done = true;
    finalize();
  });
}

function cmdCapture(cfg) {
  installSignalHandlers();
  if (cfg.initialWindowId != null) {
    const r = resolveTarget(Object.assign({}, cfg, { initialPid: null, initialNames: [] }));
    addWindow(r.window.title || `id:${cfg.initialWindowId}`, r.window, cfg);
  }
  for (const name of cfg.initialNames) {
    addFromSelector(name, () => resolveTarget(Object.assign({}, cfg, { initialNames: [name], initialPid: null, initialWindowId: null })), cfg);
  }
  if (cfg.initialPid != null) {
    const r = resolveTarget(Object.assign({}, cfg, { initialNames: [], initialWindowId: null }));
    addWindow(r.window.title || `pid:${cfg.initialPid}`, r.window, cfg);
  }

  if (cfg.durationSeconds != null) setTimeout(() => cleanupAndExit(), cfg.durationSeconds * 1000);

  if (cfg.framed) startStdinReader(cfg);
  else if (slots.filter(Boolean).length === 0) {
    logError('target_required', '--window-id, --window-name, or --pid is required in non-framed mode');
    process.exit(1);
  }
}

function startStdinReader(cfg) {
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
      if (line) handleStdinCommand(line, cfg);
    }
  });
  process.stdin.on('end', () => cleanupAndExit());
  process.stdin.resume();
}

function installSignalHandlers() {
  process.on('SIGINT', cleanupAndExit);
  process.on('SIGTERM', cleanupAndExit);
}

function cleanupAndExit() {
  log('info', 'shutting down');
  removeAllSlots();
  process.exit(0);
}

/* ---- doctor ----------------------------------------------------------- */

function cmdDoctor(cfg) {
  const checks = [];

  const ffmpeg = ffmpegPath(cfg);
  checks.push({ id: 'ffmpeg', name: 'ffmpeg', ok: !!ffmpeg, code: ffmpeg ? 'ffmpeg_present' : 'ffmpeg_missing', required: adapter.ffmpegRequired, message: ffmpeg ? 'ffmpeg available for encoding' : 'ffmpeg is required (install ffmpeg)', value: ffmpeg || 'not found' });

  const grabberOk = !!adapter.grabberBin;
  checks.push({ id: 'grabber', name: 'grabber', ok: grabberOk, code: grabberOk ? 'grabber_compiled' : 'grabber_missing', required: true, message: grabberOk ? 'native grabber is available' : (adapter.grabberMissingHint || 'native grabber not built'), value: adapter.grabberBin || 'not found' });

  // platform readiness (e.g. session/display/XComposite on Linux)
  const { checks: platformChecks, ready } = adapter.readinessChecks();
  checks.push(...platformChecks);

  // window enumeration (generic, gated on grabber + platform readiness)
  let enumOk = false, enumDetail = {};
  if (grabberOk && ready) {
    try {
      const windows = enumerateWindows();
      const capturable = windows.filter(isLikelyCapturable);
      enumOk = capturable.length > 0;
      enumDetail = { windowCount: windows.length, capturableWindowCount: capturable.length };
    } catch (e) { enumDetail = { error: e.message }; }
  }
  checks.push({ id: 'window_enumeration', name: 'window enumeration', ok: enumOk, code: enumOk ? 'window_enumeration_ok' : 'no_capturable_windows', required: true, message: enumOk ? 'found capturable windows' : 'no capturable application windows found (is a desktop logged in?)', details: enumDetail });

  const ok = checks.every((c) => c.ok || !c.required);
  const reqFail = checks.filter((c) => !c.ok && c.required);
  const optFail = checks.filter((c) => !c.ok && !c.required);
  const result = {
    type: 'doctor', ok, build: buildInfo(), checks,
    summary: { requiredFailureCount: reqFail.length, optionalFailureCount: optFail.length, requiredFailureCodes: reqFail.map((c) => c.code), optionalFailureCodes: optFail.map((c) => c.code) },
  };
  if (cfg.json) emitJsonObject(result);
  else {
    process.stdout.write(ok ? 'capture-helper doctor: OK\n' : 'capture-helper doctor: FAILED\n');
    for (const c of checks) process.stdout.write(`[${c.ok ? 'OK' : (c.required ? 'FAIL' : 'WARN')}] ${c.name} (${c.code}) — ${c.message}\n`);
  }
  if (!ok) process.exit(1);
}

/* ---- main ------------------------------------------------------------- */

function main() {
  const cfg = parseArgs(process.argv.slice(2));
  try {
    switch (cfg.command) {
      case 'version': cmdVersion(cfg); break;
      case 'doctor': cmdDoctor(cfg); break;
      case 'permissions': cmdPermissions(cfg); break;
      case 'list': cmdList(cfg); break;
      case 'resolve': cmdResolve(cfg); break;
      case 'snapshot': cmdSnapshot(cfg); break;
      case 'record': cmdRecord(cfg); return; // async, manages its own exit
      case 'capture': cmdCapture(cfg); return; // long-running
      default: printUsage(); process.exit(0);
    }
  } catch (e) {
    if (e instanceof CaptureError) { logError(e.code, e.message); process.exit(1); }
    logError('unexpected_error', e && e.stack ? e.stack : String(e));
    process.exit(1);
  }
}

main();
