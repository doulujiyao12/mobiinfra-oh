import { rcp } from '@kit.RemoteCommunicationKit';
import { PrivacyConsent } from '../../utils/PrivacyConsent';
import {
  CodexConnection, CodexEnvelope, CodexCreateBody, CodexTurnBody, CodexUploadBody, CodexApprovalBody,
  normalizeCodexOrigin, validCodexToken, validCodexCa, CodexPairBody, CodexPairingBundle, validateCodexPairing
} from './CodexTypes';

export class CodexClient {
  private origin: string = '';
  private token: string = '';
  private caCertificate: string = '';
  private generation: number = 0;
  private cancellers: (() => void)[] = [];

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
    this.cancellers = []; this.token = ''; this.origin = ''; this.caCertificate = '';
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

  async call(route: string, body?: CodexCreateBody | CodexTurnBody | CodexUploadBody | CodexApprovalBody): Promise<CodexEnvelope> {
    return this.request(route, body, true);
  }

  private async request(route: string, body: CodexCreateBody | CodexTurnBody | CodexUploadBody | CodexApprovalBody | CodexPairBody | undefined,
    authenticated: boolean): Promise<CodexEnvelope> {
    PrivacyConsent.requireAccepted();
    if (!this.origin || !this.token) { throw new Error('请先连接 Codex 服务器'); }
    const generation = this.generation;
    const security: rcp.SecurityConfiguration = this.caCertificate ?
      { remoteValidation: { content: this.caCertificate } } : { remoteValidation: 'system' };
    const session = rcp.createSession({ requestConfiguration: {
      transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 55000 } },
      tracing: { verbose: false }, security: security
    } });
    let closed = false;
    const close = (): void => {
      if (!closed) { closed = true; try { session.close(); } catch (e) { } }
    };
    this.cancellers.push(close);
    const unregister = PrivacyConsent.registerExternalRequest(close);
    try {
      const headers: rcp.RequestHeaders = { 'Content-Type': 'application/json' };
      if (authenticated) { headers['Authorization'] = 'Bearer ' + this.token; }
      const request = new rcp.Request(this.origin + route, body === undefined ? 'GET' : 'POST', headers,
        body === undefined ? undefined : JSON.stringify(body));
      const response = await session.fetch(request);
      if (generation !== this.generation) { throw new Error('连接已更换'); }
      PrivacyConsent.requireAccepted();
      if (response.statusCode >= 300 && response.statusCode < 400) { throw new Error('服务器重定向已拒绝，请填写最终 HTTPS 地址'); }
      if (response.statusCode === 401) { throw new Error('令牌无效或已撤销，请在连接设置中更新'); }
      if (response.statusCode === 429) { throw new Error('请求过于频繁，请稍后重试'); }
      if ((response.body?.byteLength ?? 0) > 16 * 1024 * 1024) { throw new Error('服务器响应过大'); }
      const envelope = JSON.parse(response.toString()) as CodexEnvelope;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(envelope.error || '服务器请求失败');
      }
      return envelope;
    } finally {
      unregister();
      this.cancellers = this.cancellers.filter((cancel: () => void) => cancel !== close);
      close();
    }
  }
}
