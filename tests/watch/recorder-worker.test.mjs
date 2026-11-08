import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHarness } from './worker-harness.mjs';

function fixture(t) {
  const base = fileURLToPath(new URL('../../.codex-tmp/watch-tests/', import.meta.url));
  fs.mkdirSync(base, { recursive: true });
  const directory = fs.mkdtempSync(path.join(base, 'recording-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function pcm(bytes, value = 1600) {
  return Int16Array.from({ length: bytes / 2 }, (_, i) => i % 2 ? -value : value).buffer;
}
function files(directory) { return fs.readdirSync(path.join(directory, 'recordings')); }
function lastLibrary(harness) { return harness.events.filter(event => event.kind === 'library').at(-1); }

test('Worker records exact samples despite short writes and finalizes a playable WAV', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory, { maxWrite: 17 });
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  assert.equal(h.events.at(-1).kind, 'started');
  h.capture(pcm(6400));
  await h.post({ kind: 'stop' });
  const names = files(directory);
  assert.equal(names.length, 1);
  assert.ok(names[0].endsWith('.wav'));
  const data = fs.readFileSync(path.join(directory, 'recordings', names[0]));
  assert.equal(data.length, 6444);
  assert.equal(data.readUInt32LE(40), 6400);
  assert.equal(data.readInt16LE(44), 1600);
  assert.equal(data.readInt16LE(6442), -1600);
  assert.equal(lastLibrary(h).records[0].durationMs, 200);
  assert.ok(h.syncs >= 2);
  assert.equal(h.microphones[0].state, 4);
});

test('a callback crossing five minutes splits losslessly without recreating the microphone', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  h.capture(pcm(16000 * 2 * 300 - 3200, 1600));
  h.capture(pcm(6400, 3200));
  await h.post({ kind: 'stop' });
  const names = files(directory).sort();
  assert.equal(names.length, 2);
  const first = fs.readFileSync(path.join(directory, 'recordings', names[0]));
  const second = fs.readFileSync(path.join(directory, 'recordings', names[1]));
  assert.equal(first.readUInt32LE(40), 16000 * 2 * 300);
  assert.equal(second.readUInt32LE(40), 3200);
  assert.equal(first.readInt16LE(first.length - 2), -3200);
  assert.equal(second.readInt16LE(44), 3200);
  assert.equal(h.microphones.length, 1);
});

test('abnormal process exit recovers a stale header from actual on-disk PCM', async t => {
  const directory = fixture(t);
  const first = await createHarness(directory);
  await first.post({ kind: 'start' });
  first.capture(pcm(64000));
  assert.ok(files(directory)[0].endsWith('.part'));
  first.dispose();
  const second = await createHarness(directory);
  t.after(second.dispose);
  assert.equal(lastLibrary(second).recoveredCount, 1);
  assert.equal(lastLibrary(second).records[0].durationMs, 2000);
  const name = files(directory)[0];
  assert.ok(name.endsWith('.wav'));
  const data = fs.readFileSync(path.join(directory, 'recordings', name));
  assert.equal(data.readUInt32LE(40), 64000);
  assert.equal(data.length, 64044);
});

test('audio interruption saves the file and does not restart recording', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  h.capture(pcm(32000));
  await h.interrupt();
  assert.equal(h.microphones[0].state, 4);
  assert.ok(h.events.some(event => event.kind === 'stopped' && event.message.includes('麦克风')));
  assert.equal(lastLibrary(h).records.length, 1);
  assert.equal(h.microphones.length, 1);
});

test('a damaged partial file is preserved and does not block recovery of the remaining files', async t => {
  const directory = fixture(t);
  const first = await createHarness(directory);
  await first.post({ kind: 'start' });
  first.capture(pcm(32000));
  first.dispose();
  const damaged = path.join(directory, 'recordings', 'cm_1000000000000_001_16000.wav.part');
  fs.writeFileSync(damaged, Buffer.alloc(100));
  const second = await createHarness(directory);
  t.after(second.dispose);
  assert.equal(lastLibrary(second).recoveredCount, 1);
  assert.equal(lastLibrary(second).records.length, 1);
  assert.equal(fs.readFileSync(damaged).length, 100);
  assert.ok(second.events.some(event => event.kind === 'ready' && event.message.includes('损坏')));
});

test('48 kHz fallback describes its real sample rate and duration', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory, { reject16k: true });
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  h.capture(pcm(96000));
  await h.post({ kind: 'stop' });
  assert.equal(lastLibrary(h).records[0].durationMs, 1000);
  const data = fs.readFileSync(path.join(directory, 'recordings', files(directory)[0]));
  assert.equal(data.readUInt32LE(24), 48000);
});

test('low storage prevents capture and unsafe deletion cannot escape the recording directory', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  h.state.freeBytes = 1024;
  await h.post({ kind: 'start' });
  assert.equal(h.microphones.length, 0);
  assert.ok(h.events.some(event => event.kind === 'stopped' && event.message.includes('空间')));
  const valuable = path.join(directory, 'valuable.txt');
  fs.writeFileSync(valuable, 'keep');
  await h.post({ kind: 'delete', name: '../valuable.txt' });
  assert.equal(fs.readFileSync(valuable, 'utf8'), 'keep');
  assert.equal(h.events.at(-1).kind, 'error');
});

