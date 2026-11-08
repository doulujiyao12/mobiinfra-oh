import test from 'node:test';
import assert from 'node:assert/strict';
import { createWavHeader, isOwnWavHeader, alignedPcmBytes, parseRecordingName,
  recordingFileName, triggeredFileName, formatDuration, WAV_HEADER_BYTES, SEGMENT_SECONDS } from '../../watch_entry/src/main/ets/core/Wav.ts';

test('16/48 kHz WAV is valid PCM and describes exactly five minutes', () => {
  for (const rate of [16000, 48000]) {
    const bytes = rate * 2 * SEGMENT_SECONDS;
    const header = createWavHeader(bytes, rate);
    const view = new DataView(header);
    assert.equal(header.byteLength, 44);
    assert.equal(new TextDecoder().decode(header.slice(0, 4)), 'RIFF');
    assert.equal(view.getUint32(4, true), bytes + 36);
    assert.equal(view.getUint32(28, true), rate * 2);
    assert.equal(view.getUint16(22, true), 1);
    assert.equal(view.getUint16(34, true), 16);
    assert.equal(view.getUint32(40, true), bytes);
    assert.ok(isOwnWavHeader(header, rate));
    assert.ok(WAV_HEADER_BYTES + bytes < 100 * 1024 * 1024);
  }
});

test('a crash recovery rebuilds lengths from actual aligned bytes, not stale header counters', () => {
  const staleHeader = createWavHeader(0, 16000);
  assert.ok(isOwnWavHeader(staleHeader, 16000));
  const actualFileSize = 44 + 32000 * 17 + 1;
  const recoveredBytes = alignedPcmBytes(actualFileSize - 44);
  const repaired = new DataView(createWavHeader(recoveredBytes, 16000));
  assert.equal(repaired.getUint32(40, true), 32000 * 17);
  assert.equal(repaired.getUint32(4, true) + 8, actualFileSize - 1);
  assert.equal(repaired.getUint32(40, true) / repaired.getUint32(28, true), 17);
});

test('recovery rejects unrelated and damaged formats', () => {
  assert.equal(isOwnWavHeader(new ArrayBuffer(44), 16000), false);
  assert.equal(isOwnWavHeader(new ArrayBuffer(12), 16000), false);
  assert.equal(isOwnWavHeader(createWavHeader(32000, 48000), 16000), false);
  const broken = createWavHeader(32000, 16000);
  new DataView(broken).setUint16(22, 2, true);
  assert.equal(isOwnWavHeader(broken, 16000), false);
  assert.throws(() => createWavHeader(2 ** 32, 16000));
  assert.throws(() => createWavHeader(32000, 44100));
  assert.throws(() => createWavHeader(NaN, 16000));
});

test('only owned recording filenames are accepted for recovery/deletion', () => {
  const name = recordingFileName(1793520000000, 2, 16000);
  assert.equal(name, 'cm_1793520000000_002_16000.wav');
  assert.equal(parseRecordingName(name).segment, 2);
  assert.equal(parseRecordingName(name + '.part').partial, true);
  for (const unsafe of ['../' + name, '/tmp/' + name, name + '/..', name + '.exe', 'notes.wav',
    'cm_1793520000000_002_44100.wav']) {
    assert.equal(parseRecordingName(unsafe), undefined);
  }
});

test('duration display stays correct for long sessions', () => {
  assert.equal(formatDuration(0), '00:00');
  assert.equal(formatDuration(59999), '00:59');
  assert.equal(formatDuration(60000), '01:00');
  assert.equal(formatDuration(6 * 3600000), '360:00');
});

test('detected clips preserve their actual timestamps and mode, alongside legacy names', () => {
  for (const mode of ['sound', 'speech']) {
    const name = triggeredFileName(1793520004120, 12345, 48000, mode);
    const parsed = parseRecordingName(name + '.part');
    assert.equal(parsed.timestamp, 1793520004120);
    assert.equal(parsed.segment, 12345);
    assert.equal(parsed.mode, mode);
    assert.equal(parsed.version, 2);
    assert.equal(parsed.partial, true);
    assert.equal(parseRecordingName('../' + name), undefined);
    assert.equal(parseRecordingName(name.replace(mode, 'unknown')), undefined);
  }
  assert.equal(parseRecordingName('cm_1793520000000_002_16000.wav').version, 1);
});
