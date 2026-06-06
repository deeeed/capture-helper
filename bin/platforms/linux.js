'use strict';

/*
 * Linux platform adapter for capture-helper.
 *
 * Supplies everything X11-specific to the generic backend core (bin/backend.js):
 * the native grabber binary, the grabber spawn environment (DISPLAY/XAUTHORITY),
 * the default encoder, and the platform-specific doctor readiness checks.
 *
 * The generic core never touches X11 directly — a future Windows adapter
 * (bin/platforms/windows.js) implements the same surface around a Windows.Graphics.Capture
 * grabber, and the core is unchanged. The native grabber, whatever the platform,
 * honours the same CLI contract: `enumerate`, `check`, and `capture <id>` emitting
 * raw BGRA frames (see src/<platform>/ and docs/protocol.md).
 */

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

function resolveGrabberBin() {
  const root = path.join(__dirname, '..', '..');
  const candidates = [
    process.env.SITEED_X11_GRABBER_BIN,
    path.join(root, 'native', 'x11-grabber'),
    path.join(root, '.build', 'x11-grabber'),
  ].filter(Boolean);
  return candidates.find((c) => { try { fs.accessSync(c, fs.constants.X_OK); return true; } catch { return false; } }) || null;
}

// Find a live local X11 DISPLAY + XAUTHORITY by reading the environ of processes
// belonging to a specific logind session. loginctl frequently leaves Display empty
// for GNOME-on-Xorg, so the session's process environment is the reliable source.
// Scoping to the session's cgroup (`session-<id>.scope`) avoids picking a different
// session's display on a multi-session host. Returns { DISPLAY, XAUTHORITY } or null.
function scanProcForDisplay(sessionId) {
  const uid = process.getuid ? process.getuid() : null;
  const scopeTag = sessionId ? `session-${sessionId}.scope` : null;
  let pids;
  try { pids = fs.readdirSync('/proc').filter((n) => /^\d+$/.test(n)); } catch { return null; }
  for (const pid of pids) {
    try {
      if (uid != null && fs.statSync(`/proc/${pid}`).uid !== uid) continue;
      if (scopeTag) {
        let cg;
        try { cg = fs.readFileSync(`/proc/${pid}/cgroup`, 'utf8'); } catch { continue; }
        if (!cg.includes(scopeTag)) continue;
      }
      const raw = fs.readFileSync(`/proc/${pid}/environ`, 'utf8');
      const vars = {};
      for (const kv of raw.split('\0')) { const i = kv.indexOf('='); if (i > 0) vars[kv.slice(0, i)] = kv.slice(i + 1); }
      if (vars.DISPLAY && /^:\d+/.test(vars.DISPLAY)) {
        let xauth = vars.XAUTHORITY;
        if (xauth) { try { fs.accessSync(xauth, fs.constants.R_OK); } catch { xauth = undefined; } }
        return { DISPLAY: vars.DISPLAY, XAUTHORITY: xauth };
      }
    } catch { /* not ours / gone */ }
  }
  return null;
}

// Find the active graphical (x11/wayland) user session via loginctl.
// Returns { type, display, xauthority } or null.
function findGraphicalSession() {
  const myUid = process.getuid ? String(process.getuid()) : null;
  const sessions = spawnSync('loginctl', ['list-sessions', '--no-legend'], { encoding: 'utf8' });
  if (sessions.status !== 0 || !sessions.stdout) return null;
  for (const line of sessions.stdout.split('\n')) {
    const id = line.trim().split(/\s+/)[0];
    if (!id) continue;
    const show = spawnSync('loginctl', ['show-session', id, '-p', 'Type', '-p', 'Class', '-p', 'Active', '-p', 'Display', '-p', 'User'], { encoding: 'utf8' });
    if (show.status !== 0) continue;
    const p = {};
    for (const kv of show.stdout.split('\n')) { const i = kv.indexOf('='); if (i > 0) p[kv.slice(0, i)] = kv.slice(i + 1); }
    if (p.Class !== 'user' || p.Active !== 'yes') continue;       // loginctl prints "yes", not "true"
    if (p.Type !== 'x11' && p.Type !== 'wayland') continue;
    if (myUid != null && p.User !== myUid) continue;             // only OUR user's session, not another user's
    const fromProc = scanProcForDisplay(id);                      // scope discovery to THIS session
    return {
      type: p.Type,
      display: (p.Display && p.Display.startsWith(':')) ? p.Display : (fromProc ? fromProc.DISPLAY : null),
      xauthority: fromProc ? fromProc.XAUTHORITY : null,
    };
  }
  return null;
}

