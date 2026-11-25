import { common } from '@kit.AbilityKit';
import { wearEngine } from '@kit.WearEngine';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { createAudioCodecJob } from 'libwatchaudio.so';
import type { AudioCodecJob } from '../cpp/types/libwatchaudio/index';
import { BusinessError, zlib } from '@kit.BasicServicesKit';

// Match the phone recording library's bounded WAV limit. One watch recording
// can now span a whole session rather than a five-minute file.
const MAX_RECORDING_BYTES: number = 2 * 1024 * 1024 * 1024 - 1;

const PROTOCOL: string = 'clawmate.recordings';
export function watchConnectionMessage(error: BusinessError): string {
  if (error.code === 1008500004) { return '当前手机应用尚未开通 Wear Engine 服务，请在华为开发者平台开通后重试。'; }
  if (error.code === 1008500002 || error.code === 1008500003) { return '手表尚未连接，请先在运动健康中配对并保持连接。'; }
  if (error.code === 1008500005 || error.code === 1008500006) { return '请先在运动健康中完成穿戴设备的授权，再重新连接。'; }
  if (error.code === 1008500008 || error.code === 1008500009) { return '请先登录华为账号，再重新连接手表。'; }
  return (error.message || '手表连接未完成，请重试') + (error.code ? ' (' + error.code + ')' : '');
}

function withTimeout<T>(operation: Promise<T>, milliseconds: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer: number = setTimeout(() => reject(new Error('Wear Engine 响应超时，请检查连接')), milliseconds);
    operation.then((value: T) => { clearTimeout(timer); resolve(value); },
      (error: Error) => { clearTimeout(timer); reject(error); });
  });
}

export class WatchRecording {
  id: string = '';
  createdAt: number = 0;
  durationMs: number = 0;
  bytes: number = 0;
  sampleRate: number = 16000;
  channels: number = 1;
  bitsPerSample: number = 16;
  mimeType: string = 'audio/wav';
  mode: string = '';
  synced: boolean = false;
}
export class WatchRecordingPage {
  recordings: WatchRecording[] = [];
  nextCursor: string = '';
}
export class DownloadedRecording {
  sourceId: string = '';
  recording: WatchRecording = new WatchRecording();
  path: string = '';
}
class AudioReceipt {
  sourceBytes: number = 0;
  audioBytes: number = 0;
}
class Message {
  acceptAac?: boolean;
  acceptGzip?: boolean;
  skipSha256?: boolean;
  progress?: number;
  phase?: string;
  protocol: string = PROTOCOL;
  version: number = 1;
  type: string = '';
  requestId: string = '';
  sourceId: string = '';
  cursor: string = '';
  limit: number = 6;
  recordingId: string = '';
  transferId: string = '';
  sha256: string = '';
  bytes: number = 0;
  recordings: WatchRecording[] = [];
  nextCursor: string = '';
  recording: WatchRecording = new WatchRecording();
  message: string = '';
  code: string = '';
}
class PendingReply {
  resolve: (message: Message) => void = (_message: Message): void => {};
  reject: (error: Error) => void = (_error: Error): void => {};
}
class IncomingFile {
  offer: Message;
  resolve: (path: string) => void;
  reject: (error: Error) => void;
  timer: number = -1;
  handling: boolean = false;
  lastProgress: number = -1;
  compressing: boolean = false;
  onProgress?: (percent: number, compressing?: boolean, restoring?: boolean) => void;
  constructor(offer: Message, resolve: (path: string) => void, reject: (error: Error) => void) {
    this.offer = offer; this.resolve = resolve; this.reject = reject;
  }
}

