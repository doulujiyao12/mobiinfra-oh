import { decodeRequest, SyncFailure, SyncRepository, SyncRequest,
  SyncResponse, SyncTransport, SyncViewState, TransferOffer } from './SyncProtocol';

type StateListener = (state: SyncViewState) => void;

/** App-level reliability: transport success alone never marks a recording as synced. */
export class RecordingSyncEngine {
  private repository: SyncRepository;
  private transport: SyncTransport;
  private sourceId: string;
  private peer: string;
  private listener: StateListener;
  private view: SyncViewState = new SyncViewState();
  private offer: TransferOffer | undefined = undefined;
  private phase: string = '';
  private deadline: number = 0;
  private generation: number = 0;
  private connected: boolean = true;
  private commands: Promise<void> = Promise.resolve();
  private queued: number = 0;
  private handshaken: boolean = false;

  constructor(repository: SyncRepository, transport: SyncTransport, sourceId: string, peer: string, listener: StateListener) {
    this.repository = repository;
    this.transport = transport;
    this.sourceId = sourceId;
    this.peer = peer;
    this.listener = listener;
    this.view.status = 'waiting';
    this.view.message = '等待手机 App 发起同步';
    this.emit();
  }

  private emit(): void {
    const snapshot: SyncViewState = new SyncViewState();
    snapshot.status = this.view.status;
    snapshot.message = this.view.message;
    snapshot.currentId = this.view.currentId;
    snapshot.progress = this.view.progress;
    snapshot.syncedIds = this.view.syncedIds.slice();
    this.listener(snapshot);
  }

  async initialize(): Promise<void> {
    this.view.syncedIds = await this.repository.confirmedIds(this.peer);
    this.emit();
  }

  receive(text: string): Promise<void> {
    if (!this.connected) { return Promise.resolve(); }
    if (this.queued >= 32) { return Promise.resolve(); }
    this.queued++;
    const task: Promise<void> = this.commands.then(async () => {
      if (!this.connected) { return; }
      let request: SyncRequest | undefined = undefined;
      try {
        request = decodeRequest(text);
        await this.dispatch(request);
      } catch (error) {
        const failure: SyncFailure = error as SyncFailure;
        const response: SyncResponse = this.response(request?.requestId || '', 'ERROR');
        response.code = failure.code || 'INTERNAL_ERROR';
        response.message = failure.message || '同步请求失败';
        try { await this.send(response); } catch (_) { /* Connection recovery retries the request. */ }
      }
    });
    this.commands = task.catch(() => {}).then(() => { this.queued--; });
    return this.commands;
  }

  private response(requestId: string, type: string): SyncResponse {
    const response: SyncResponse = new SyncResponse();
    response.sourceId = this.sourceId;
    response.requestId = requestId;
    response.type = type;
    return response;
  }

  private async send(response: SyncResponse): Promise<void> {
    if (this.connected) { await this.transport.send(JSON.stringify(response)); }
  }

  private offerResponse(requestId: string): SyncResponse {
    const response: SyncResponse = this.response(requestId, 'RECORDING_OFFER');
    response.recording = this.offer!.recording;
    response.recordingId = this.offer!.recording.id;
    response.transferId = this.offer!.transferId;
    response.sha256 = this.offer!.sha256;
    response.bytes = this.offer!.recording.bytes;
    return response;
  }

