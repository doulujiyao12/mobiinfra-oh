import { speechRecognizer } from '@kit.CoreSpeechKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buildHarmonyAsrCreateEngineParams, mergeHarmonyAsrFinalTranscript,
  mergeHarmonyAsrPartialTranscript } from '../voice/HarmonySpeechRecognizerAsrProvider';
import { AppLogger } from '../AppLogger';
import { RecordingAnalysis, RecordingJob, RecordingSegment, RecordingWorkerMessage, SpeechRange, recordingTime } from './RecordingTypes';
import { RecordingLiveJob, RecordingLiveState, RecordingLiveTranscriber, RecordingLiveUpdate,
  emptyLiveAnalysis, appendLiveUpdate } from './RecordingLiveTypes';
import { RecordingLiveCheckpoint } from './RecordingLiveCheckpoint';
import { readCapturedPcm, readWav16k, recordingWavDuration } from './RecordingWav';
import { SYSTEM_ASR_MODEL_ID, SYSTEM_ASR_FRAME, SYSTEM_ASR_WINDOW, SYSTEM_ASR_OVERLAP,
  systemAsrStartParams, systemAsrPcm, trimSystemAsrOverlap } from './RecordingSystemAsrPolicy';

// The capture writer owns the microphone and audio file. ASR only reads bounded
// committed PCM windows, so recognizer restarts never interrupt or lose recording.
export class RecordingSystemAsrRunner implements RecordingLiveTranscriber {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private job: RecordingLiveJob | null = null;
  private available: () => number = (): number => 0;
  private update: (value: RecordingLiveUpdate) => void = (): void => {};
  private onFailure: (message: string) => void = (): void => {};
  private result: RecordingAnalysis = emptyLiveAnalysis(0);
  private cursor: number = 0;
  private committed: number = 0;
  private startSample: number = 0;
  private finalSamples: number = -1;
  private ready: boolean = false;
  private flushing: boolean = false;
  private closed: boolean = false;
  private failure: string = '';
  private sessionId: string = '';
  private sequence: number = 0;
  private generation: number = 0;
  private timer: number = -1;
  private watchdog: number = -1;
  private lastReport: number = 0;
  private quietSamples: number = 0;
  private replayed: boolean = false;
  private replayNext: boolean = false;
  private finalText: string = '';
  private lastFinal: string = '';
  private lastFinalAt: number = -1;
  private preview: string = '';
  private cache: Float32Array = new Float32Array(0);
  private cacheStart: number = 0;
  private resolve: ((value: RecordingAnalysis) => void) | null = null;
  private reject: ((error: Error) => void) | null = null;

  start(job: RecordingLiveJob, available: () => number, update: (value: RecordingLiveUpdate) => void,
    onFailure: (message: string) => void): void {
    if (this.job !== null || this.closed) { throw new Error('系统转写不可重复启动'); }
    this.job = job; this.available = available; this.update = update; this.onFailure = onFailure;
    this.result.modelId = SYSTEM_ASR_MODEL_ID; this.result.method = 'system';
    try { this.openEngine(); } catch (e) { this.fail((e as Error).message); }
  }

