import { worker, MessageEvents } from '@kit.ArkTS';
import { RecordingPage, TransferOffer, SyncFailure, SyncRepository, SyncRequest } from '../sync/SyncProtocol';
import { SyncStoreCommand, SyncStoreResult } from '../sync/SyncWorkerModels';

class PendingCall {
  resolve: (result: SyncStoreResult) => void = (_result: SyncStoreResult): void => {};
  reject: (error: Error | SyncFailure) => void = (_error: Error | SyncFailure): void => {};
  timer: number = -1;
}

export class SyncStoreClient implements SyncRepository {
  private instance: worker.ThreadWorker;
  private calls: Map<number, PendingCall> = new Map();
  private sequence: number = 0;
  constructor() {
    this.instance = new worker.ThreadWorker('watch_entry/ets/workers/SyncWorker.ets', { name: 'ClawMateSyncIO' });
    this.instance.onmessage = (event: MessageEvents): void => {
      const result: SyncStoreResult = event.data as SyncStoreResult;
      const pending: PendingCall | undefined = this.calls.get(result.requestId);
      if (pending === undefined) { return; }
      clearTimeout(pending.timer);
      this.calls.delete(result.requestId);
      if (result.error.length > 0) { pending.reject(new SyncFailure(result.code, result.error)); }
      else { pending.resolve(result); }
    };
    this.instance.onerror = (): void => { this.rejectAll('同步线程异常，请重新打开应用'); };
  }

  private rejectAll(message: string): void {
    this.calls.forEach((call: PendingCall) => { clearTimeout(call.timer); call.reject(new Error(message)); });
    this.calls.clear();
  }

  private call(command: SyncStoreCommand): Promise<SyncStoreResult> {
    command.requestId = ++this.sequence;
    return new Promise<SyncStoreResult>((resolve, reject) => {
      const pending: PendingCall = new PendingCall();
      pending.resolve = resolve;
      pending.reject = reject;
      pending.timer = setTimeout(() => {
        this.calls.delete(command.requestId);
        reject(new Error('同步存储响应超时，请重试'));
      }, 60000);
      this.calls.set(command.requestId, pending);
      try { this.instance.postMessage(command); } catch (error) {
        clearTimeout(pending.timer);
        this.calls.delete(command.requestId);
        reject(error as Error);
      }
    });
  }

  async initialize(filesDir: string): Promise<string> {
    const command: SyncStoreCommand = new SyncStoreCommand();
    command.kind = 'init'; command.filesDir = filesDir;
    return (await this.call(command)).sourceId;
  }
  async list(peer: string, cursor: string, limit: number): Promise<RecordingPage> {
    const command: SyncStoreCommand = new SyncStoreCommand();
    command.kind = 'list'; command.peer = peer; command.cursor = cursor; command.limit = limit;
    return (await this.call(command)).page;
  }
  async prepare(peer: string, id: string): Promise<TransferOffer> {
    const command: SyncStoreCommand = new SyncStoreCommand();
    command.kind = 'prepare'; command.peer = peer; command.id = id;
    return (await this.call(command)).offer;
  }
  async confirm(peer: string, request: SyncRequest): Promise<void> {
    const command: SyncStoreCommand = new SyncStoreCommand();
    command.kind = 'confirm'; command.peer = peer; command.confirmation = request;
    await this.call(command);
  }
  async confirmedIds(peer: string): Promise<string[]> {
    const command: SyncStoreCommand = new SyncStoreCommand();
    command.kind = 'confirmed'; command.peer = peer;
    return (await this.call(command)).ids;
  }
  destroy(): void { this.rejectAll('同步服务已关闭'); this.instance.terminate(); }
}