/** Companion integration only: no UI, no cloud upload, no deletion of watch files. */
export class WatchRecordingClient {
  static async devices(context: common.UIAbilityContext): Promise<wearEngine.Device[]> {
    if (!canIUse('SystemCapability.Health.WearEngine')) { throw new Error('当前设备不支持 Wear Engine 手表连接'); }
    const devices = await withTimeout(wearEngine.getDeviceClient(context).getConnectedDevices(), 15000);
    return devices.filter((device: wearEngine.Device): boolean => device.category === wearEngine.DeviceCategory.WATCH);
  }
  peerName: string = '';
  private context: common.UIAbilityContext;
  private peer: wearEngine.P2pAppParam;
  private client: wearEngine.P2pClient;
  private deviceId: string = '';
  private sourceId: string = '';
  private pending: Map<string, PendingReply> = new Map();
  private incoming: IncomingFile | undefined = undefined;
  private downloading: boolean = false;
  private aacEnabled: boolean = true;
  private decoding: AudioCodecJob | undefined = undefined;
  private registeredMessage: boolean = false;
  private registeredFile: boolean = false;
  private generation: number = 0;
  private ensureActive(generation: number): void {
    if (generation !== this.generation) { throw new Error('手表连接已取消'); }
  }
  private messageReceiver = (message: wearEngine.P2pMessage): void => {
    if (message.content.byteLength > 4096) { return; }
    try {
      const response: Message = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true })
        .decodeToString(message.content)) as Message;
      if (response === null || response.protocol !== PROTOCOL || response.version !== 1 ||
        typeof response.sourceId !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(response.sourceId) ||
        (this.sourceId.length > 0 && response.sourceId !== this.sourceId)) { return; }
      const incoming = this.incoming;
      if (response.type === 'TRANSFER_STATE' && incoming !== undefined && !incoming.handling &&
        response.transferId === incoming.offer.transferId) {
        if (response.phase === 'compressing') {
          if (incoming.lastProgress < 0 && typeof response.progress === 'number' && Number.isFinite(response.progress)) {
            incoming.compressing = true;
            incoming.onProgress?.(Math.max(0, Math.min(99, Math.floor(response.progress))), true);
          }
        } else if (response.phase !== 'preparing' && typeof response.progress === 'number' &&
          Number.isFinite(response.progress)) {
          const percent = Math.min(99, Math.floor(response.progress));
          if (percent > incoming.lastProgress) { incoming.lastProgress = percent; incoming.onProgress?.(percent); }
        }
      }
      const pending: PendingReply | undefined = this.pending.get(response.requestId);
      if (pending !== undefined) {
        if (response.type === 'ERROR') { pending.reject(new Error(`${response.code}: ${response.message}`)); }
        else { pending.resolve(response); }
      } else if (response.type === 'ERROR' && response.transferId === this.incoming?.offer.transferId) {
        this.incoming?.reject(new Error(response.message || response.code));
      }
    } catch (_) { /* Ignore malformed or unrelated messages. */ }
  };
  private fileReceiver = (file: wearEngine.P2pFile): void => {
    const incoming: IncomingFile | undefined = this.incoming;
    if (incoming === undefined || incoming.handling) { try { fs.closeSync(file.file.fd); } catch (_) {} return; }
    incoming.handling = true;
    incoming.onProgress?.(100);
    this.saveReceivedFile(file, incoming.offer).then((path: string) => incoming.resolve(path))
      .catch((error: Error) => incoming.reject(error)).finally(() => {
        try { fs.closeSync(file.file.fd); } catch (_) {}
      });
  };

  constructor(context: common.UIAbilityContext, watchAppId: string = '6917613102135452205', watchBundleName: string = 'com.coevomind.clawmate') {
    if (!/^[0-9]+$/.test(watchAppId)) { throw new Error('请填写手表应用的 AGC APP ID'); }
    this.context = context;
    this.peer = { remoteApp: { bundleName: watchBundleName, fingerprint: watchAppId } };
    this.client = wearEngine.getP2pClient(context);
  }

  async connect(deviceId: string = ''): Promise<void> {
    await this.close();
    const generation = this.generation;
    const devices: wearEngine.Device[] = await withTimeout(wearEngine.getDeviceClient(this.context).getConnectedDevices(), 15000);
    this.ensureActive(generation);
    const watches: wearEngine.Device[] = devices.filter((device: wearEngine.Device) =>
      (deviceId.length > 0 ? device.randomId === deviceId : device.category === wearEngine.DeviceCategory.WATCH));
    if (watches.length !== 1) { throw new Error('请指定一块已连接的手表'); }
    this.deviceId = watches[0].randomId;
    this.peerName = watches[0].name || '我的手表';
    try {
      if (!await this.client.isRemoteAppInstalled(this.deviceId, this.peer.remoteApp.bundleName)) {
        throw new Error('手表尚未安装 ClawMate');
      }
      this.ensureActive(generation);
      // Register both receivers before the watch can send any response/file.
      const receiverDevice = this.deviceId;
      const messageRegistration = this.client.registerMessageReceiver(receiverDevice, this.peer, this.messageReceiver);
      const messagesReady = messageRegistration.then((): void => {
        if (generation === this.generation) { this.registeredMessage = true; }
        else { this.client.unregisterMessageReceiver(receiverDevice, this.peer, this.messageReceiver).catch((): void => {}); }
      });
      const fileRegistration = this.client.registerFileReceiver(receiverDevice, this.peer, this.fileReceiver);
      const filesReady = fileRegistration.then((): void => {
        if (generation === this.generation) { this.registeredFile = true; }
        else { this.client.unregisterFileReceiver(receiverDevice, this.peer, this.fileReceiver).catch((): void => {}); }
      });
      await withTimeout(Promise.all([messagesReady, filesReady]), 15000);
      this.ensureActive(generation);
      const started: wearEngine.P2pResult = await withTimeout(
        this.client.startRemoteApp(this.deviceId, this.peer.remoteApp.bundleName), 20000);
      this.ensureActive(generation);
      if (started.code !== 207 && started.code !== 202) { throw new Error(`手表应用启动失败 (${started.code})`); }
      const response: Message = await this.request('HELLO', new Message());
      this.ensureActive(generation);
      if (response.type !== 'HELLO_RESULT') { throw new Error('手表握手响应无效'); }
      this.sourceId = response.sourceId;
    } catch (error) {
      if (generation === this.generation) { await this.close(); }
      throw new Error(watchConnectionMessage(error as BusinessError));
    }
  }

  identity(): string { return this.sourceId; }

  private async request(type: string, body: Message): Promise<Message> {
    if (this.deviceId.length === 0) { throw new Error('请先连接手表'); }
    const generation = this.generation;
    body.type = type;
    body.requestId = util.generateRandomUUID(true);
    const content: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(body));
    if (content.byteLength > 4096) { throw new Error('同步请求过大'); }
    let lastError: Error = new Error('手表响应超时');
    // Retries retain the requestId; GET/READY/ACK are designed to be idempotent.
    for (let attempt: number = 0; attempt < 3; attempt++) {
      this.ensureActive(generation);
      let timer: number = -1;
      const response: Promise<Message> = new Promise<Message>((resolve, reject) => {
        const pending: PendingReply = new PendingReply();
        pending.resolve = resolve; pending.reject = reject;
        this.pending.set(body.requestId, pending);
        timer = setTimeout(() => reject(new Error('手表响应超时，请检查连接')), 15000);
      });
      // Install a rejection handler immediately, even while native sendMessage is awaiting.
      const guarded: Promise<Message> = response.then((message: Message) => message);
      guarded.catch(() => {});
      try {
        const sent: wearEngine.P2pResult = await withTimeout(this.client.sendMessage(this.deviceId, this.peer, { content }), 15000);
        if (sent.code !== 207) { throw new Error(`手表消息发送失败 (${sent.code})`); }
        return await guarded;
      } catch (error) { lastError = new Error(watchConnectionMessage(error as BusinessError)); }
      finally { clearTimeout(timer); this.pending.delete(body.requestId); }
    }
    throw lastError;
  }

  async list(cursor: string = ''): Promise<WatchRecordingPage> {
    const body: Message = new Message(); body.cursor = cursor;
    const response: Message = await this.request('LIST_RECORDINGS', body);
    if (response.type !== 'RECORDINGS_LIST' || !Array.isArray(response.recordings) || response.recordings.length > 8 ||
      typeof response.nextCursor !== 'string' || response.nextCursor.length > 120) {
      throw new Error('手表录音列表无效');
    }
    const page: WatchRecordingPage = new WatchRecordingPage();
    page.recordings = response.recordings;
    page.nextCursor = response.nextCursor;
    return page;
  }

  async syncAll(onSaved: (recording: DownloadedRecording) => void): Promise<void> {
    let cursor: string = '';
    do {
      const page: WatchRecordingPage = await this.list(cursor);
      for (let i: number = 0; i < page.recordings.length; i++) {
        // Never trust the watch's synced flag alone: phone app data may have been cleared.
        onSaved(await this.download(page.recordings[i].id));
      }
      if (page.nextCursor.length > 0 && page.nextCursor === cursor) { throw new Error('分页游标未前进'); }
      cursor = page.nextCursor;
    } while (cursor.length > 0);
  }

  async download(recordingId: string, existingPath: string = '',
    onProgress?: (percent: number, compressing?: boolean, restoring?: boolean) => void): Promise<DownloadedRecording> {
    const generation = this.generation;
    const aacEnabled = this.aacEnabled;
    try { return await this.downloadOnce(recordingId, existingPath, onProgress); }
    catch (error) {
      this.ensureActive(generation);
      if (aacEnabled && !this.aacEnabled) { return this.downloadOnce(recordingId, existingPath, onProgress); }
      throw error as Error;
    }
  }

  private async downloadOnce(recordingId: string, existingPath: string,
    onProgress?: (percent: number, compressing?: boolean, restoring?: boolean) => void): Promise<DownloadedRecording> {
    if (this.downloading || this.sourceId.length === 0) { throw new Error('请先连接手表，且一次只下载一个录音'); }
    this.downloading = true;
    let offer: Message | undefined = undefined;
    try {
      const body: Message = new Message(); body.recordingId = recordingId;
      body.skipSha256 = true;
      offer = await this.request('GET_RECORDING', body);
      if (offer.type !== 'RECORDING_OFFER' || offer.recordingId !== recordingId ||
        !Number.isSafeInteger(offer.bytes) || offer.bytes <= 44 ||
        offer.bytes > MAX_RECORDING_BYTES || offer.recording.id !== recordingId || offer.recording.bytes !== offer.bytes) {
        throw new Error('手表文件信息无效');
      }
      let destination: string = this.destination(recordingId);
      // An earlier download may have been moved into the managed recording library.
      const receiptPath = this.destination(recordingId) + '.audio.json';
      if (existingPath && this.matchesSize(existingPath, offer.bytes, receiptPath)) {
        destination = existingPath;
      } else if (!this.matchesSize(destination, offer.bytes, receiptPath)) {
        const expected: Message = offer;
        const received: Promise<string> = new Promise<string>((resolve, reject) => {
          const incoming: IncomingFile = new IncomingFile(expected, resolve, reject);
          incoming.onProgress = onProgress;
          incoming.timer = setTimeout(() => reject(new Error('录音接收超时，请重试')), 30 * 60 * 1000);
          this.incoming = incoming;
        });
        received.catch(() => {});
        const ready: Message = new Message(); ready.transferId = offer.transferId;
        ready.acceptGzip = canIUse('SystemCapability.BundleManager.Zlib');
        ready.acceptAac = this.aacEnabled && canIUse('SystemCapability.Multimedia.Media.AudioCodec');
        await this.request('READY_RECORDING', ready);
        await received;
      }
      const confirmation: Message = new Message();
      confirmation.recordingId = recordingId; confirmation.transferId = offer.transferId;
      // Older watches still require their offer digest to be echoed in the receipt.
      confirmation.sha256 = offer.sha256 || '';
      confirmation.bytes = offer.bytes;
      const acknowledged: Message = await this.request('ACK_RECORDING', confirmation);
      if (acknowledged.type !== 'RECORDING_ACKED') { throw new Error('手表未确认同步状态'); }
      const result: DownloadedRecording = new DownloadedRecording();
      result.sourceId = this.sourceId; result.recording = offer.recording;
      result.path = destination;
      return result;
    } catch (error) {
      if (offer?.transferId) {
        const cancel: Message = new Message(); cancel.transferId = offer.transferId;
        try { await this.request('CANCEL_TRANSFER', cancel); } catch (_) {}
      }
      throw new Error((error as Error).message);
    } finally {
      if (this.incoming !== undefined) { clearTimeout(this.incoming.timer); }
      this.incoming = undefined; this.downloading = false;
    }
  }

  private destination(id: string): string {
    if (!/^cm2_\d{13}_\d{4,6}_(16000|48000)_(sound|speech)\.wav$/.test(id) &&
      !/^cm_\d{13}_\d{3}_(16000|48000)\.wav$/.test(id)) { throw new Error('无效的录音标识'); }
    const root: string = `${this.context.filesDir}/watch-recordings`;
    if (!fs.accessSync(root)) { fs.mkdirSync(root); }
    const directory: string = `${root}/${this.sourceId}`;
    if (!fs.accessSync(directory)) { fs.mkdirSync(directory); }
    return `${directory}/${id}`;
  }

  private matchesSize(path: string, bytes: number, receiptPath: string = ''): boolean {
    if (!fs.accessSync(path)) { return false; }
    const stat = fs.statSync(path);
    if (!stat.isFile()) { return false; }
    if (stat.size === bytes) { return true; }
    try {
      const receipt = ArkJSON.parse(fs.readTextSync(receiptPath)) as AudioReceipt;
      return receipt.sourceBytes === bytes && receipt.audioBytes === stat.size &&
        stat.size > bytes && stat.size <= bytes + 8192;
    } catch (_) { return false; }
  }

  private async restoreAac(source: string, path: string, offer: Message, generation: number): Promise<number> {
    const job: AudioCodecJob = createAudioCodecJob();
    this.decoding = job;
    const timer = setInterval((): void => {
      if (generation !== this.generation || this.incoming?.offer !== offer) { job.cancel(); }
      else { this.incoming?.onProgress?.(job.progress(), false, true); }
    }, 300);
    try {
      this.incoming?.onProgress?.(0, false, true);
      const bytes: number = await job.run(source, path, true, offer.recording.sampleRate, offer.bytes);
      this.ensureActive(generation);
      if (this.incoming?.offer !== offer) { throw new Error('录音接收已结束'); }
      return bytes;
    } catch (error) {
      this.ensureActive(generation);
      if (this.incoming?.offer !== offer) { throw new Error('录音接收已结束'); }
      this.aacEnabled = false;
      throw error as Error;
    } finally {
      clearInterval(timer);
      if (this.decoding === job) { this.decoding = undefined; }
    }
  }

  private async restoreGzip(source: string, path: string, offer: Message, generation: number): Promise<void> {
    const gzip = await zlib.createGZip();
    await gzip.gzopen(source, 'rb');
    try {
      const output = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(128 * 1024);
        let total = 0;
        while (true) {
          this.ensureActive(generation);
          if (this.incoming?.offer !== offer) { throw new Error('录音接收已结束'); }
          const size = await gzip.gzread(buffer);
          if (size === 0) { break; }
          total += size;
          if (size < 0 || total > offer.bytes) { throw new Error('压缩录音大小异常'); }
          let offset = 0;
          while (offset < size) {
            const written = fs.writeSync(output.fd, buffer.slice(offset, size));
            if (written <= 0) { throw new Error('保存录音失败'); }
            offset += written;
          }
        }
      } finally { fs.closeSync(output.fd); }
    } finally { await gzip.gzclose(); }
  }

  private async saveReceivedFile(file: wearEngine.P2pFile, offer: Message): Promise<string> {
    const path: string = this.destination(offer.recordingId);
    const generation = this.generation;
    const temporary = path + '.' + util.generateRandomUUID(true) + '.part';
    try {
      const size = fs.statSync(file.file.fd).size;
      if (size <= 0 || size > MAX_RECORDING_BYTES) { throw new Error('录音大小异常'); }
      await fs.copyFile(file.file.fd, temporary + '.wire');
      const header = new Uint8Array(8);
      const wire = fs.openSync(temporary + '.wire', fs.OpenMode.READ_ONLY);
      try { fs.readSync(wire.fd, header.buffer); } finally { fs.closeSync(wire.fd); }
      const aac = header[0] === 255 && (header[1] & 0xF6) === 0xF0;
      let audioBytes = offer.bytes;
      if (aac) {
        audioBytes = await this.restoreAac(temporary + '.wire', temporary, offer, generation);
      } else if (size === offer.bytes && header[0] === 82 && header[1] === 73) {
        fs.renameSync(temporary + '.wire', temporary);
      } else if (size < offer.bytes && header[0] === 31 && header[1] === 139 &&
        canIUse('SystemCapability.BundleManager.Zlib')) {
        await this.restoreGzip(temporary + '.wire', temporary, offer, generation);
      } else { throw new Error('录音大小与手表记录不符'); }
      if (fs.statSync(temporary).size !== audioBytes) { throw new Error('录音大小与手表记录不符'); }
      this.ensureActive(generation);
      if (this.incoming?.offer !== offer) { throw new Error('录音接收已结束'); }
      const handle = fs.openSync(temporary, fs.OpenMode.READ_WRITE);
      try { fs.fsyncSync(handle.fd); } finally { fs.closeSync(handle.fd); }
      fs.renameSync(temporary, path);
      if (aac) {
        const receipt = new AudioReceipt();
        receipt.sourceBytes = offer.bytes; receipt.audioBytes = audioBytes;
        const descriptor = fs.openSync(path + '.audio.json', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          const content = new util.TextEncoder().encodeInto(ArkJSON.stringify(receipt));
          let offset = 0;
          while (offset < content.byteLength) {
            const size = fs.writeSync(descriptor.fd, content.slice(offset).buffer as ArrayBuffer);
            if (size <= 0) { throw new Error('保存录音信息失败'); }
            offset += size;
          }
        } finally { fs.closeSync(descriptor.fd); }
      }
      return path;
    } finally {
      if (fs.accessSync(temporary + '.wire')) { fs.unlinkSync(temporary + '.wire'); }
      if (fs.accessSync(temporary)) { fs.unlinkSync(temporary); }
    }
  }

  async close(): Promise<void> {
    this.generation++;
    this.decoding?.cancel();
    const deviceId = this.deviceId;
    const registeredFile = this.registeredFile; const registeredMessage = this.registeredMessage;
    this.registeredFile = false; this.registeredMessage = false;
    this.deviceId = ''; this.sourceId = ''; this.peerName = '';
    if (this.incoming !== undefined) { clearTimeout(this.incoming.timer); this.incoming.reject(new Error('连接已关闭')); }
    this.incoming = undefined;
    this.pending.forEach((pending: PendingReply) => pending.reject(new Error('连接已关闭')));
    this.pending.clear();
    if (registeredFile) {
      try { await withTimeout(this.client.unregisterFileReceiver(deviceId, this.peer, this.fileReceiver), 5000); } catch (_) {}
    }
    if (registeredMessage) {
      try { await withTimeout(this.client.unregisterMessageReceiver(deviceId, this.peer, this.messageReceiver), 5000); } catch (_) {}
    }
  }
}
