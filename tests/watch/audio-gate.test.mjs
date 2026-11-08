import test from 'node:test';
import assert from 'node:assert/strict';
import { AudioGate } from '../../watch_entry/src/main/ets/core/AudioGate.ts';

function samples(ms, rate = 16000, amplitude = 0) {
  return Int16Array.from({ length: ms * rate / 1000 }, (_, i) => i % 2 ? -amplitude : amplitude).buffer;
}

function sink() {
  const clips = [];
  let active;
  return {
    clips,
    begin: startSample => { active = { startSample, chunks: [], ended: false }; clips.push(active); },
    write: pcm => active.chunks.push(Buffer.from(pcm)),
    end: () => { active.ended = true; active = undefined; }
  };
}

test('long silence, DC offsets and isolated short sounds do not produce clips', () => {
  const output = sink();
  const gate = new AudioGate(16000, 'sound', () => { throw new Error('sound mode must not call VAD'); });
  for (let i = 0; i < 20; i++) { gate.consume(samples(1000), output); }
  gate.consume(new Int16Array(16000).fill(10000).buffer, output);
  gate.consume(samples(80, 16000, 5000), output);
  gate.consume(samples(3000), output);
  gate.flush(output);
  assert.equal(output.clips.length, 0);
});

test('pre-roll preserves onset, two-second tail closes the clip, idle audio is discarded', () => {
  const gate = new AudioGate(16000, 'sound', () => false);
  const output = sink();
  gate.consume(samples(5000), output);
  gate.consume(samples(1000, 16000, 5000), output);
  assert.equal(gate.isSaving(), true);
  gate.consume(samples(1980), output);
  assert.equal(gate.isSaving(), true);
  gate.consume(samples(20), output);
  assert.equal(gate.isSaving(), false);
  gate.consume(samples(20000), output);
  assert.equal(output.clips.length, 1);
  const clip = output.clips[0];
  assert.equal(clip.startSample, 4120 * 16);
  assert.equal(clip.ended, true);
  const pcm = Buffer.concat(clip.chunks);
  assert.equal(pcm.length, 3880 * 32);
  assert.equal(pcm.readInt16LE(880 * 32), 5000);
});

test('callback fragmentation and stop preserve every sample of a detected active clip', () => {
  for (const rate of [16000, 48000]) {
    const whole = samples(201, rate, 5000);
    const gate = new AudioGate(rate, 'sound', () => false);
    const output = sink();
    // Deliberately not aligned to 20 ms; includes a partial final frame.
    for (let offset = 0; offset < whole.byteLength; offset += 138) {
      gate.consume(whole.slice(offset, offset + 138), output);
    }
    gate.flush(output);
    assert.equal(output.clips.length, 1);
    assert.deepEqual(Buffer.concat(output.clips[0].chunks), Buffer.from(whole));
  }
});

test('speech mode obeys VAD rather than loudness, with exact full frames at either rate', () => {
  for (const rate of [16000, 48000]) {
    let voiced = false;
    let calls = 0;
    const gate = new AudioGate(rate, 'speech', pcm => {
      assert.equal(pcm.byteLength, rate / 50 * 2);
      calls++;
      return voiced;
    });
    const output = sink();
    gate.consume(samples(3000, rate, 10000), output);
    assert.equal(output.clips.length, 0);
    voiced = true;
    gate.consume(samples(200, rate, 500), output);
    assert.equal(gate.isSaving(), true);
    voiced = false;
    gate.consume(samples(2000, rate, 10000), output);
    assert.equal(gate.isSaving(), false);
    assert.equal(output.clips.length, 1);
    assert.equal(calls, 260);
  }
});
