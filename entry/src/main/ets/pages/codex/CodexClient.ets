import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppRequests } from '../../utils/AppRequests';
import { codexResponseText } from './CodexResponseText';
import {
  CodexConnection, CodexEnvelope, CodexCreateBody, CodexTurnBody, CodexUploadBody, CodexApprovalBody,
  normalizeCodexOrigin, validCodexToken, validCodexCa, CodexPairBody, CodexPairingBundle, validateCodexPairing, CodexForkBody, CodexResumeBody
} from './CodexTypes';

class CodexRequestFailure extends Error {
  retryable: boolean;
  transportFailure: boolean;
  constructor(message: string, retryable: boolean = false, transportFailure: boolean = false) {
    super(message); this.retryable = retryable; this.transportFailure = transportFailure;
  }
}

export class CodexClient {
  private origin: string = '';
  private token: string = '';
  private caCertificate: string = '';
  private generation: number = 0;
  private cancellers: (() => void)[] = [];
  private updateCancellers: (() => void)[] = [];
  private session: rcp.Session | null = null;
  private compressionEnabled: boolean = true;
  private chunkBytes: number = 1024 * 1024;
  onReachability: (reachable: boolean, message: string) => void = () => {};

  setArtifactChunkBytes(bytes: number): void {
    this.chunkBytes = Number.isSafeInteger(bytes) && bytes >= 16384 && bytes <= 1048576 ? bytes : 1048576;
  }
  artifactChunkBytes(): number { return this.chunkBytes; }

  configure(connection: CodexConnection): void {
    this.close();
    this.origin = normalizeCodexOrigin(connection.origin);
    if (!validCodexToken(connection.token)) { throw new Error('桥接令牌格式无效，请使用服务器生成的 token'); }
    this.token = connection.token;
    if (connection.caCertificate && !validCodexCa(connection.caCertificate)) { throw new Error('配对证书格式无效'); }
    this.caCertificate = connection.caCertificate || '';
  }

  close(): void {
    this.generation++;
    this.cancellers.forEach((cancel: () => void) => { cancel(); });
    this.cancellers = []; this.updateCancellers = []; this.token = ''; this.origin = ''; this.caCertificate = '';
    this.session?.close(); this.session = null; this.chunkBytes = 1048576; this.compressionEnabled = true;
  }
  cancelTaskUpdates(): void {
    this.updateCancellers.forEach((cancel: () => void) => { cancel(); }); this.updateCancellers = [];
  }

  async pair(bundle: CodexPairingBundle): Promise<CodexConnection> {
    validateCodexPairing(bundle);
    this.configure({ origin: bundle.origin, token: bundle.code, caCertificate: bundle.caCertificate });
    const result = await this.request('/v1/pair', { code: bundle.code, deviceName: '我的鸿蒙手机' }, false);
    if (!result.token || !validCodexToken(result.token) || result.serverId !== bundle.serverId) {
      this.close(); throw new Error('配对响应不匹配，请重新生成配对信息');
    }
    const connection: CodexConnection = { origin: bundle.origin, token: result.token, caCertificate: bundle.caCertificate };
    this.configure(connection); return connection;
  }

  async call(route: string, body?: CodexCreateBody | CodexTurnBody | CodexUploadBody | CodexApprovalBody | CodexForkBody | CodexResumeBody): Promise<CodexEnvelope> {
    return this.request(route, body, true);
  }

  private async request(route: string, body: CodexCreateBody | CodexTurnBody | CodexUploadBody | CodexApprovalBody | CodexPairBody | CodexForkBody | CodexResumeBody | undefined,
    authenticated: boolean): Promise<CodexEnvelope> {
    const generation = this.generation;
    for (let attempt: number = 0; ; attempt++) {
      try { return await this.fetchOnce(route, body, authenticated); }
      catch (e) {
        const failure = e as CodexRequestFailure;
        // Only idempotent reads may retry. Never resend a task, upload, pairing,
        // stop or approval after an ambiguous transport failure.
        if (body !== undefined || route === '/v1/health' || route.includes('waitMs=') || attempt >= 1 ||
          !failure.retryable || generation !== this.generation) { throw failure; }
        await new Promise<void>((resolve) => { setTimeout(resolve, 600 + Math.floor(Math.random() * 600)); });
        if (generation !== this.generation) { throw new Error('连接已更换'); }
      }
    }
  }

  private transport(): rcp.Session {
    if (this.session !== null) { return this.session; }
    const security: rcp.SecurityConfiguration = this.caCertificate ?
      { remoteValidation: { content: this.caCertificate } } : { remoteValidation: 'system' };
    this.session = rcp.createSession({ requestConfiguration: {
      transfer: { autoRedirect: false, timeout: { connectMs: 25000, transferMs: 65000 } },
      tracing: { verbose: false }, security: security
    } });
    return this.session;
  }

