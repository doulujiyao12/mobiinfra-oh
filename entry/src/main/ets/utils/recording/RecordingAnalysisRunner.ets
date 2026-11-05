import worker, { MessageEvents } from '@ohos.worker';
import { RecordingAnalysis, RecordingJob, RecordingWorkerMessage } from './RecordingTypes';
import { AppLogger } from '../AppLogger';

export class RecordingAnalysisRunner {
  private thread: worker.ThreadWorker | null = null;
  private reject: ((error: Error) => void) | null = null;
  run(job: RecordingJob, progress: (value: RecordingWorkerMessage) => void): Promise<RecordingAnalysis> {
    this.cancel();
    return new Promise<RecordingAnalysis>((resolve, reject) => {
      let thread = new worker.ThreadWorker('entry/ets/workers/RecordingAnalysisWorker.ets');
      this.thread = thread; this.reject = reject;
      let current: RecordingWorkerMessage | null = null; let began = Date.now();
      let timer = setInterval((): void => {
        if (this.thread !== thread || current === null) { return; }
        let seconds = Math.floor((Date.now() - began) / 1000);
        if (seconds >= 1) {
          progress({ kind: 'progress', progress: current.progress,
            message: current.message + ' · 已用 ' + seconds + ' 秒', result: null });
        }
      }, 1000);
      let finish = (): void => {
        clearInterval(timer);
        try { thread.terminate(); } catch (e) { }
        if (this.thread === thread) { this.thread = null; this.reject = null; this.stopTimer = null; }
      };
      thread.onmessage = (event: MessageEvents): void => {
        if (this.thread !== thread) { return; }
        let message = event.data as RecordingWorkerMessage;
        if (message.kind === 'done' && message.result !== null) { finish(); resolve(message.result); }
        else if (message.kind === 'error') { finish(); reject(new Error(message.message)); }
        else if (message.kind === 'diagnostic') {
          // Logs are optional side effects, not analysis failures or progress.
          try { AppLogger.info('RecordingAnalysis', message.message); } catch (e) { }
        } else { current = message; began = Date.now(); progress(message); }
      };
      thread.onerror = (): void => { if (this.thread === thread) { finish(); reject(new Error('分析线程异常退出，原始录音已保留')); } };
      thread.onmessageerror = (): void => { if (this.thread === thread) { finish(); reject(new Error('分析结果接收失败，原始录音已保留')); } };
      // Cancel must release the status timer as well as terminate the worker.
      this.stopTimer = (): void => { clearInterval(timer); };
      try { thread.postMessage(job); } catch (e) { finish(); reject(new Error((e as Error).message)); }
    });
  }
  private stopTimer: (() => void) | null = null;
  cancel(): void {
    let thread = this.thread; let reject = this.reject; this.thread = null; this.reject = null;
    this.stopTimer?.(); this.stopTimer = null;
    if (thread !== null) { try { thread.terminate(); } catch (e) { } }
    if (reject !== null) { reject(new Error('分析已停止')); }
  }
}
