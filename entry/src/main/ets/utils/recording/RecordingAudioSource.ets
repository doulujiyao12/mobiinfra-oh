export type RecordingAudioSource = 'environment' | 'mixed' | 'system';
export function recordingAudioSource(value: string): RecordingAudioSource {
  return value === 'mixed' || value === 'system' ? value : 'environment';
}
export function recordingAudioSourceLabel(value: string): string {
  return value === 'mixed' ? '环境音 + 系统声音' : value === 'system' ? '仅系统声音' : '环境音';
}
export interface RecordingAudioFrame { mic: boolean; timestampMs: number; receivedMs: number; data: ArrayBuffer; }
interface AudioSpan { start: number; mic: boolean; samples: Int16Array; }
class AudioTrack {
  offset: number = 0;
  lastTimestamp: number = -1;
  end: number = 0;
}

// AVScreenCapture supplies two timestamped PCM16/16kHz/mono tracks. Mix on a
// shared sample timeline, not by concatenating callbacks (which doubles duration).
export class RecordingAudioMixer {
  private mixed: boolean;
  private origin: number = 0;
  private originReady: boolean = false;
  private cursor: number = 0;
  private end: number = 0;
  private spans: AudioSpan[] = [];
  private inner: AudioTrack = new AudioTrack();
  private microphone: AudioTrack = new AudioTrack();
  private realigned: number = 0;
  private lateSamples: number = 0;
  constructor(mixed: boolean) { this.mixed = mixed; }
  append(frames: RecordingAudioFrame[]): void {
    for (let frame of frames) {
      if (!this.mixed && frame.mic) { continue; }
      if (!Number.isFinite(frame.timestampMs) || frame.timestampMs < 0 ||
        !Number.isFinite(frame.receivedMs) || frame.receivedMs < 0 || frame.data.byteLength % 2 !== 0) {
        throw new Error('系统音频数据格式异常');
      }
      if (frame.data.byteLength === 0) { continue; }
      if (frame.data.byteLength > 128000) { throw new Error('系统单帧音频数据过大'); }
      let track = frame.mic ? this.microphone : this.inner;
      let receivedEnd = Math.round(frame.receivedMs * 16);
      let receivedStart = Math.max(0, receivedEnd - frame.data.byteLength / 2);
      if (!this.originReady) {
        this.origin = frame.timestampMs - receivedStart / 16; this.originReady = true;
      }
      let start = Math.round((frame.timestampMs - this.origin) * 16) + track.offset;
      // SDK timestamps can reset when an output route changes, or the two
      // sources can use different origins. Re-anchor just that track to the
      // native monotonic arrival clock, never to Date.now() or the UI timer.
      if (start + frame.data.byteLength / 2 > receivedEnd + 8000 ||
        start + frame.data.byteLength / 2 < receivedEnd - 32000 ||
        (track.lastTimestamp >= 0 && frame.timestampMs <= track.lastTimestamp)) {
        let aligned = Math.max(track.end, receivedStart, this.cursor);
        track.offset += aligned - start; start = aligned; this.realigned++;
      }
      // Small timestamp rounding differences must not create repeated holes.
      if (track.lastTimestamp >= 0 && Math.abs(start - track.end) <= 160) { start = track.end; }
      track.lastTimestamp = frame.timestampMs;
      track.end = Math.max(track.end, start + frame.data.byteLength / 2);
      let samples = new Int16Array(frame.data.byteLength / 2), view = new DataView(frame.data);
      for (let i = 0; i < samples.length; i++) { samples[i] = view.getInt16(i * 2, true); }
      // Already committed WAV samples cannot be rewritten. Keep any uncommitted
      // tail of a late callback; a delayed source must not terminate both tracks.
      if (start < this.cursor) {
        let skipped = Math.min(samples.length, this.cursor - start);
        this.lateSamples += skipped; samples = samples.slice(skipped); start += skipped;
      }
      if (samples.length === 0) { continue; }
      let span: AudioSpan = { start: start, mic: frame.mic, samples: samples };
      this.spans.push(span); this.end = Math.max(this.end, start + samples.length);
      let buffered = this.spans.reduce((total: number, item: AudioSpan): number => total + item.samples.length, 0);
      if (this.spans.length > 512 || buffered > 128000) { throw new Error('音频处理未能及时跟上，已结束录音并保留已录内容'); }
    }
  }
  advance(elapsedMs: number): void {
    if (!Number.isFinite(elapsedMs) || elapsedMs < 0) { throw new Error('系统录音时钟异常'); }
    this.end = Math.max(this.end, Math.round(elapsedMs * 16));
  }
  takeNotice(): string {
    if (this.realigned === 0 && this.lateSamples === 0) { return ''; }
    let notice = 'clock_realignments=' + this.realigned + ' late_samples=' + this.lateSamples;
    this.realigned = 0; this.lateSamples = 0; return notice;
  }
  drain(final: boolean, write: (buffer: ArrayBuffer) => void): boolean {
    // Retain 500ms for cross-source callback skew. Advance silence from the
    // capture clock, including playback pauses. Limit each UI turn to 2s of
    // output; a long quiet interval must not block the UI or allocate a gap.
    let target = final ? this.end : Math.max(this.cursor, this.end - 8000);
    let until = Math.min(target, this.cursor + 32000);
    while (this.cursor < until) {
      let count = Math.min(1600, until - this.cursor), inner = new Int16Array(count), mic = new Int16Array(count);
      for (let span of this.spans) {
        let first = Math.max(this.cursor, span.start), last = Math.min(this.cursor + count, span.start + span.samples.length);
        let target = span.mic ? mic : inner;
        for (let pos = first; pos < last; pos++) { target[pos - this.cursor] = span.samples[pos - span.start]; }
      }
      let buffer = new ArrayBuffer(count * 2), output = new DataView(buffer);
      for (let i = 0; i < count; i++) {
        let value = this.mixed ? Math.round((inner[i] + mic[i]) / 2) : inner[i];
        output.setInt16(i * 2, Math.max(-32768, Math.min(32767, value)), true);
      }
      write(buffer); this.cursor += count;
      this.spans = this.spans.filter((span: AudioSpan): boolean => span.start + span.samples.length > this.cursor);
    }
    return this.cursor < target;
  }
}