  private async dispatch(request: SyncRequest): Promise<void> {
    if (request.type !== 'HELLO' && !this.handshaken) { throw new SyncFailure('HELLO_REQUIRED', '请先完成同步握手'); }
    if (request.type === 'HELLO') {
      this.handshaken = true;
      if (this.offer === undefined) {
        this.view.status = 'connected';
        this.view.message = '手机已连接，可以同步录音';
        this.emit();
      }
      const response: SyncResponse = this.response(request.requestId, 'HELLO_RESULT');
      response.message = 'LIST_RECORDINGS,GET_RECORDING,READY_RECORDING,ACK_RECORDING,CANCEL_TRANSFER,GET_STATUS';
      await this.send(response);
    } else if (request.type === 'LIST_RECORDINGS') {
      const page = await this.repository.list(this.peer, request.cursor || '', request.limit || 6);
      const response: SyncResponse = this.response(request.requestId, 'RECORDINGS_LIST');
      response.recordings = page.recordings;
      response.nextCursor = page.nextCursor;
      await this.send(response);
    } else if (request.type === 'GET_RECORDING') {
      if (this.offer !== undefined) {
        if (this.offer.recording.id !== request.recordingId || this.phase !== 'offered') {
          throw new SyncFailure('BUSY', '已有录音正在同步，请先完成或取消');
        }
      } else {
        this.view.currentId = request.recordingId;
        this.view.status = 'preparing';
        this.view.message = '正在校验录音';
        this.emit();
        try { this.offer = await this.repository.prepare(this.peer, request.recordingId); } catch (error) {
          this.idle('文件准备失败，请在手机重试');
          throw error;
        }
        this.phase = 'offered';
        this.deadline = Date.now() + 60000;
      }
      await this.send(this.offerResponse(request.requestId));
    } else if (request.type === 'READY_RECORDING') {
      this.requireTransfer(request.transferId);
      if (this.phase === 'offered') {
        this.phase = 'sending';
        this.deadline = Date.now() + 180000;
        this.view.status = 'transferring';
        this.view.progress = 0;
        this.view.message = '正在发送录音';
        this.emit();
        const response: SyncResponse = this.statusResponse(request.requestId);
        try { await this.send(response); } catch (error) {
          this.phase = 'offered';
          this.deadline = Date.now() + 60000;
          throw error;
        }
        // Do not block the command queue: ACK/cancel may arrive before SDK completion.
        this.beginTransfer().catch(() => {});
      } else { await this.send(this.statusResponse(request.requestId)); }
    } else if (request.type === 'ACK_RECORDING') {
      // May also acknowledge an identical file already durably held by the phone.
      await this.repository.confirm(this.peer, request);
      if (this.offer?.transferId === request.transferId) {
        this.generation++;
        await this.transport.cancel(); // No-op after transfer; releases any late SDK callback safely.
        this.offer = undefined;
        this.phase = '';
      }
      this.view.syncedIds = await this.repository.confirmedIds(this.peer);
      if (this.offer === undefined) { this.idle('手机已确认接收，手表原文件已保留'); }
      const response: SyncResponse = this.response(request.requestId, 'RECORDING_ACKED');
      response.recordingId = request.recordingId;
      response.transferId = request.transferId;
      await this.send(response);
    } else if (request.type === 'CANCEL_TRANSFER') {
      this.requireTransfer(request.transferId);
      this.generation++;
      await this.transport.cancel();
      this.offer = undefined;
      this.phase = '';
      this.idle('同步已取消，录音仍保留在手表');
      await this.send(this.response(request.requestId, 'TRANSFER_CANCELLED'));
    } else if (request.type === 'GET_STATUS') {
      await this.send(this.statusResponse(request.requestId));
    }
  }

  private requireTransfer(id: string): void {
    if (this.offer === undefined || this.offer.transferId !== id) {
      throw new SyncFailure('UNKNOWN_TRANSFER', '传输已结束，请重新请求录音');
    }
  }

  private statusResponse(requestId: string): SyncResponse {
    const response: SyncResponse = this.response(requestId, 'TRANSFER_STATE');
    response.transferId = this.offer?.transferId || '';
    response.recordingId = this.offer?.recording.id || '';
    response.phase = this.phase || 'idle';
    response.progress = this.view.progress;
    return response;
  }

  private async beginTransfer(): Promise<void> {
    const generation: number = ++this.generation;
    const offer: TransferOffer = this.offer!;
    try {
      await this.transport.transfer(offer.path, (progress: number): void => {
        if (generation !== this.generation || !this.connected) { return; }
        this.view.progress = Math.min(100, Math.max(0, progress));
        this.deadline = Date.now() + 180000;
        this.emit();
      });
      if (generation !== this.generation || !this.connected) { return; }
      this.phase = 'awaiting_ack';
      this.deadline = Date.now() + 60000;
      this.view.status = 'awaiting_ack';
      this.view.progress = 100;
      this.view.message = '发送完成，等待手机校验确认';
      this.emit();
      await this.send(this.statusResponse(''));
    } catch (error) {
      if (generation !== this.generation || !this.connected) { return; }
      this.offer = undefined;
      this.phase = '';
      this.idle('发送未完成，可在手机重新请求；原文件已保留');
      const response: SyncResponse = this.response('', 'ERROR');
      response.code = 'TRANSFER_FAILED';
      response.transferId = offer.transferId;
      response.recordingId = offer.recording.id;
      response.message = (error as Error).message || '文件传输失败';
      try { await this.send(response); } catch (_) {}
    }
  }

  private idle(message: string): void {
    this.deadline = 0;
    this.view.currentId = '';
    this.view.progress = 0;
    this.view.status = 'connected';
    this.view.message = message;
    this.emit();
  }

  async tick(now: number): Promise<void> {
    const operation: Promise<void> = this.commands.then(() => this.expire(now));
    this.commands = operation.catch(() => {});
    await operation;
  }

  private async expire(now: number): Promise<void> {
    if (this.offer === undefined || this.deadline === 0 || now < this.deadline) { return; }
    this.generation++;
    const id: string = this.offer.transferId;
    this.offer = undefined;
    this.phase = '';
    await this.transport.cancel();
    this.idle('同步等待超时，可在手机重试；原文件已保留');
    const response: SyncResponse = this.response('', 'ERROR');
    response.code = 'TRANSFER_TIMEOUT';
    response.transferId = id;
    try { await this.send(response); } catch (_) {}
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    this.generation++;
    await this.transport.cancel();
    this.offer = undefined;
  }
}
