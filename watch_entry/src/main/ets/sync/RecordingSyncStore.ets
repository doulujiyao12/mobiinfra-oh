import { fileIo as fs, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { parseRecordingName, SEGMENT_SECONDS, WAV_HEADER_BYTES, isOwnWavHeader } from '../core/Wav';
import { RecordingMetadata, RecordingPage, TransferOffer, SyncRequest, SyncFailure, SyncRepository } from './SyncProtocol';

class Receipt {
  peer: string = '';
  id: string = '';
  transferId: string = '';
  sha256: string = '';
  bytes: number = 0;
  receivedAt: number = 0;
}

class PendingTransfer extends Receipt {}

class SyncJournal {
  version: number = 1;
  sourceId: string = '';
  receipts: Receipt[] = [];
  pending: PendingTransfer | undefined = undefined;
}

/** Runs in its own Worker: catalog/hash/journal I/O never block microphone callbacks. */
export class RecordingSyncStore implements SyncRepository {
  private directory: string;
  private journalPath: string;
  private journal: SyncJournal = new SyncJournal();

  constructor(filesDir: string) {
    this.directory = `${filesDir}/recordings`;
    this.journalPath = `${filesDir}/recording-sync.v1.json`;
    if (fs.accessSync(this.journalPath)) {
      try {
        if (fs.statSync(this.journalPath).size > 8 * 1024 * 1024) { throw new Error('同步记录过大'); }
        const loaded: SyncJournal = JSON.parse(fs.readTextSync(this.journalPath)) as SyncJournal;
        if (loaded.version !== 1 || typeof loaded.sourceId !== 'string' ||
          !/^[a-zA-Z0-9-]{16,80}$/.test(loaded.sourceId) || !Array.isArray(loaded.receipts) ||
          loaded.receipts.length > 8000) { throw new Error('同步记录格式错误'); }
        loaded.receipts.forEach((receipt: Receipt) => this.validateReceipt(receipt));
        if (loaded.pending !== undefined) { this.validateReceipt(loaded.pending); }
        this.journal = loaded;
      } catch (_) { throw new SyncFailure('JOURNAL_ERROR', '同步记录损坏，原文件已保留；本地录音不受影响'); }
    } else {
      this.journal.sourceId = util.generateRandomUUID(true);
      this.persist(this.journal);
    }
  }

  sourceId(): string { return this.journal.sourceId; }

  private validateReceipt(receipt: Receipt): void {
    if (receipt === null || typeof receipt.peer !== 'string' || receipt.peer.length > 512 ||
      typeof receipt.id !== 'string' || parseRecordingName(receipt.id) === undefined || receipt.id.endsWith('.part') ||
      typeof receipt.transferId !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(receipt.transferId) ||
      typeof receipt.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(receipt.sha256) ||
      !Number.isSafeInteger(receipt.bytes) || receipt.bytes <= WAV_HEADER_BYTES ||
      !Number.isFinite(receipt.receivedAt)) { throw new Error('无效的同步确认'); }
  }

  private persist(next: SyncJournal): void {
    const temporary: string = `${this.journalPath}.next`;
    const handle: fs.File = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(next));
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const written: number = fs.writeSync(handle.fd, bytes.slice(offset).buffer as ArrayBuffer);
        if (written <= 0) { throw new Error('同步状态写入失败'); }
        offset += written;
      }
      fs.fsyncSync(handle.fd);
    } finally { fs.closeSync(handle.fd); }
    fs.renameSync(temporary, this.journalPath);
    // Commit in memory only after the durable replacement succeeds.
    this.journal = next;
  }

  private path(id: string): string {
    const parsed = parseRecordingName(id);
    if (parsed === undefined || parsed.partial) { throw new SyncFailure('INVALID_RECORDING', '只能同步已完成的录音'); }
    return `${this.directory}/${id}`;
  }

  private metadata(id: string, peer: string): RecordingMetadata {
    const path: string = this.path(id);
    if (!fs.accessSync(path)) { throw new SyncFailure('NOT_FOUND', '录音不存在或已删除'); }
    const parsed = parseRecordingName(id)!;
    const stat: fs.Stat = fs.statSync(path);
    if (!stat.isFile() || stat.size <= WAV_HEADER_BYTES || stat.size > 100 * 1024 * 1024 ||
      (stat.size - WAV_HEADER_BYTES) % 2 !== 0) { throw new SyncFailure('INVALID_RECORDING', '录音文件无效或超过传输上限'); }
    const result: RecordingMetadata = new RecordingMetadata();
    result.id = id;
    result.bytes = stat.size;
    result.sampleRate = parsed.sampleRate;
    result.mode = parsed.mode;
    result.createdAt = parsed.timestamp + (parsed.version === 1 ? (parsed.segment - 1) * SEGMENT_SECONDS * 1000 : 0);
    result.durationMs = (stat.size - WAV_HEADER_BYTES) / (parsed.sampleRate * 2) * 1000;
    result.synced = this.journal.receipts.some((r: Receipt) => r.peer === peer && r.id === id && r.bytes === stat.size);
    return result;
  }

  async list(peer: string, cursor: string, limit: number): Promise<RecordingPage> {
    if (cursor.length > 0) { this.path(cursor); }
    const page: RecordingPage = new RecordingPage();
    if (!fs.accessSync(this.directory)) { return page; }
    const records: RecordingMetadata[] = [];
    fs.listFileSync(this.directory).forEach((id: string) => {
      const parsed = parseRecordingName(id);
      if (parsed === undefined || parsed.partial) { return; }
      try { records.push(this.metadata(id, peer)); } catch (_) { /* Invalid files are never offered. */ }
    });
    records.sort((a: RecordingMetadata, b: RecordingMetadata) => b.createdAt - a.createdAt || b.id.localeCompare(a.id));
    let remaining: RecordingMetadata[] = records;
    if (cursor.length > 0) {
      const key = parseRecordingName(cursor)!;
      const time: number = key.timestamp + (key.version === 1 ? (key.segment - 1) * SEGMENT_SECONDS * 1000 : 0);
      remaining = records.filter((record: RecordingMetadata) => record.createdAt < time ||
        (record.createdAt === time && record.id.localeCompare(cursor) < 0));
    }
    page.recordings = remaining.slice(0, limit);
    page.nextCursor = remaining.length > limit ? page.recordings[page.recordings.length - 1].id : '';
    return page;
  }

  async prepare(peer: string, id: string): Promise<TransferOffer> {
    const recording: RecordingMetadata = this.metadata(id, peer);
    const path: string = this.path(id);
    const handle: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const header: ArrayBuffer = new ArrayBuffer(WAV_HEADER_BYTES);
      if (fs.readSync(handle.fd, header) !== WAV_HEADER_BYTES || !isOwnWavHeader(header, recording.sampleRate) ||
        new DataView(header).getUint32(40, true) !== recording.bytes - WAV_HEADER_BYTES) {
        throw new SyncFailure('INVALID_RECORDING', '录音文件头或长度无效');
      }
    } finally { fs.closeSync(handle.fd); }
    const digest: string = (await hash.hash(path, 'sha256')).toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(digest) || fs.statSync(path).size !== recording.bytes) {
      throw new SyncFailure('FILE_CHANGED', '录音文件在准备期间发生变化');
    }
    const old: PendingTransfer | undefined = this.journal.pending;
    const pending: PendingTransfer = new PendingTransfer();
    pending.peer = peer;
    pending.id = id;
    pending.sha256 = digest;
    pending.bytes = recording.bytes;
    pending.transferId = old !== undefined && old.peer === peer && old.id === id && old.sha256 === digest ?
      old.transferId : util.generateRandomUUID(true);
    pending.receivedAt = 0;
    const next: SyncJournal = new SyncJournal();
    next.sourceId = this.journal.sourceId;
    next.receipts = this.journal.receipts.slice();
    next.pending = pending;
    this.persist(next);
    const offer: TransferOffer = new TransferOffer();
    offer.recording = recording;
    offer.transferId = pending.transferId;
    offer.sha256 = digest;
    offer.path = path;
    return offer;
  }

  async confirm(peer: string, request: SyncRequest): Promise<void> {
    this.path(request.recordingId);
    const digest: string = request.sha256.toLowerCase();
    const previous: Receipt | undefined = this.journal.receipts.find((r: Receipt) => r.peer === peer &&
      r.id === request.recordingId && r.transferId === request.transferId && r.sha256 === digest && r.bytes === request.bytes);
    if (previous !== undefined) { return; } // Duplicate ACK after a lost response is idempotent.
    const pending: PendingTransfer | undefined = this.journal.pending;
    if (pending === undefined || pending.peer !== peer || pending.id !== request.recordingId ||
      pending.transferId !== request.transferId || pending.sha256 !== digest || pending.bytes !== request.bytes) {
      throw new SyncFailure('ACK_MISMATCH', '确认与待同步文件不匹配，请重新获取录音');
    }
    const recording: RecordingMetadata = this.metadata(request.recordingId, peer);
    if (recording.bytes !== request.bytes) { throw new SyncFailure('FILE_CHANGED', '录音文件已变化'); }
    const receipt: Receipt = new Receipt();
    receipt.peer = peer;
    receipt.id = pending.id;
    receipt.transferId = pending.transferId;
    receipt.sha256 = digest;
    receipt.bytes = pending.bytes;
    receipt.receivedAt = Date.now();
    const next: SyncJournal = new SyncJournal();
    next.sourceId = this.journal.sourceId;
    // Bound the journal. Evicted receipts only affect status; audio is never removed.
    next.receipts = this.journal.receipts.filter((r: Receipt) => !(r.peer === peer && r.id === receipt.id));
    next.receipts.push(receipt);
    next.receipts = next.receipts.slice(-8000);
    this.persist(next);
  }

  async confirmedIds(peer: string): Promise<string[]> {
    const ids: Set<string> = new Set(fs.accessSync(this.directory) ? fs.listFileSync(this.directory) : []);
    return this.journal.receipts.filter((r: Receipt) => r.peer === peer && ids.has(r.id)).map((r: Receipt) => r.id);
  }
}
