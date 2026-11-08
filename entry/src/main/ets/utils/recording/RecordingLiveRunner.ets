import worker, { MessageEvents } from '@ohos.worker';
import { RecordingAnalysis, RecordingSegment } from './RecordingTypes';
import { RecordingLiveJob, RecordingLiveRequest, RecordingLiveUpdate, RecordingLiveTranscriber,
  emptyLiveAnalysis, appendLiveUpdate } from './RecordingLiveTypes';

// One request in flight, with bounded file windows instead of queued PCM.
// Slow inference can lag without stopping capture or growing an IPC backlog.
export class RecordingLiveRunner implements RecordingLiveTranscriber {
  private thread: worker.ThreadWorker | null = null;
  private ready: boolean = false;
  private pending: boolean = false;
  private cursor: number = 0;
  private sentEnd: number = 0;
  private finalSamples: number = -1;
  private timer: number = -1;
  private watchdog: number = -1;
  private failure: string = '';
  private result: RecordingAnalysis = emptyLiveAnalysis(0);
  private available: () => number = (): number => 0;
  private update: (value: RecordingLiveUpdate) => void = (): void => {};
  private onFailure: (message: string) => void = (): void => {};
  private resolve: ((value: RecordingAnalysis) => void) | null = null;
  private reject: ((error: Error) => void) | null = null;
  start(job: RecordingLiveJob, available: () => number, update: (value: RecordingLiveUpdate) => void,
    onFailure: (message: string) => void): void {
    this.available = available; this.update = update; this.onFailure = onFailure;
    try {
      const thread = new worker.ThreadWorker('entry/ets/workers/RecordingLiveWorker.ets'); this.thread = thread;
      thread.onmessage = (event: MessageEvents): void => {
        if (this.thread !== thread) { return; }
        try {
          const value = event.data as RecordingLiveUpdate; clearTimeout(this.watchdog);
          if (value.kind === 'error') { this.fail(value.error); return; }
          if (value.kind === 'ready') { this.ready = true; this.pending = false; this.pump(); return; }
          if (!this.pending || value.processed !== this.sentEnd) { throw new Error('实时转写进度不一致'); }
          appendLiveUpdate(this.result, value); this.update(value); this.cursor = value.processed; this.pending = false;
          if (value.kind === 'done') {
            this.result.duration = this.finalSamples / 16000;
            const resolve = this.resolve; this.close(); resolve?.(this.result);
          } else { this.pump(); }
        } catch (e) { this.fail((e as Error).message); }
      };
      thread.onerror = (): void => { if (this.thread === thread) { this.fail('实时转写线程退出'); } };
      thread.onmessageerror = (): void => { if (this.thread === thread) { this.fail('实时转写结果接收失败'); } };
      this.send({ kind: 'start', job: job });
      this.timer = setInterval((): void => { this.pump(); }, 1000);
    } catch (e) { this.fail((e as Error).message); }
  }
  private send(request: RecordingLiveRequest): void {
    this.pending = true;
    this.watchdog = setTimeout((): void => { this.fail('实时转写响应超时，录音仍会保存'); }, 120000);
    try { this.thread?.postMessage(request); } catch (e) { this.fail((e as Error).message); }
  }
  private pump(): void {
    if (!this.ready || this.pending || this.thread === null) { return; }
    const available = this.finalSamples >= 0 ? this.finalSamples : Math.floor(this.available());
    const end = Math.min(available, this.cursor + 64000);
    if (end < this.cursor || !Number.isInteger(end)) { this.fail('实时录音长度无效'); return; }
    const final = this.finalSamples >= 0 && end === this.finalSamples;
    if (end === this.cursor && !final) { return; }
    this.sentEnd = end; this.send({ kind: final ? 'finish' : 'advance', end: end });
  }
  finish(samples: number): Promise<RecordingAnalysis> {
    if (this.failure) { return Promise.reject(new Error(this.failure)); }
    if (!Number.isInteger(samples) || samples < this.cursor) { return Promise.reject(new Error('录音结束位置无效')); }
    this.finalSamples = samples;
    return new Promise<RecordingAnalysis>((resolve, reject): void => { this.resolve = resolve; this.reject = reject; this.pump(); });
  }
  snapshot(duration: number): RecordingAnalysis { this.result.duration = duration; return this.result; }
  recent(): RecordingSegment[] { return this.result.segments.slice(-8); }
  completedSamples(): number { return this.cursor; }
  private close(): void {
    clearInterval(this.timer); clearTimeout(this.watchdog);
    const thread = this.thread; this.thread = null;
    this.resolve = null; this.reject = null;
    if (thread !== null) { try { thread.terminate(); } catch (e) {} }
  }
  private fail(message: string): void {
    if (this.failure) { return; }
    this.failure = message || '实时转写未完成'; const reject = this.reject; this.close();
    reject?.(new Error(this.failure)); this.onFailure(this.failure);
  }
  cancel(): void { if (this.thread !== null) { this.fail('实时转写已停止，已有文字和录音保留'); } }
}