  // Existing WAVs use the same paced streaming path, not a second ASR pipeline.
  // Checkpoints contain completed sessions only; an interrupted session replays
  // from its start while already committed sessions are reused.
  run(job: RecordingJob, checkpointPath: string,
    progress: (value: RecordingWorkerMessage) => void): Promise<RecordingAnalysis> {
    try {
      const duration = recordingWavDuration(job.audioPath); const total = Math.floor(duration * 16000);
      if (job.restart && fs.accessSync(checkpointPath)) { fs.unlinkSync(checkpointPath); }
      const checkpoint = new RecordingLiveCheckpoint(checkpointPath);
      const restored: RecordingLiveState = checkpoint.restoreState(duration);
      if (restored.analysis.modelId === SYSTEM_ASR_MODEL_ID) {
        this.result = restored.analysis; this.cursor = restored.processed; this.committed = restored.committed;
        const last = this.result.segments[this.result.segments.length - 1];
        this.replayed = last !== undefined && this.cursor < Math.round(last.end * 16000);
      }
      const liveJob: RecordingLiveJob = { audioPath: job.audioPath, modelDir: '', language: 'zh', fileInput: true };
      this.start(liveJob, (): number => total, (value: RecordingLiveUpdate): void => {
        if (value.kind === 'checkpoint' || value.kind === 'done') { checkpoint.append(value); }
        progress({ kind: 'progress', progress: Math.min(99, Math.floor(value.processed * 100 / Math.max(1, total))),
          message: '系统转写 · ' + recordingTime(value.processed / 16000) + ' / ' + recordingTime(duration), result: null });
      }, (): void => {});
      return this.finish(total);
    } catch (e) { this.cancel(); return Promise.reject(new Error((e as Error).message)); }
  }

  private openEngine(): void {
    const generation = ++this.generation;
    this.watchdog = setTimeout((): void => { this.fail('系统语音服务启动超时，录音仍会保留'); }, 15000);
    speechRecognizer.createEngine(buildHarmonyAsrCreateEngineParams('zh-CN')).then(
      (engine: speechRecognizer.SpeechRecognitionEngine): void => {
        if (this.closed || generation !== this.generation) { engine.shutdown(); return; }
        clearTimeout(this.watchdog); this.engine = engine;
        this.beginSession();
        if (!this.closed) { this.timer = setInterval((): void => { this.pumpSafely(); }, 40); }
      }).catch((error: Error): void => { if (!this.closed && generation === this.generation) { this.fail(error.message); } });
  }