  private async fetchOnce(route: string, body: CodexCreateBody | CodexTurnBody | CodexUploadBody | CodexApprovalBody | CodexPairBody | CodexForkBody | CodexResumeBody | undefined,
    authenticated: boolean): Promise<CodexEnvelope> {
    if (!this.origin || !this.token) { throw new Error('请先连接 Codex 服务器'); }
    const generation = this.generation;
    const session = this.transport();
    const headers: rcp.RequestHeaders = { 'Content-Type': 'application/json', 'Accept-Encoding': this.compressionEnabled ? 'gzip' : 'identity' };
    if (authenticated) { headers['Authorization'] = 'Bearer ' + this.token; }
    const request = new rcp.Request(this.origin + route, body === undefined ? 'GET' : 'POST', headers,
      body === undefined ? undefined : JSON.stringify(body));
    let cancelled: boolean = false;
    const close = (): void => {
      if (!cancelled) { cancelled = true; try { session.cancel(request); } catch (e) { } }
    };
    this.cancellers.push(close);
    if (route.includes('waitMs=')) { this.updateCancellers.push(close); }
    const unregister = AppRequests.registerExternalRequest(() => { this.close(); });
    let timer: number = -1;
    let transportFailed: boolean = false;
    let timedOut: boolean = false;
    try {
      const deadline = new Promise<rcp.Response>((resolve, reject) => {
        timer = setTimeout(() => {
          timedOut = true;
          reject(new CodexRequestFailure('连接电脑超时，请检查网络后重试；已下发的任务请先同步状态', true, true));
          close();
        },
          route === '/v1/health' ? 18000 : 70000);
      });
      const response = await Promise.race([session.fetch(request), deadline]);
      if (generation !== this.generation) { throw new Error('连接已更换'); }
      if (cancelled) { throw new Error('请求已取消'); }
      if (response.statusCode !== 401) { this.onReachability(true, ''); }
      if (response.statusCode >= 300 && response.statusCode < 400) { throw new Error('服务器重定向已拒绝，请填写最终 HTTPS 地址'); }
      if (response.statusCode === 401) {
        this.onReachability(false, '连接授权已失效，请重新配对'); throw new Error('令牌无效或已撤销，请在连接设置中更新');
      }
      if (response.statusCode === 429) { throw new Error('请求过于频繁，请稍后重试'); }
      let responseText: string;
      try { responseText = await codexResponseText(response.body, response.toString()); }
      catch (e) {
        const bytes = new Uint8Array(response.body || new ArrayBuffer(0));
        if (bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
          this.compressionEnabled = false;
          throw new CodexRequestFailure('压缩响应未能解析，将改用普通传输，请同步会话后重试', true);
        }
        throw new Error((e as Error).message);
      }
      if (generation !== this.generation || cancelled) { throw new Error('请求已取消或连接已更换'); }
      const envelope = JSON.parse(responseText) as CodexEnvelope;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new CodexRequestFailure(envelope.error || '服务器请求失败', response.statusCode === 502 || response.statusCode === 504);
      }
      return envelope;
    } catch (e) {
      if (generation !== this.generation || cancelled && !timedOut && !(e instanceof CodexRequestFailure)) { throw new Error('请求已取消或连接已更换'); }
      if (timedOut) {
        transportFailed = true; this.onReachability(false, '连接电脑超时，请检查网络后重试');
        throw new CodexRequestFailure('连接电脑超时，请检查网络后重试；已下发的任务请先同步状态', true, true);
      }
      const error = e as Error;
      if (error instanceof CodexRequestFailure) {
        if (error.transportFailure) { transportFailed = true; this.onReachability(false, error.message); }
        throw error;
      }
      const code = (e as BusinessError).code;
      if (code === 1007900061 && this.compressionEnabled) {
        this.compressionEnabled = false;
        throw new CodexRequestFailure('网络组件未能解压响应，将改用普通传输，请同步会话后重试', true);
      }
      const transient = [1007900005, 1007900006, 1007900007, 1007900018, 1007900028, 1007900035,
        1007900052, 1007900055, 1007900056, 1007900092, 1007900095].includes(code);
      if (transient) {
        transportFailed = true; this.onReachability(false, '网络暂时中断，正在尝试恢复');
        throw new CodexRequestFailure(code === 1007900028 ? '连接电脑超时，请稍后重试' : '与电脑的网络连接中断，请稍后重试', true, true);
      }
      throw error;
    } finally {
      if (timer >= 0) { clearTimeout(timer); }
      unregister();
      this.cancellers = this.cancellers.filter((cancel: () => void) => cancel !== close);
      this.updateCancellers = this.updateCancellers.filter((cancel: () => void) => cancel !== close);
      if (transportFailed && this.cancellers.length === 0 && this.session === session) {
        session.close(); this.session = null;
      }
    }
  }
}
