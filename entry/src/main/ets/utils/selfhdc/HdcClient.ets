import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { decodeUtf8Compat, encodeUtf8Compat } from '../TextEncodingCompat';
import { HdcIdentity } from './HdcIdentity';
import { HdcAuthBarrier } from './HdcAuthBarrier';
import { HdcShellResult, buildHdcShellPlan, hdcShellOutputPreview, parseHdcShellResult } from './HdcShell';
import {
  HdcAuth, HdcCommand, HdcHandshake, HdcPacket, HdcPacketStream, decodeHdcHandshake,
  decodeHdcTlv, encodeHdcHandshake, encodeHdcPacket, encodeHdcTlv, isHdcAuthPending, joinHdcBytes
} from './HdcProtocol';

class HdcCompletion<T> {
  promise: Promise<T>;
  private resolveValue: (value: T) => void = (_value: T): void => {};
  private rejectValue: (error: Error) => void = (_error: Error): void => {};
  private settled: boolean = false;
  constructor() {
    this.promise = new Promise<T>((resolve, reject): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
    // Network callbacks may fail before connect() has started awaiting authentication.
    this.promise.catch((_error: Error): void => {});
  }
  resolve(value: T): void {
    if (!this.settled) {
      this.settled = true;
      this.resolveValue(value);
    }
  }
  reject(error: Error): void {
    if (!this.settled) {
      this.settled = true;
      this.rejectValue(error);
    }
  }
}

class HdcShellRequest {
  completion: HdcCompletion<Uint8Array> = new HdcCompletion<Uint8Array>();
  chunks: Uint8Array[] = [];
  size: number = 0;
  timer: number = -1;
  channel: number;
  constructor(channel: number) { this.channel = channel; }
}

// One short-lived direct TCP session per test. No subprocess, HTTP proxy or PC keys.
export class HdcClient {
  private tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
  private stream: HdcPacketStream = new HdcPacketStream();
  private auth: HdcCompletion<boolean> = new HdcCompletion<boolean>();
  private authBarrier: HdcAuthBarrier = new HdcAuthBarrier();
  private receiveQueue: Promise<void> = Promise.resolve();
  private queuedBytes: number = 0;
  private active: HdcShellRequest | undefined = undefined;
  private authTimer: number = -1;
  private session: number = 0;
  private nextChannel: number = 100;
  private modern: boolean = false;
  private authorized: boolean = false;
  private stopped: boolean = false;
  private failure: Error | undefined = undefined;
  private identity: HdcIdentity | undefined = undefined;
  private target: string = '';
  // Identifies the implemented public protocol revision; no proprietary SDK hash is forged.
  private readonly version: string = 'Ver: 3.2.0g';

  private log: (event: string) => void;
  constructor(log: (event: string) => void) { this.log = log; }

  async connect(ip: string, port: number, filesDir: string): Promise<void> {
    try {
      this.log('KEY loading/generating app-private RSA3072 identity');
      this.identity = await HdcIdentity.load(filesDir);
      this.checkOpen();
      this.log('KEY public SHA256=' + this.identity.fingerprint);
      this.session = await HdcIdentity.sessionId();
      this.checkOpen();
      this.target = ip + ':' + String(port);
      this.tcp.on('message', (info: socket.SocketMessageInfo): void => {
        if (this.stopped) { return; }
        let bytes = new Uint8Array(info.message);
        this.queuedBytes += bytes.length;
        if (this.queuedBytes > 4 * 1024 * 1024) {
          this.fail(new Error('HDC_PROTO: queued input exceeds 4 MiB'));
          return;
        }
        this.receiveQueue = this.receiveQueue.then(async (): Promise<void> => {
          this.queuedBytes -= bytes.length;
          if (this.stopped) { return; }
          let packets = this.stream.feed(bytes);
          for (let index = 0; index < packets.length; index++) {
            if (this.stopped) { break; }
            await this.receive(packets[index]);
          }
        }).catch((error: Error): void => { this.fail(error); });
      });
      this.tcp.on('error', (error: BusinessError): void => {
        this.fail(new Error('HDC_TCP: code=' + String(error.code) + ' ' + error.message));
      });
      this.tcp.on('close', (): void => {
        if (!this.stopped) { this.fail(new Error('HDC_TCP: daemon closed connection')); }
      });
      this.log('TCP connecting ' + this.target + ' session=' + String(this.session));
      await this.tcp.bind({ address: '0.0.0.0', family: 1, port: 0 });
      this.checkOpen();
      await this.tcp.connect({ address: { address: ip, family: 1, port: port }, timeout: 8000 });
      this.checkOpen();
      this.log('TCP connected; sending AUTH_NONE, protocol=' + this.version);
      this.authTimer = setTimeout((): void => {
        this.fail(new Error(this.authBarrier.hasSuccess()
          ? 'HDC_HANDSHAKE_TIMEOUT: 已认证但握手通道关闭确认未完成，未发送 Shell'
          : 'HDC_AUTH_TIMEOUT: 90秒内未获授权；检查手机授权弹窗及无线调试状态'));
      }, 90000);
      await this.sendHandshake(HdcAuth.None, encodeHdcTlv('authtype', '1'));
      await this.auth.promise;
      this.checkOpen();
    } catch (e) {
      let error = e as Error;
      this.fail(error);
      throw error;
    }
  }

