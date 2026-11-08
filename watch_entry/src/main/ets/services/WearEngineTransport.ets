import { wearEngine } from '@kit.WearEngine';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { MAX_MESSAGE_BYTES, SyncFailure, SyncTransport } from '../sync/SyncProtocol';
import { backgroundTasks } from './BackgroundTasks';
import { withTimeout } from '../core/Async';

class ActiveTransfer {
  file: wearEngine.P2pFile;
  reject: (error: Error) => void;
  closed: boolean = false;
  constructor(file: wearEngine.P2pFile, reject: (error: Error) => void) {
    this.file = file;
    this.reject = reject;
  }
}

export class WearEngineTransport implements SyncTransport {
  private client: wearEngine.P2pClient;
  private deviceId: string;
  private peer: wearEngine.P2pAppParam;
  private transferJob: ActiveTransfer | undefined = undefined;
  private open: boolean = true;
  private operation: Promise<void> | undefined = undefined;
  private transferGeneration: number = 0;

  constructor(client: wearEngine.P2pClient, deviceId: string, peer: wearEngine.P2pAppParam) {
    this.client = client; this.deviceId = deviceId; this.peer = peer;
  }

  async send(text: string): Promise<void> {
    const content: Uint8Array = new util.TextEncoder().encodeInto(text);
    if (content.byteLength > MAX_MESSAGE_BYTES) { throw new SyncFailure('MESSAGE_TOO_LARGE', '消息超过 4096 字节'); }
    let lastError: Error = new Error('消息发送失败');
    for (let attempt: number = 0; attempt < 3; attempt++) {
      if (!this.open) { throw new Error('手机连接已关闭'); }
      try {
        const result: wearEngine.P2pResult = await withTimeout(
          this.client.sendMessage(this.deviceId, this.peer, { content }), 10000, '手机消息发送超时');
        if (result.code !== wearEngine.P2pResultCode.COMMUNICATION_SUCCESS) {
          throw new Error(`手机消息发送失败 (${result.code})`);
        }
        return;
      } catch (error) { lastError = error as Error; }
      if (attempt < 2) { await new Promise<void>((resolve) => { setTimeout(resolve, 500 * (attempt + 1)); }); }
    }
    throw lastError;
  }

  transfer(path: string, progress: (value: number) => void): Promise<void> {
    if (!this.open || this.operation !== undefined) { return Promise.reject(new Error('文件通道忙或已关闭')); }
    const operation: Promise<void> = this.runTransfer(path, progress);
    this.operation = operation;
    return operation.finally(() => { if (this.operation === operation) { this.operation = undefined; } });
  }

  private async runTransfer(path: string, progress: (value: number) => void): Promise<void> {
    const generation: number = ++this.transferGeneration;
    await backgroundTasks.setMode('dataTransfer', true);
    try {
      if (!this.open || generation !== this.transferGeneration) { throw new Error('文件传输已取消'); }
      const file: wearEngine.P2pFile = { file: fs.openSync(path, fs.OpenMode.READ_ONLY) };
      await new Promise<void>((resolve, reject) => {
        const job: ActiveTransfer = new ActiveTransfer(file, reject);
        this.transferJob = job;
        try {
          this.client.transferFile(this.deviceId, this.peer, file, (error: BusinessError, result: wearEngine.P2pResult): void => {
            if (job.closed) { return; }
            if (error) { this.finish(job); reject(new Error(`${error.message} (${error.code})`)); return; }
            if (result.progress !== undefined) { progress(result.progress); }
            // 100% progress is not a terminal success; only SDK code 207 is.
            if (result.code === wearEngine.P2pResultCode.COMMUNICATION_SUCCESS) {
              this.finish(job); resolve();
            } else if (result.code !== undefined) {
              this.finish(job); reject(new Error(`文件传输失败 (${result.code})`));
            }
          });
        } catch (error) { this.finish(job); reject(error as Error); }
      });
    } finally { await backgroundTasks.setMode('dataTransfer', false); }
  }

  private finish(job: ActiveTransfer): void {
    if (job.closed) { return; }
    job.closed = true;
    try { fs.closeSync(job.file.file.fd); } catch (_) {}
    if (this.transferJob === job) { this.transferJob = undefined; }
  }

  async cancel(): Promise<void> {
    this.transferGeneration++;
    const operation: Promise<void> | undefined = this.operation;
    const job: ActiveTransfer | undefined = this.transferJob;
    if (job !== undefined && !job.closed) {
      try {
      // Preserve the same file object/descriptor until cancellation has completed.
      await withTimeout(this.client.cancelFileTransfer(this.deviceId, this.peer, job.file), 5000, '取消传输超时');
      } catch (_) { /* A disconnected service can no longer complete its transfer. */ }
      finally { this.finish(job); job.reject(new Error('文件传输已取消')); }
    }
    // Also drain an in-flight background-task request before a retry can start.
    try { await operation; } catch (_) {}
  }

  async close(): Promise<void> { this.open = false; await this.cancel(); }
}
