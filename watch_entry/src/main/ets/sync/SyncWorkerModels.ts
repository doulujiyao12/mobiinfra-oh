import { RecordingPage, SyncRequest, TransferOffer } from './SyncProtocol';

export class SyncStoreCommand {
  kind: string = '';
  requestId: number = 0;
  filesDir: string = '';
  peer: string = '';
  id: string = '';
  cursor: string = '';
  limit: number = 6;
  confirmation: SyncRequest = new SyncRequest();
}

export class SyncStoreResult {
  requestId: number = 0;
  error: string = '';
  code: string = '';
  sourceId: string = '';
  page: RecordingPage = new RecordingPage();
  offer: TransferOffer = new TransferOffer();
  ids: string[] = [];
}
