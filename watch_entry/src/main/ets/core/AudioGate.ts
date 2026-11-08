import type { RecordingMode } from '../model/RecorderModels';

export const FRAME_MS: number = 20;
export const PRE_ROLL_MS: number = 1000;
export const SILENCE_TAIL_MS: number = 2000;
const ONSET_WINDOW: number = 10;
const ONSET_POSITIVES: number = 6;

export interface GateSink {
  begin(startSample: number): void;
  write(pcm: ArrayBuffer): void;
  end(): void;
}

export type SpeechClassifier = (pcm: ArrayBuffer) => boolean;

/** Streaming gate: bounded RAM, exact 20 ms frames, no microphone lifecycle calls. */
export class AudioGate {
  private mode: RecordingMode;
  private classifier: SpeechClassifier;
  private frameSamples: number;
  private frame: Int16Array;
  private filled: number = 0;
  private processedSamples: number = 0;
  private preRoll: ArrayBuffer[] = [];
  private onset: boolean[] = [];
  private positives: number = 0;
  private quietFrames: number = 0;
  private active: boolean = false;
  private noiseDb: number = -60;
  private db: number = -100;

  constructor(sampleRate: number, mode: RecordingMode, classifier: SpeechClassifier) {
    if (sampleRate !== 16000 && sampleRate !== 48000) { throw new Error('不支持的检测采样率'); }
    this.mode = mode;
    this.classifier = classifier;
    this.frameSamples = sampleRate * FRAME_MS / 1000;
    this.frame = new Int16Array(this.frameSamples);
  }

  isSaving(): boolean { return this.active; }

  level(): number { return Math.min(1, Math.max(0, (this.db + 60) / 60)); }

  consume(pcm: ArrayBuffer, sink: GateSink): void {
    if (pcm.byteLength % 2 !== 0) { throw new Error('收到不完整的 PCM 音频帧'); }
    const input: Int16Array = new Int16Array(pcm);
    let offset: number = 0;
    while (offset < input.length) {
      const count: number = Math.min(this.frameSamples - this.filled, input.length - offset);
      // Copy before returning from the SDK callback: its input storage may be reused.
      this.frame.set(input.subarray(offset, offset + count), this.filled);
      offset += count;
      this.filled += count;
      if (this.filled === this.frameSamples) {
        const complete: Int16Array = this.frame;
        this.frame = new Int16Array(this.frameSamples);
        this.filled = 0;
        this.accept(complete, sink);
      }
    }
  }

  /** Preserve the last <20 ms on user stop/interruption only if a clip is open. */
  flush(sink: GateSink): void {
    if (this.active && this.filled > 0) {
      sink.write(this.frame.slice(0, this.filled).buffer as ArrayBuffer);
    }
    this.filled = 0;
    this.preRoll = [];
    this.onset = [];
    this.positives = 0;
    this.active = false;
  }

  private accept(samples: Int16Array, sink: GateSink): void {
    let sum: number = 0;
    let squares: number = 0;
    for (let i: number = 0; i < samples.length; i++) {
      const value: number = samples[i] / 32768;
      sum += value;
      squares += value * value;
    }
    // Remove DC offset so a constant sensor offset cannot trigger recording.
    const mean: number = sum / samples.length;
    const power: number = Math.max(0, squares / samples.length - mean * mean);
    this.db = 10 * Math.log10(Math.max(power, 1e-10));
    const openDb: number = Math.max(-42, Math.min(-24, this.noiseDb + 10));
    const holdDb: number = Math.max(-48, Math.min(-30, this.noiseDb + 6));
    const pcm: ArrayBuffer = samples.buffer as ArrayBuffer;
    const detected: boolean = this.mode === 'speech' ? this.classifier(pcm) :
      this.db >= (this.active ? holdDb : openDb);
    this.processedSamples += samples.length;

    if (this.active) {
      sink.write(pcm);
      this.quietFrames = detected ? 0 : this.quietFrames + 1;
      if (this.quietFrames >= SILENCE_TAIL_MS / FRAME_MS) {
        sink.end();
        this.active = false;
        this.quietFrames = 0;
        this.preRoll = [];
        this.onset = [];
        this.positives = 0;
      }
      return;
    }

    if (this.mode === 'sound' && !detected) {
      const rate: number = this.db < this.noiseDb ? 0.05 : 0.01;
      this.noiseDb += (this.db - this.noiseDb) * rate;
    }
    this.preRoll.push(pcm);
    if (this.preRoll.length > PRE_ROLL_MS / FRAME_MS) { this.preRoll.shift(); }
    this.onset.push(detected);
    if (detected) { this.positives++; }
    if (this.onset.length > ONSET_WINDOW && this.onset.shift()) { this.positives--; }
    if (this.positives < ONSET_POSITIVES) { return; }

    sink.begin(this.processedSamples - this.preRoll.length * this.frameSamples);
    for (let i: number = 0; i < this.preRoll.length; i++) { sink.write(this.preRoll[i]); }
    this.preRoll = [];
    this.onset = [];
    this.positives = 0;
    this.quietFrames = 0;
    this.active = true;
  }
}