  private beginSession(): void {
    const engine = this.engine; if (engine === null || this.closed) { return; }
    this.sessionId = 'recording-' + Date.now() + '-' + (++this.sequence);
    const id = this.sessionId;
    this.startSample = this.cursor; this.finalText = ''; this.preview = ''; this.lastFinal = ''; this.lastFinalAt = -1;
    this.quietSamples = 0; this.ready = false; this.flushing = false; this.replayNext = false;
    this.lastReport = 0;
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (sessionId: string, _message: string): void => {
        if (!this.accepts(sessionId, id)) { return; }
        clearTimeout(this.watchdog); this.ready = true;
      },
      onEvent: (_sessionId: string, _code: number, _message: string): void => {},
      onResult: (sessionId: string, value: speechRecognizer.SpeechRecognitionResult): void => {
        if (!this.accepts(sessionId, id) || !value.result?.trim()) { return; }
        try {
          if (value.isFinal || value.isLast) {
            if (value.result === this.lastFinal && this.cursor === this.lastFinalAt) { return; }
            this.lastFinal = value.result; this.lastFinalAt = this.cursor;
            this.finalText = mergeHarmonyAsrFinalTranscript(this.finalText, value.result, value.isLast);
            this.preview = this.finalText;
          } else { this.preview = mergeHarmonyAsrPartialTranscript(this.finalText, value.result); }
          AppLogger.debug('Recording.SystemASR', 'result session=' + this.sequence + ' final=' + value.isFinal +
            ' last=' + value.isLast + ' chars=' + value.result.length + ' previewChars=' + this.preview.length);
          this.report();
        } catch (e) { this.fail((e as Error).message); }
      },
      onComplete: (sessionId: string, _message: string): void => {
        if (!this.accepts(sessionId, id)) { return; }
        try { this.completeSession(); } catch (e) { this.fail((e as Error).message); }
      },
      onError: (sessionId: string, code: number, message: string): void => {
        if (this.accepts(sessionId, id)) { this.fail('系统语音识别失败（' + code + '）：' + message); }
      }
    };
    engine.setListener(listener);
    this.watchdog = setTimeout((): void => { this.fail('系统语音服务未开始接收音频，录音仍会保留'); }, 15000);
    engine.startListening(systemAsrStartParams(id));
    AppLogger.debug('Recording.SystemASR', 'start session=' + this.sequence + ' sample=' + this.cursor);
  }
  private accepts(sessionId: string, expected: string): boolean {
    return !this.closed && this.engine !== null && sessionId === expected && this.sessionId === expected;
  }
  private pumpSafely(): void {
    try { this.pump(); } catch (e) { this.fail((e as Error).message); }
  }
  private pump(): void {
    if (this.closed || !this.ready || this.flushing || this.engine === null || this.job === null) { return; }
    const available = this.finalSamples >= 0 ? this.finalSamples : Math.floor(this.available());
    const count = Math.min(SYSTEM_ASR_FRAME, available - this.cursor);
    if (count < 0) { throw new Error('系统转写音频长度发生变化'); }
    if (count === 0) {
      if (this.finalSamples >= 0) { this.flush(); }
      return;
    }
    if (count < SYSTEM_ASR_FRAME && this.finalSamples < 0) { return; }
    if (this.cursor < this.cacheStart || this.cursor + count > this.cacheStart + this.cache.length) {
      this.cacheStart = this.cursor; const end = Math.min(available, this.cursor + 64000);
      this.cache = this.job.fileInput ? readWav16k(this.job.audioPath, this.cursor / 16000, end / 16000) :
        readCapturedPcm(this.job.audioPath, this.cursor, end);
    }
    const offset = this.cursor - this.cacheStart; const samples = this.cache.slice(offset, offset + count);
    if (samples.length !== count) { throw new Error('系统转写读取到的音频不完整'); }
    const pcm = systemAsrPcm(samples);
    // Advance before invoking a native method: callbacks may arrive synchronously.
    this.cursor += count;
    const quiet = samples.every((sample: number): boolean => Math.abs(sample) < 0.008);
    this.quietSamples = quiet ? this.quietSamples + count : 0;
    const id = this.sessionId;
    this.engine.writeAudio(id, pcm);
    if (this.closed || this.flushing || id !== this.sessionId) { return; }
    const length = this.cursor - this.startSample;
    if ((this.finalSamples >= 0 && this.cursor >= this.finalSamples) || length >= SYSTEM_ASR_WINDOW ||
      (length >= 45 * 16000 && this.quietSamples >= 8000)) { this.flush(); }
    else if (Date.now() - this.lastReport >= 500) { this.report(); }
  }
  private flush(): void {
    if (this.flushing || this.engine === null) { return; }
    this.flushing = true; this.replayNext = this.quietSamples < 8000 && this.cursor - this.startSample >= SYSTEM_ASR_WINDOW;
    this.watchdog = setTimeout((): void => { this.fail('系统转写结束分段超时，已有文字和录音已保留'); }, 20000);
    this.engine.finish(this.sessionId);
  }
  private completeSession(): void {
    clearTimeout(this.watchdog); this.ready = false; this.flushing = true;
    if (this.cursor <= this.startSample && (this.finalSamples < 0 || this.cursor < this.finalSamples)) {
      throw new Error('系统语音服务未接收音频就结束了识别');
    }
    if (this.cursor < this.committed) { throw new Error('系统语音服务提前结束了衔接分段，请重试'); }
    const segments: RecordingSegment[] = [];
    const previous = this.result.segments[this.result.segments.length - 1]?.text || '';
    const text = trimSystemAsrOverlap(previous, this.finalText, this.replayed).trim();
    if (this.preview && this.preview !== this.finalText) { throw new Error('系统转写未确认最后的文字，已有内容已保留'); }
    if (text && this.cursor > this.startSample) {
      segments.push({ id: this.result.segments.length, start: this.startSample / 16000,
        end: this.cursor / 16000, speaker: -1, text: text, language: 'zh' });
    }
    const done = this.finalSamples >= 0 && this.cursor >= this.finalSamples;
    const resumeAt = !done && this.replayNext ? Math.max(this.startSample, this.cursor - SYSTEM_ASR_OVERLAP) : this.cursor;
    const value: RecordingLiveUpdate = { kind: done ? 'done' : 'checkpoint', processed: this.cursor,
      segments: segments, speech: segments.map((segment: RecordingSegment): SpeechRange => ({ start: segment.start, end: segment.end })),
      error: '', modelId: SYSTEM_ASR_MODEL_ID, method: 'system', resumeAt: resumeAt };
    appendLiveUpdate(this.result, value); this.committed = this.cursor; this.result.duration = this.cursor / 16000;
    this.preview = ''; this.finalText = ''; this.update(value);
    AppLogger.debug('Recording.SystemASR', 'complete session=' + this.sequence + ' samples=' + this.cursor + ' chars=' + text.length);
    if (done) { const resolve = this.resolve; this.close(); resolve?.(this.result); return; }
    this.replayed = resumeAt < this.cursor; this.cursor = resumeAt;
    this.beginSession();
  }
  private report(): void {
    this.lastReport = Date.now();
    this.update({ kind: 'update', processed: this.cursor, segments: [], speech: [], error: '',
      modelId: SYSTEM_ASR_MODEL_ID, method: 'system', preview: this.previewSegment() });
  }
  finish(samples: number): Promise<RecordingAnalysis> {
    if (this.failure) { return Promise.reject(new Error(this.failure)); }
    if (!Number.isInteger(samples) || samples < this.cursor) { return Promise.reject(new Error('录音结束位置无效')); }
    this.finalSamples = samples;
    return new Promise<RecordingAnalysis>((resolve, reject): void => { this.resolve = resolve; this.reject = reject; });
  }
  private previewSegment(): RecordingSegment | undefined {
    const previous = this.result.segments[this.result.segments.length - 1]?.text || '';
    const text = trimSystemAsrOverlap(previous, this.preview, this.replayed).trim();
    if (text && this.cursor > this.startSample) {
      return { id: this.result.segments.length, start: this.startSample / 16000,
        end: this.cursor / 16000, speaker: -1, text: text, language: 'zh' };
    }
    return undefined;
  }
  recent(): RecordingSegment[] {
    const segments = this.result.segments.slice(-7);
    const preview = this.previewSegment();
    if (preview !== undefined) { segments.push(preview); }
    return segments;
  }
  snapshot(duration: number): RecordingAnalysis {
    // Do not mutate the committed checkpoint state when preserving a partial session.
    const result: RecordingAnalysis = { modelId: SYSTEM_ASR_MODEL_ID, method: 'system', duration: duration,
      segments: this.result.segments.slice(), speech: this.result.speech.slice(), speakers: this.result.speakers.slice(), timings: [] };
    const last = this.recent().find((segment: RecordingSegment): boolean => segment.id === this.result.segments.length);
    if (last !== undefined) { result.segments.push(last); result.speech.push({ start: last.start, end: last.end }); }
    return result;
  }
  completedSamples(): number { return this.cursor; }
  private close(): void {
    this.closed = true; this.generation++; clearInterval(this.timer); clearTimeout(this.watchdog);
    const engine = this.engine; this.engine = null;
    this.resolve = null; this.reject = null; this.cache = new Float32Array(0);
    if (engine !== null) { try { engine.shutdown(); } catch (e) {} }
  }
  private fail(message: string): void {
    if (this.closed) { return; }
    this.failure = message || '系统语音识别不可用'; const reject = this.reject; this.close();
    AppLogger.warn('Recording.SystemASR', this.failure); reject?.(new Error(this.failure)); this.onFailure(this.failure);
  }
  cancel(): void { if (!this.closed) { this.fail('系统转写已暂停，录音与已完成文字保留'); } }
}
