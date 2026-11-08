import { worker, ThreadWorkerGlobalScope, MessageEvents } from '@kit.ArkTS';
import { RecordingSyncStore } from '../sync/RecordingSyncStore';
import { SyncFailure } from '../sync/SyncProtocol';
import { SyncStoreCommand, SyncStoreResult } from '../sync/SyncWorkerModels';

const port: ThreadWorkerGlobalScope = worker.workerPort;
let store: RecordingSyncStore | undefined = undefined;
let commands: Promise<void> = Promise.resolve();

async function dispatch(command: SyncStoreCommand): Promise<void> {
  const result: SyncStoreResult = new SyncStoreResult();
  result.requestId = command.requestId;
  try {
    if (command.kind === 'init') {
      store = new RecordingSyncStore(command.filesDir);
      result.sourceId = store.sourceId();
    } else {
      if (store === undefined) { throw new SyncFailure('NOT_READY', '同步存储尚未就绪'); }
      if (command.kind === 'list') { result.page = await store.list(command.peer, command.cursor, command.limit); }
      else if (command.kind === 'prepare') { result.offer = await store.prepare(command.peer, command.id); }
      else if (command.kind === 'confirm') { await store.confirm(command.peer, command.confirmation); }
      else if (command.kind === 'confirmed') { result.ids = await store.confirmedIds(command.peer); }
      else { throw new SyncFailure('BAD_REQUEST', '未知同步存储操作'); }
    }
  } catch (error) {
    const code: string = (error as SyncFailure).code;
    result.code = typeof code === 'string' && code.length > 0 ? code : 'STORAGE_ERROR';
    result.error = (error as Error).message || '同步存储失败';
  }
  port.postMessage(result);
}

port.onmessage = (event: MessageEvents): void => {
  commands = commands.then(() => dispatch(event.data as SyncStoreCommand));
};