  private checkOpen(): void {
    if (this.stopped) {
      throw this.failure || new Error('SELF_HDC_CANCELLED: 已停止连接');
    }
  }

  private async send(channel: number, command: number, data: Uint8Array): Promise<void> {
    this.checkOpen();
    this.log('TX channel=' + String(channel) + ' command=' + String(command) + ' bytes=' + String(data.length));
    await this.tcp.send({ data: encodeHdcPacket({ channel: channel, command: command, data: data }).buffer });
    this.checkOpen();
  }

  private async sendHandshake(auth: number, data: Uint8Array): Promise<void> {
    let handshake: HdcHandshake = {
      banner: 'OHOS HDC', auth: auth, session: this.session, target: this.target,
      data: data, version: this.version
    };
    await this.send(0, HdcCommand.Handshake, encodeHdcHandshake(handshake));
  }

  private async receive(packet: HdcPacket): Promise<void> {
    this.log('RX channel=' + String(packet.channel) + ' command=' + String(packet.command) +
      ' bytes=' + String(packet.data.length));
    if (packet.command === HdcCommand.Handshake) {
      if (packet.channel !== 0) { throw new Error('HDC_PROTO: handshake on nonzero channel'); }
      await this.receiveHandshake(decodeHdcHandshake(packet.data));
      return;
    }
    if (packet.command === HdcCommand.ChannelClose) {
      if (packet.data.length !== 1) { throw new Error('HDC_PROTO: malformed channel close'); }
      if (packet.data[0] > 0) {
        await this.send(packet.channel, HdcCommand.ChannelClose, new Uint8Array([packet.data[0] - 1]));
      }
      if (packet.channel === 0) {
        // AUTH_OK alone must NOT resolve connect(): this ACK can kill every active daemon task.
        // TCP preserves write order, so acknowledge it before sending the first shell command.
        if (this.authBarrier.closeAcknowledged()) {
          this.authorized = true;
          clearTimeout(this.authTimer);
          this.authTimer = -1;
          this.log('AUTH READY: channel-0 close acknowledged; shell commands may now start');
          this.auth.resolve(true);
        } else { this.log('AUTH channel-0 close acknowledged; still waiting for successful authentication'); }
        return;
      }
      let request = this.active;
      if (request && request.channel === packet.channel) {
        clearTimeout(request.timer);
        this.active = undefined;
        request.completion.resolve(joinHdcBytes(request.chunks));
      }
      return;
    }
    if (packet.command === HdcCommand.Echo) {
      if (packet.data.length === 0) { throw new Error('HDC_PROTO: empty echo'); }
      let message = decodeUtf8Compat(packet.data.slice(1));
      this.log('DAEMON level=' + String(packet.data[0]) + ' ' + message.substring(0, 1600));
      if (packet.data[0] === 0) { // MSG_FAIL=0, not 1.
        if (packet.channel === 0 && !this.authorized && isHdcAuthPending(message)) { return; }
        throw new Error('HDC_DAEMON: ' + message.substring(0, 1600));
      }
      return;
    }
    if (packet.command === HdcCommand.EchoRaw) {
      let request = this.active;
      if (!request || request.channel !== packet.channel) {
        throw new Error('HDC_PROTO: shell data on unexpected channel');
      }
      request.size += packet.data.length;
      if (request.size > 16 * 1024 * 1024) { throw new Error('HDC_SHELL: output exceeds 16 MiB'); }
      request.chunks.push(packet.data);
      return;
    }
    throw new Error('HDC_UNSUPPORTED: daemon command=' + String(packet.command));
  }

