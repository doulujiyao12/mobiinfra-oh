import { RecordingSegment, SpeechRange } from './RecordingTypes';

export interface RecordingSpeechSpan { source: number; packed: number; length: number; }
export interface RecordingSpeechAudio { samples: Float32Array; spans: RecordingSpeechSpan[]; }

// Keep half a second of real context around speech and between disjoint runs.
// Only long silence is removed; packed times must never become recording times.
export function packRecordingSpeech(samples: Float32Array, speech: SpeechRange[]): RecordingSpeechAudio {
  let windows: SpeechRange[] = [];
  for (let range of speech) {
    let start = Math.max(0, Math.floor((range.start - 0.5) * 16000));
    let end = Math.min(samples.length, Math.ceil((range.end + 0.5) * 16000));
    if (end <= start) { continue; }
    let last = windows[windows.length - 1];
    if (last && start <= last.end + 8000) { last.end = Math.max(last.end, end); }
    else { windows.push({ start: start, end: end }); }
  }
  let spans: RecordingSpeechSpan[] = []; let length = 0;
  for (let window of windows) {
    if (spans.length > 0) { length += 8000; }
    spans.push({ source: window.start, packed: length, length: window.end - window.start });
    length += window.end - window.start;
  }
  if (spans.length === 1 && spans[0].source === 0 && length === samples.length) {
    return { samples: samples, spans: spans };
  }
  let packed = new Float32Array(length);
  for (let span of spans) { packed.set(samples.subarray(span.source, span.source + span.length), span.packed); }
  return { samples: packed, spans: spans };
}

export function restoreRecordingSpeechTurns(turns: RecordingSegment[], spans: RecordingSpeechSpan[]): RecordingSegment[] {
  let restored: RecordingSegment[] = [];
  for (let turn of turns) {
    for (let span of spans) {
      let start = Math.max(turn.start * 16000, span.packed);
      let end = Math.min(turn.end * 16000, span.packed + span.length);
      if (end <= start) { continue; }
      restored.push({ id: restored.length, start: (span.source + start - span.packed) / 16000,
        end: (span.source + end - span.packed) / 16000, speaker: turn.speaker, text: '', language: '' });
    }
  }
  return restored.sort((a: RecordingSegment, b: RecordingSegment): number => a.start - b.start || a.speaker - b.speaker);
}