// Resolve DISPLAY + XAUTHORITY. If not already in env (bare SSH / farmslot host),
// discover the active graphical session.
function resolveEnv() {
  const env = Object.assign({}, process.env);
  const localDisplay = !!env.DISPLAY && /^:\d+/.test(env.DISPLAY); // not a forwarded localhost:N
  let xauthOk = false;
  if (env.XAUTHORITY) { try { fs.accessSync(env.XAUTHORITY, fs.constants.R_OK); xauthOk = true; } catch { /* unreadable */ } }
  if (localDisplay && xauthOk) return env;
  const g = findGraphicalSession();
  if (g && g.display) {
    if (!localDisplay) {
      // No local DISPLAY (unset, or forwarded localhost:N) — adopt the session's display+cookie
      // rather than pairing a forwarded display with the local session cookie.
      env.DISPLAY = g.display;
      if (g.xauthority) env.XAUTHORITY = g.xauthority;
    } else if (!xauthOk && g.xauthority && g.display === env.DISPLAY) {
      env.XAUTHORITY = g.xauthority; // local DISPLAY set but no cookie — fill in the matching one
    }
  }
  return env;
}

// NB: do NOT trust process.env.XDG_SESSION_TYPE — over SSH it is "tty".
function sessionType() {
  const g = findGraphicalSession();
  return g ? g.type : 'unknown';
}

const GRABBER = resolveGrabberBin();
const ENV = resolveEnv();

// Platform-specific doctor checks: session type, X display reachability, XComposite.
// Returns { checks, ready } — `ready` gates the generic enumeration check.
function readinessChecks() {
  const checks = [];
  const stype = sessionType();
  checks.push({
    id: 'session_type', name: 'session type', ok: stype === 'x11', required: false,
    code: stype === 'x11' ? 'session_x11' : (stype === 'wayland' ? 'session_wayland' : 'session_unknown'),
    message: stype === 'x11' ? 'X11 session detected' : `non-X11 session (${stype}); per-window capture requires Xorg`,
    value: stype,
  });

  let displayOk = false, compositeOk = false, detail = {};
  if (!GRABBER) {
    detail = { error: 'native grabber not built' };
  } else if (!ENV.DISPLAY) {
    detail = { error: 'DISPLAY is unset and no active X11 user session was found via loginctl' };
  } else {
    const res = spawnSync(GRABBER, ['check'], { env: ENV, encoding: 'utf8' });
    if (res.status === 0 || res.status === 66) {
      try { const j = JSON.parse((res.stdout || '').trim().split('\n').pop()); displayOk = j.root === true; compositeOk = j.composite === true; detail = j; } catch { /* */ }
    } else {
      detail = { error: (res.stderr || '').trim() || `grabber check exit ${res.status}`, display: ENV.DISPLAY };
    }
  }
  checks.push({
    id: 'display', name: 'X display', ok: displayOk, required: true,
    code: displayOk ? 'display_available' : 'display_unavailable',
    message: displayOk ? `connected to ${ENV.DISPLAY}` : 'cannot reach an X display (set DISPLAY/XAUTHORITY or log into an Xorg session)',
    value: ENV.DISPLAY || 'unset', details: detail,
  });
  checks.push({
    id: 'xcomposite', name: 'XComposite extension', ok: compositeOk, required: true,
    code: compositeOk ? 'xcomposite_present' : 'xcomposite_missing',
    message: compositeOk ? 'XComposite available for per-window capture' : 'XComposite extension unavailable on this display',
  });
  return { checks, ready: displayOk };
}

function openFile(p) { spawnSync('xdg-open', [p]); }

module.exports = {
  platform: 'linux',
  defaultEncoder: 'libx264',
  ffmpegRequired: true,
  grabberBin: GRABBER,
  grabberMissingHint: 'native grabber not built; run scripts/postinstall.js (needs gcc + libxcomposite-dev libxdamage-dev libxfixes-dev libxext-dev)',
  env: ENV,
  readinessChecks,
  openFile,
};