  private async receiveHandshake(handshake: HdcHandshake): Promise<void> {
    if (handshake.banner !== 'OHOS HDC') {
      throw new Error('HDC_AUTH: banner=' + handshake.banner + '; 协议版本或系统策略拒绝连接');
    }
    if (handshake.session !== 0 && handshake.session !== this.session) {
      throw new Error('HDC_AUTH: mismatched session id');
    }
    this.log('AUTH received type=' + String(handshake.auth) + ' handshakeVersion=' + handshake.version);
    if (handshake.auth === HdcAuth.PublicKey) {
      if (!this.identity) { throw new Error('HDC_KEY: missing identity'); }
      let features = new Map<string, string>();
      if (handshake.data.length >= 32) { features = decodeHdcTlv(handshake.data); }
      let authType = features.get('authtype');
      if (authType !== undefined && authType !== '0' && authType !== '1') {
        throw new Error('HDC_AUTH_UNSUPPORTED: daemon RSA algorithm=' + authType);
      }
      this.modern = authType === '1';
      this.log('AUTH algorithm=' + (this.modern ? 'RSA3072/PSS/SHA512/salt64' : 'RSA3072/PKCS1/raw') +
        ' peerFeatures=' + (features.get('supportfeatures') || '') +
        ' encrypttcp=' + (features.get('encrypttcp') || 'unspecified'));
      if (features.get('encrypttcp') === '1') {
        throw new Error('HDC_TLS_REQUIRED: 此端口要求加密 HDC；当前客户端尚未实现 TLS-PSK，停止测试');
      }
      await this.sendHandshake(HdcAuth.PublicKey, encodeUtf8Compat('MobiInfra-SelfHdc\f' + this.identity.pem));
      this.log('AUTH public key sent; 请在手机系统弹窗中允许 MobiInfra-SelfHdc 调试');
      return;
    }
    if (handshake.auth === HdcAuth.Signature) {
      if (!this.identity) { throw new Error('HDC_KEY: missing identity'); }
      this.log('AUTH signing challenge (' + String(handshake.data.length) + ' bytes; contents omitted)');
      let signature = await this.identity.sign(handshake.data, this.modern);
      this.checkOpen();
      await this.sendHandshake(HdcAuth.Signature, encodeUtf8Compat(signature));
      return;
    }
    if (handshake.auth === HdcAuth.Ok) {
      let fields = decodeHdcTlv(handshake.data);
      let status = fields.get('daemonauthstatus') || '';
      let message = fields.get('emgmsg') || '';
      this.log('AUTH status=' + status + ' message=' + message.substring(0, 1600));
      if (status === 'DAEMON_UNAUTH' && isHdcAuthPending(message)) {
        this.authBarrier.authOk(false);
        this.log('AUTH WAITING_USER: 系统尚未授权，继续等待弹窗确认');
        return;
      }
      if (status !== 'SUCCESS') {
        throw new Error('HDC_AUTH_REJECTED: ' + status + ' ' + message);
      }
      if (message.length > 0) { this.log('AUTH daemon notice=' + message.substring(0, 1600)); }
      this.authBarrier.authOk(true);
      this.log('AUTH SUCCESS: daemon reports SUCCESS; waiting for channel-0 close ACK before shell');
      return;
    }
    if (handshake.auth === HdcAuth.TlsPsk) {
      throw new Error('HDC_TLS_REQUIRED: daemon requires TLS-PSK; 当前实现无法完成此认证');
    }
    throw new Error('HDC_AUTH_UNSUPPORTED: authType=' + String(handshake.auth));
  }

  async shell(command: string, timeoutMs: number = 20000, sensitiveOutput: boolean = false,
    sensitiveCommand: boolean = false): Promise<HdcShellResult> {
    this.checkOpen();
    if (!this.authorized) { throw new Error('HDC_AUTH: shell requested before authorization'); }
    if (this.active) { throw new Error('HDC_SHELL: concurrent command not allowed'); }
    let request = new HdcShellRequest(this.nextChannel++);
    let plan = buildHdcShellPlan(command, this.session, request.channel);
    this.active = request;
    // HDC's raw-shell protocol does not report the process exit status. Obtain it in-band.
    request.timer = setTimeout((): void => {
      this.fail(new Error('HDC_SHELL_TIMEOUT: channel=' + String(request.channel) + ' timeout=' + String(timeoutMs)));
    }, timeoutMs);
    try {
      this.log('SHELL wrapper=compound-v2 channel=' + String(request.channel) +
        ' wireCommand=' + (sensitiveCommand ? '(input text omitted)' : hdcShellOutputPreview(plan.wireCommand, false)));
      await this.send(request.channel, HdcCommand.Execute, encodeUtf8Compat(plan.wireCommand + '\0'));
      let output = decodeUtf8Compat(await request.completion.promise);
      let result: HdcShellResult;
      try { result = parseHdcShellResult(output, plan.marker); } catch (e) {
        this.log('SHELL parse failed channel=' + String(request.channel) +
          ' outputBytes=' + String(request.size) + ' expectedMarker=' + plan.marker +
          ' reply=' + hdcShellOutputPreview(output, sensitiveOutput));
        throw e as Error;
      }
      this.log('SHELL completed channel=' + String(request.channel) + ' exit=' + String(result.exitCode) +
        ' outputBytes=' + String(request.size));
      return result;
    } catch (e) {
      let error = e as Error;
      this.fail(error);
      throw error;
    } finally {
      clearTimeout(request.timer);
      if (this.active === request) { this.active = undefined; }
    }
  }

  private fail(error: Error): void {
    if (this.stopped) { return; }
    this.failure = error;
    this.auth.reject(error);
    if (this.active) { this.active.completion.reject(error); }
    this.close();
  }

  close(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    clearTimeout(this.authTimer);
    let error = this.failure || new Error('SELF_HDC_CANCELLED: connection closed');
    this.auth.reject(error);
    if (this.active) {
      clearTimeout(this.active.timer);
      this.active.completion.reject(error);
      this.active = undefined;
    }
    try {
      this.tcp.off('message');
      this.tcp.off('error');
      this.tcp.off('close');
    } catch (e) { /* A socket that failed before bind may have no registered listeners. */ }
    try { this.tcp.close().catch((_error: Error): void => {}); } catch (e) { /* Already closed/unbound. */ }
  }
}