test('default sound mode saves no silence, retains microphone between clips and uses real clip times', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  const startAt = h.state.now;
  await h.post({ kind: 'start' });
  h.capture(pcm(32000 * 5, 0));
  assert.deepEqual(files(directory), []);
  assert.equal(h.microphones[0].state, 2);
  h.capture(pcm(32000));
  h.capture(pcm(32000 * 5, 0));
  assert.equal(files(directory).length, 1);
  assert.ok(files(directory)[0].endsWith('.wav'));
  assert.equal(h.microphones[0].state, 2);
  h.capture(pcm(32000));
  await h.post({ kind: 'stop' });
  const records = lastLibrary(h).records;
  assert.equal(records.length, 2);
  assert.equal(records[0].createdAt, startAt + 10120);
  assert.equal(records[1].createdAt, startAt + 4120);
  assert.equal(records[0].durationMs + records[1].durationMs, 5760);
  assert.equal(h.events.findLast(e => e.kind === 'stopped').listeningMs, 12000);
  assert.equal(h.microphones.length, 1);
  assert.equal(h.microphones[0].state, 4);
  assert.equal(h.state.detectorCalls, 0);
});

test('stop during silence creates no empty WAV and releases capture', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  h.capture(pcm(32000 * 10, 0));
  await h.post({ kind: 'stop' });
  assert.deepEqual(files(directory), []);
  assert.equal(h.microphones[0].state, 4);
  assert.match(h.events.findLast(e => e.kind === 'stopped').message, /没有检测到/);
});

test('quiet listening still reaches the six-hour session limit', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory);
  t.after(h.dispose);
  await h.post({ kind: 'start' });
  h.state.now += 6 * 3600000;
  h.capture(pcm(640, 0)); // Fresh data avoids the no-data watchdog taking precedence.
  await h.checkpoint();
  assert.equal(h.microphones[0].state, 4);
  assert.deepEqual(files(directory), []);
  assert.ok(h.events.some(e => e.kind === 'stopped' && /6 小时监听/.test(e.message)));
});

test('speech detector failure stops visibly, without falling back to sound mode', async t => {
  const directory = fixture(t);
  const h = await createHarness(directory, { failDetector: true });
  t.after(h.dispose);
  await h.post({ kind: 'start', mode: 'speech' });
  assert.equal(h.microphones[0].state, 4);
  assert.deepEqual(files(directory), []);
  assert.ok(h.events.some(e => e.kind === 'stopped' && /人声检测器/.test(e.message)));
  assert.ok(!h.events.some(e => e.kind === 'started'));
});

test('real WebRTC reference decisions drive speech-only saving at 16/48 kHz', async t => {
  const raw = fs.readFileSync(new URL('./fixtures/webrtc-speech-8k.pcm', import.meta.url));
  for (const rate of [16000, 48000]) {
    const repeat = rate / 8000;
    const voice = Buffer.alloc(raw.length * repeat);
    for (let i = 0; i < raw.length / 2; i++) {
      for (let j = 0; j < repeat; j++) { voice.writeInt16LE(raw.readInt16LE(i * 2), (i * repeat + j) * 2); }
    }
    // A loud low-frequency non-speech tone precedes speech. It should not open a clip.
    const tone = Buffer.alloc(rate * 2 * 3);
    for (let i = 0; i < rate * 3; i++) { tone.writeInt16LE(Math.round(10000 * Math.sin(2 * Math.PI * 100 * i / rate)), i * 2); }
    const prefix = Buffer.concat([Buffer.alloc(rate * 2), tone, Buffer.alloc(rate * 2)]);
    const input = Buffer.concat([prefix, voice, Buffer.alloc(rate * 2 * 3)]);
    const reference = spawnSync('python', [fileURLToPath(new URL('./vad-reference.py', import.meta.url)), String(rate)],
      { input, encoding: 'utf8' });
    if (reference.status === 77) { t.skip('Install optional host webrtcvad-wheels dependency; see README'); return; }
    assert.equal(reference.status, 0, reference.stderr);
    const decisions = JSON.parse(reference.stdout);
    assert.ok(decisions.some(Boolean), 'actual speech fixture must be detected');
    assert.ok(decisions.slice(-50).every(x => !x), 'silence must stop being classified as speech');
    let cursor = 0;
    const directory = fixture(t);
    const h = await createHarness(directory, { reject16k: rate === 48000,
      speechClassifier: (_pcm, actualRate, mode) => {
        assert.equal(actualRate, rate);
        assert.equal(mode, 2);
        return decisions[cursor++];
      } });
    t.after(h.dispose);
    await h.post({ kind: 'start', mode: 'speech' });
    h.capture(prefix.buffer.slice(prefix.byteOffset, prefix.byteOffset + prefix.byteLength));
    assert.deepEqual(files(directory), [], 'VAD must reject the non-speech prefix despite its volume');
    // Split SDK callbacks across native VAD frame boundaries.
    for (let i = prefix.length; i < input.length; i += 1778) {
      const part = input.subarray(i, i + 1778);
      h.capture(part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength));
    }
    assert.equal(h.microphones[0].state, 2);
    await h.post({ kind: 'stop' });
    assert.equal(cursor, decisions.length);
    assert.equal(h.state.detectorCloses, 1);
    const records = lastLibrary(h).records;
    assert.equal(records.length, 1);
    assert.equal(records[0].mode, 'speech');
    assert.ok(records[0].durationMs > 2000 && records[0].durationMs < input.length / (rate * 2) * 1000);
    assert.equal(fs.readFileSync(records[0].path).readUInt32LE(24), rate);
  }
});
