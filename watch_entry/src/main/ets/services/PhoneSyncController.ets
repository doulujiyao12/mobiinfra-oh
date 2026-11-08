import { common } from '@kit.AbilityKit';
import { wearEngine } from '@kit.WearEngine';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PHONE_APP_ID, PHONE_BUNDLE_NAME } from '../config/PhonePeer';
import { MAX_MESSAGE_BYTES, SyncViewState } from '../sync/SyncProtocol';
import { RecordingSyncEngine } from '../sync/RecordingSyncEngine';
import { SyncStoreClient } from './SyncStoreClient';
import { WearEngineTransport } from './WearEngineTransport';
import { backgroundTasks } from './BackgroundTasks';
import { withTimeout } from '../core/Async';

type SyncListener = (state: SyncViewState) => void;

class PhoneSyncController {
  private context: common.UIAbilityContext | undefined = undefined;
  private store: SyncStoreClient | undefined = undefined;
  private client: wearEngine.P2pClient | undefined = undefined;
  private device: wearEngine.Device | undefined = undefined;
  private transport: WearEngineTransport | undefined = undefined;
  private engine: RecordingSyncEngine | undefined = undefined;
  private peer: wearEngine.P2pAppParam = { remoteApp: { bundleName: PHONE_BUNDLE_NAME, fingerprint: PHONE_APP_ID } };
  private sourceId: string = '';
  private view: SyncViewState = new SyncViewState();
  private listener: SyncListener | undefined = undefined;
  private connecting: boolean = false;
  private closing: boolean = false;
  private generation: number = 0;
  private poll: number = -1;
  private nextRetry: number = 0;
  private retryDelay: number = 5000;
  private serviceSubscribed: boolean = false;
  private receiverRegistered: boolean = false;
  private receiver: ((message: wearEngine.P2pMessage) => void) | undefined = undefined;
  private checking: boolean = false;
  private lastCheck: number = 0;
  private receive(message: wearEngine.P2pMessage, engine: RecordingSyncEngine): void {
    if (message.content.byteLength > MAX_MESSAGE_BYTES) { return; }
    try {
      const text: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(message.content);
      engine.receive(text).catch(() => {});
    } catch (_) { /* Invalid UTF-8 cannot be a protocol request. */ }
  }
  private serviceDied = (): void => { this.disconnect('手机连接已断开，等待重连').catch(() => {}); };
  private taskCancelled = (): void => { this.disconnect('后台传输已被系统取消，可重新连接').catch(() => {}); };

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
    this.closing = false;
    backgroundTasks.initialize(context);
    backgroundTasks.onCancel(this.taskCancelled);
    if (!canIUse('SystemCapability.Health.WearEngine')) {
      this.update('unsupported', '当前设备不支持手机连接'); return;
    }
    this.store = new SyncStoreClient();
    this.store.initialize(context.filesDir).then((sourceId: string) => {
      if (this.closing) { return; }
      this.sourceId = sourceId;
      this.connect().catch(() => {});
      this.poll = setInterval(() => {
        if (this.closing) { return; }
        this.engine?.tick(Date.now()).catch(() => {});
        if (this.engine === undefined && Date.now() >= this.nextRetry) { this.connect().catch(() => {}); }
        if (this.engine !== undefined && Date.now() - this.lastCheck >= 15000) { this.checkConnection().catch(() => {}); }
      }, 5000);
    }).catch((error: Error) => { this.update('error', error.message); });
  }

  subscribe(listener: SyncListener): void { this.listener = listener; this.emit(); }
  unsubscribe(): void { this.listener = undefined; }
  isFileInUse(id: string): boolean { return this.view.currentId === id && id.length > 0; }

  private emit(): void {
    if (this.listener === undefined) { return; }
    const snapshot: SyncViewState = new SyncViewState();
    snapshot.status = this.view.status; snapshot.message = this.view.message;
    snapshot.peerName = this.view.peerName; snapshot.currentId = this.view.currentId;
    snapshot.progress = this.view.progress; snapshot.syncedIds = this.view.syncedIds.slice();
    this.listener(snapshot);
  }
  private update(status: string, message: string): void {
    this.view.status = status; this.view.message = message; this.emit();
  }

  async connect(): Promise<void> {
    if (this.closing || this.connecting || this.engine !== undefined || this.sourceId.length === 0 ||
      this.context === undefined || this.store === undefined) { return; }
    this.connecting = true;
    const generation: number = this.generation;
    this.update('connecting', '正在连接已配对手机');
    try {
      const devices: wearEngine.Device[] = await withTimeout(
        wearEngine.getDeviceClient(this.context).getConnectedDevices(), 15000, '查询手机超时，请重试');
      const phones: wearEngine.Device[] = devices.filter((device: wearEngine.Device) =>
        device.category === undefined || device.category === wearEngine.DeviceCategory.DEFAULT);
      if (phones.length !== 1) { throw new Error(phones.length === 0 ? '未连接手机，请检查运动健康中的连接' : '发现多个手机，请保留目标手机连接'); }
      const device: wearEngine.Device = phones[0];
      const client: wearEngine.P2pClient = wearEngine.getP2pClient(this.context);
      if (!await withTimeout(client.isRemoteAppInstalled(device.randomId, PHONE_BUNDLE_NAME), 15000, '查询手机应用超时')) {
        throw new Error('请先在配对手机安装 ClawMate');
      }
      if (this.closing || generation !== this.generation) { return; }
      this.client = client; this.device = device;
      const transport: WearEngineTransport = new WearEngineTransport(client, device.randomId, this.peer);
      this.transport = transport;
      const engine: RecordingSyncEngine = new RecordingSyncEngine(this.store, transport, this.sourceId,
        `${device.randomId}|${PHONE_APP_ID}`, (state: SyncViewState): void => {
          if (this.closing || generation !== this.generation) { return; }
          state.peerName = device.name || '已配对手机';
          this.view = state; this.emit();
        });
      this.engine = engine;
      const receiver = (message: wearEngine.P2pMessage): void => {
        if (!this.closing && generation === this.generation && this.engine === engine) { this.receive(message, engine); }
      };
      this.receiver = receiver;
      const registration: Promise<void> = client.registerMessageReceiver(device.randomId, this.peer, receiver);
      registration.then(() => {
        if (this.closing || generation !== this.generation) {
          client.unregisterMessageReceiver(device.randomId, this.peer, receiver).catch(() => {});
        }
      }).catch(() => {});
      await withTimeout(registration, 15000, '手机消息接收器注册超时');
      if (this.closing || generation !== this.generation) {
        try { await client.unregisterMessageReceiver(device.randomId, this.peer, receiver); } catch (_) {}
        return;
      }
      this.receiverRegistered = true;
      await engine.initialize();
      if (!this.serviceSubscribed) { wearEngine.on('serviceDie', this.serviceDied); this.serviceSubscribed = true; }
      this.retryDelay = 5000;
    } catch (error) {
      if (!this.closing && generation === this.generation) {
        await this.disconnect(this.describe(error as BusinessError));
      }
    } finally {
      this.connecting = false;
      this.nextRetry = Date.now() + this.retryDelay;
      this.retryDelay = Math.min(60000, this.retryDelay * 2);
    }
  }

  private async checkConnection(): Promise<void> {
    if (this.checking || this.context === undefined || this.device === undefined) { return; }
    this.checking = true;
    this.lastCheck = Date.now();
    const generation: number = this.generation;
    const id: string = this.device.randomId;
    try {
      const devices: wearEngine.Device[] = await withTimeout(
        wearEngine.getDeviceClient(this.context).getConnectedDevices(), 10000, '检查手机连接超时');
      if (generation === this.generation && !devices.some((device: wearEngine.Device) => device.randomId === id)) {
        await this.disconnect('手机已断开，等待重新连接');
      }
    } catch (_) { if (generation === this.generation) { await this.disconnect('手机连接不可用，等待重连'); } }
    finally { this.checking = false; }
  }

  private describe(error: BusinessError): string {
    if (error.code === 1008500004) { return '手机 App 尚未开通 Wear Engine 服务'; }
    if (error.code === 1008500003 || error.code === 1008500002) { return '手机已断开，请检查运动健康连接'; }
    return `${error.message || '手机连接失败'}${error.code ? ` (${error.code})` : ''}`;
  }

  async reconnect(): Promise<void> { await this.disconnect('正在重新连接'); await this.connect(); }

  private async disconnect(message: string): Promise<void> {
    this.generation++;
    const engine: RecordingSyncEngine | undefined = this.engine;
    this.engine = undefined;
    await engine?.disconnect();
    await this.transport?.close();
    this.transport = undefined;
    if (this.receiverRegistered && this.client !== undefined && this.device !== undefined && this.receiver !== undefined) {
      try { await withTimeout(this.client.unregisterMessageReceiver(this.device.randomId, this.peer, this.receiver),
        5000, '取消消息接收超时'); } catch (_) {}
    }
    this.receiverRegistered = false;
    this.receiver = undefined;
    this.client = undefined; this.device = undefined;
    this.view.currentId = ''; this.view.progress = 0;
    if (!this.closing) { this.update('offline', message); }
  }

  async destroy(): Promise<void> {
    this.closing = true;
    if (this.poll !== -1) { clearInterval(this.poll); this.poll = -1; }
    backgroundTasks.offCancel(this.taskCancelled);
    if (this.serviceSubscribed) { try { wearEngine.off('serviceDie', this.serviceDied); } catch (_) {} }
    this.serviceSubscribed = false;
    await this.disconnect('应用已关闭');
    this.store?.destroy(); this.store = undefined;
    this.listener = undefined;
  }
}
export const phoneSyncController: PhoneSyncController = new PhoneSyncController();
