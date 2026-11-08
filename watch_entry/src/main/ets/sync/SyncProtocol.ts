export const SYNC_PROTOCOL: string = 'clawmate.recordings';
export const SYNC_VERSION: number = 1;
export const MAX_MESSAGE_BYTES: number = 4096;
export const MAX_PAGE_SIZE: number = 8;

export class SyncRequest {
  protocol: string = SYNC_PROTOCOL;
  version: number = SYNC_VERSION;
  type: string = '';
  requestId: string = '';
  cursor: string = '';
  limit: number = 6;
  recordingId: string = '';
  transferId: string = '';
  sha256: string = '';
  bytes: number = 0;
}

/** Wire metadata deliberately excludes sandbox paths and file descriptors. */
export class RecordingMetadata {
  id: string = '';
  createdAt: number = 0;
  durationMs: number = 0;
  bytes: number = 0;
  sampleRate: number = 16000;
  channels: number = 1;
  bitsPerSample: number = 16;
  mimeType: string = 'audio/wav';
  mode: string = 'manual';
  synced: boolean = false;
}

export class RecordingPage {
  recordings: RecordingMetadata[] = [];
  nextCursor: string = '';
}

export class TransferOffer {
  recording: RecordingMetadata = new RecordingMetadata();
  transferId: string = '';
  sha256: string = '';
  path: string = ''; // Internal only; never serialize this class to the phone.
}

export class SyncResponse {
  protocol: string = SYNC_PROTOCOL;
  version: number = SYNC_VERSION;
  sourceId: string = '';
  requestId: string = '';
  type: string = '';
  code: string = '';
  message: string = '';
  recordings: RecordingMetadata[] = [];
  nextCursor: string = '';
  recording: RecordingMetadata | undefined = undefined;
  recordingId: string = '';
  transferId: string = '';
  sha256: string = '';
  bytes: number = 0;
  phase: string = '';
  progress: number = 0;
}

export class SyncViewState {
  status: string = 'initializing';
  message: string = '正在准备手机连接';
  peerName: string = '';
  currentId: string = '';
  progress: number = 0;
  syncedIds: string[] = [];
}

export class SyncFailure extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export function decodeRequest(text: string): SyncRequest {
  let request: SyncRequest;
  try { request = JSON.parse(text) as SyncRequest; } catch (_) {
    throw new SyncFailure('BAD_REQUEST', '消息不是有效的 JSON');
  }
  if (request === null || typeof request !== 'object' || Array.isArray(request) ||
    request.protocol !== SYNC_PROTOCOL || request.version !== SYNC_VERSION) {
    throw new SyncFailure('UNSUPPORTED_PROTOCOL', '不支持的同步协议版本');
  }
  if (typeof request.requestId !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(request.requestId) ||
    typeof request.type !== 'string') {
    throw new SyncFailure('BAD_REQUEST', '请求标识或类型无效');
  }
  const types: string[] = ['HELLO', 'LIST_RECORDINGS', 'GET_RECORDING', 'READY_RECORDING',
    'ACK_RECORDING', 'CANCEL_TRANSFER', 'GET_STATUS'];
  if (types.indexOf(request.type) < 0) { throw new SyncFailure('BAD_REQUEST', '未知请求类型'); }
  if (request.type === 'LIST_RECORDINGS') {
    if (request.cursor !== undefined && (typeof request.cursor !== 'string' || request.cursor.length > 120)) {
      throw new SyncFailure('BAD_REQUEST', '分页游标无效');
    }
    if (request.limit !== undefined && (!Number.isInteger(request.limit) || request.limit < 1 ||
      request.limit > MAX_PAGE_SIZE)) { throw new SyncFailure('BAD_REQUEST', '每页最多 8 条录音'); }
  }
  if (request.type === 'GET_RECORDING' || request.type === 'ACK_RECORDING') {
    if (typeof request.recordingId !== 'string' || request.recordingId.length > 120) {
      throw new SyncFailure('BAD_REQUEST', '录音标识无效');
    }
  }
  if (request.type === 'READY_RECORDING' || request.type === 'ACK_RECORDING' || request.type === 'CANCEL_TRANSFER') {
    if (typeof request.transferId !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(request.transferId)) {
      throw new SyncFailure('BAD_REQUEST', '传输标识无效');
    }
  }
  if (request.type === 'ACK_RECORDING' && (typeof request.sha256 !== 'string' ||
    !/^[a-fA-F0-9]{64}$/.test(request.sha256) || !Number.isSafeInteger(request.bytes) || request.bytes <= 44)) {
    throw new SyncFailure('BAD_REQUEST', '文件确认信息无效');
  }
  return request;
}

export interface SyncRepository {
  list(peer: string, cursor: string, limit: number): Promise<RecordingPage>;
  prepare(peer: string, id: string): Promise<TransferOffer>;
  confirm(peer: string, request: SyncRequest): Promise<void>;
  confirmedIds(peer: string): Promise<string[]>;
}

export interface SyncTransport {
  send(text: string): Promise<void>;
  transfer(path: string, progress: (value: number) => void): Promise<void>;
  cancel(): Promise<void>;
}
