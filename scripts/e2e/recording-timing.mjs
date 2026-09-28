// Native window capture with real CDP button input and concurrent session PNGs.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';

const helper = process.env.CAPTURE_HELPER ?? path.resolve('.build/release/capture-helper');
const port = Number(process.env.CAPTURE_TIMING_CDP_PORT);
assert.ok(Number.isInteger(port) && port > 0 && port < 65536, 'Set CAPTURE_TIMING_CDP_PORT to a dedicated test browser');
const root = await mkdtemp(path.join(os.tmpdir(), 'capture-timing-proof-'));
const title = `Capture timing proof ${path.basename(root)}`;
const server = createServer((_req, res) => {
  res.setHeader('Content-Type', 'text/html');
  res.end(`<title>${title}</title><style>body{background:rgb(240,0,0);font:26px system-ui;padding:30px}button{font:26px system-ui;padding:20px}h1{background:white}</style><h1>${title}</h1><button id="green" onclick="document.body.style.background='rgb(0,224,0)'">Green</button><button id="blue" onclick="document.body.style.background='rgb(0,0,240)'">Blue</button><button id="red" onclick="document.body.style.background='rgb(240,0,0)'">Red</button>`);
});
server.listen(0, '127.0.0.1'); await once(server, 'listening');
const url = `http://127.0.0.1:${server.address().port}/`;
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
let sequence = 0;
const pending = new Map();
socket.addEventListener('message', ({ data }) => {
  const message = JSON.parse(data); const request = pending.get(message.id); if (!request) return;
  clearTimeout(request.timer); pending.delete(message.id);
  if (message.error) request.reject(new Error(JSON.stringify(message.error))); else request.resolve(message.result);
});
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence; const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 10000);
    pending.set(id, { resolve, reject, timer }); socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await call('Runtime.evaluate', { expression, returnByValue: true });
  assert.equal(result.exceptionDetails, undefined); return result.result.value;
}
async function wait(check, label) {
  for (let i = 0; i < 100; i++) { if (await check()) return; await delay(100); }
  throw new Error(`Timed out: ${label}`);
}
let child;
try {
  await call('Page.bringToFront');
  await wait(() => evaluate(`document.title === ${JSON.stringify(title)}`), 'test document loaded');
  const windows = JSON.parse(execFileSync(helper, ['list', '--json'], { encoding: 'utf8' })).windows;
  const window = windows.find(window => window.title.includes(title) && window.width > 300);
  assert.ok(window, 'Owned test document must have an exact capture window');
  const video = path.join(root, 'recording.mp4');
  child = spawn(helper, ['record', '--framed', '--window-id', String(window.id), '--max-fps', '30', '--output', video], { stdio: ['pipe', 'ignore', 'pipe'] });
  const exited = once(child, 'exit');
  const events = []; let buffered = '';
  child.stderr.on('data', chunk => {
    buffered += chunk.toString();
    const lines = buffered.split('\n'); buffered = lines.pop();
    for (const line of lines) if (line.trim()) events.push(JSON.parse(line));
  });
  await wait(() => events.some(event => event.type === 'info' && event.msg === 'record frames=1'), 'first recorded frame');
  const actions = [];
  for (const [color, channel] of [['green', 1], ['blue', 2], ['red', 0]]) {
    const point = await evaluate(`(()=>{const r=document.querySelector('#${color}').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    const started = Date.now();
    await call('Input.dispatchMouseEvent', { ...point, type: 'mousePressed', button: 'left', clickCount: 1 });
    await call('Input.dispatchMouseEvent', { ...point, type: 'mouseReleased', button: 'left', clickCount: 1 });
    await delay(200);
    const snapshotPath = path.join(root, `${color}.png`);
    const requested = Date.now(); child.stdin.write(`snapshot ${snapshotPath}\n`);
    await wait(() => events.some(event => event.type === 'snapshot' && event.output === snapshotPath), `${color} snapshot`);
    actions.push({ color, channel, started, requested, received: Date.now(), snapshotPath });
    await delay(color === 'green' ? 1400 : 300);
  }
  child.stdin.end('stop\n');
  const [code] = await exited; assert.equal(code, 0, JSON.stringify(events));
  const complete = events.find(event => event.type === 'record_complete');
  assert.ok(complete?.timing_path);
  const timing = JSON.parse(await readFile(complete.timing_path, 'utf8'));
  const hash = createHash('sha256').update(await readFile(video)).digest('hex');
  assert.equal(timing.video_digest, `sha256:${hash}`);
  const probe = JSON.parse(execFileSync('ffprobe', ['-v','error','-select_streams','v:0','-show_entries','frame=best_effort_timestamp_time','-of','json',video], { encoding:'utf8' }));
  const measured = probe.frames.map(frame => Number(frame.best_effort_timestamp_time) * 1000);
  assert.equal(timing.frames_ms.length, measured.length);
  measured.forEach((value, index) => assert.ok(Math.abs(value - timing.frames_ms[index]) < 0.01));
  const pixels = execFileSync('ffmpeg', ['-v','error','-i',video,'-vf','crop=2:2:iw*0.8:ih*0.8,scale=1:1','-fps_mode','passthrough','-f','rawvideo','-pix_fmt','rgb24','pipe:1']);
  for (const action of actions) {
    const row = timing.snapshots.find(snapshot => snapshot.output === action.snapshotPath);
    assert.equal(row.recording_id, complete.recording_id);
    assert.equal(row.writer_accepted, true);
    assert.ok(Number.isInteger(row.encoded_frame_index));
    assert.ok(Math.abs(timing.frames_ms[row.encoded_frame_index] - row.media_time_ms) < 0.01);
    const png = execFileSync('ffmpeg', ['-v','error','-i',action.snapshotPath,'-vf','crop=2:2:iw*0.8:ih*0.8,scale=1:1','-f','rawvideo','-pix_fmt','rgb24','pipe:1']);
    const rgb = pixels.subarray(row.encoded_frame_index * 3, row.encoded_frame_index * 3 + 3);
    assert.ok(png[action.channel] > 170 && rgb[action.channel] > 170, `${action.color} screenshot and matching frame must agree: ${[...png]} / ${[...rgb]}`);
    for (let channel=0; channel<3; channel++) if (channel !== action.channel) assert.ok(png[channel] < 60 && rgb[channel] < 60);
    const lower = timing.clock.earliest_zero_unix_ms + row.media_time_ms;
    const upper = timing.clock.latest_zero_unix_ms + row.media_time_ms;
    assert.ok(upper >= action.started && lower <= action.received, 'source frame must lie within the real interaction/snapshot window');
  }
  const result = { pass: true, root, frames: timing.frames_ms.length, durationMs: timing.duration_ms, snapshots: timing.snapshots.length, recordingId: complete.recording_id, nativeTimelineMatchesMp4: true, snapshotPixelsMatchEncodedFrames: true };
  await writeFile(path.join(root, 'proof.json'), JSON.stringify({ ...result, actions, events }, null, 2));
  console.log(JSON.stringify(result));
} finally {
  if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGINT');
  socket.close(); await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`); server.close();
}
