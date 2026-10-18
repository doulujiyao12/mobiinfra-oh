import { EventEmitter } from 'node:events';
import { readFileSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { CodexRpc } from '../../bridge/codex/rpc.mjs';
import { BridgeCore } from '../../bridge/codex/core.mjs';
import { createBridgeServer } from '../../bridge/codex/server.mjs';
import { PairingManager, PAIRING_PREFIX } from '../../bridge/codex/pairing.mjs';
import { Settings, writePrivate } from './settings.mjs';
import { ensureCertificates, lanAddresses } from './certificates.mjs';
import { VERSION } from './paths.mjs';
import QRCode from 'qrcode';

export class CompanionManager extends EventEmitter {
  server = null; core = null; rpc = null; state = 'stopped'; lastError = ''; account = null;
  constructor(directory, layout, dependencies = {}) {
    super(); this.settings = new Settings(directory); this.layout = layout;
    this.rpcFactory = dependencies.rpcFactory || (() => new CodexRpc(layout.codex, undefined, { env: {
      ...process.env, PATH: path.join(path.dirname(layout.codex), '..', 'codex-path') + path.delimiter + (process.env.PATH || '')
    } }));
    this.pairing = new PairingManager(this.settings.directory);
  }
  async initialize() {
    this.rpc = this.rpcFactory();
    this.rpc.on('message', message => {
      if (message.method === 'account/login/completed') {
        this.lastLogin = { success: !!message.params.success, error: message.params.error || '' };
        this.readAccount().catch(() => {}); this.emit('change');
      }
      if (message.id !== undefined && message.method && !this.core) {
        this.rpc.send({ id: message.id, error: { code: -32601, message: 'Unsupported local interaction' } });
      }
    });
    this.rpc.on('stopped', () => { this.state = 'error'; this.lastError = 'Codex 已退出。请关闭并重新打开 PC 应用。'; this.emit('change'); });
    await this.rpc.initialize(); await this.readAccount();
  }
  async readAccount() {
    const result = await this.rpc.request('account/read', { refreshToken: false });
    this.requiresOpenaiAuth = result.requiresOpenaiAuth;
    this.account = result.account ? { type: result.account.type,
      email: result.account.email || '', planType: result.account.planType || '' } : null;
    return this.account;
  }
  status() {
    const config = this.settings.publicValue();
    const addresses = lanAddresses();
    const origins = config.networkMode === 'public' ? [config.publicOrigin].filter(Boolean) :
      (config.host === '127.0.0.1' ? ['127.0.0.1'] : addresses).map(ip => `https://${ip}:${config.port}`);
    return { version: VERSION, state: this.state, lastError: this.lastError, account: this.account,
      login: this.lastLogin || null, config, origins, devices: this.pairing.list(),
      fingerprint: this.certificates?.fingerprint || '', tasks: this.core?.list() || [],
      dataDirectory: this.settings.directory, launcher: this.layout.launcher };
  }
  configure(body) {
    if (this.server || this.state === 'starting') throw new Error('请先停止手机连接服务，再修改项目或网络配置。');
    this.settings.update(body); return this.status();
  }
  async login(type = 'chatgpt') {
    if (!['chatgpt', 'chatgptDeviceCode'].includes(type)) throw new Error('无效的登录方式。');
    this.lastLogin = null;
    const result = await this.rpc.request('account/login/start', { type });
    this.loginId = result.loginId;
    // Only supported browser/device flows are exposed. No raw credentials leave Codex.
    return { type: result.type, authUrl: result.authUrl, verificationUrl: result.verificationUrl, userCode: result.userCode };
  }
  async cancelLogin() {
    if (this.loginId) await this.rpc.request('account/login/cancel', { loginId: this.loginId });
    this.loginId = null; this.lastLogin = null;
  }
  async logout() {
    if (this.server) throw new Error('请先停止连接服务，再退出 Codex 账号。');
    await this.rpc.request('account/logout'); await this.readAccount(); return this.status();
  }
  async start() {
    if (this.server) return this.status();
    if (this.state === 'starting') throw new Error('服务正在启动，请稍候。');
    this.state = 'starting'; this.lastError = '';
    try {
      await this.readAccount();
      if (!this.account && this.requiresOpenaiAuth !== false) throw new Error('请先登录 Codex。');
      const config = this.settings.value;
      if (!config.workspaces.length) throw new Error('请先选择至少一个项目文件夹。');
      this.certificates = config.networkMode === 'lan' ? ensureCertificates(this.settings.directory, lanAddresses(), this.layout.launcher) :
        { cert: config.certFile, key: config.keyFile, caCertificate: '', fingerprint: '' };
      const bridgeConfig = { ...config, stateDir: path.join(this.settings.directory, 'tasks'), tls: this.certificates };
      if (this.core) { this.core.close(); this.core = null; await this.initialize(); }
      this.core = new BridgeCore(bridgeConfig, this.rpc);
      await this.core.initialize({ initializeRpc: false });
      this.server = createBridgeServer(bridgeConfig, this.core, { pairing: this.pairing });
      await new Promise((resolve, reject) => {
        this.server.once('error', reject); this.server.listen(config.port, config.host, resolve);
      });
      this.state = 'running';
      this.server.on('error', () => { this.state = 'error'; this.lastError = '连接服务异常，请停止后重新启动。'; });
      return this.status();
    } catch (error) {
      this.server?.close(); this.server = null; this.state = 'error'; this.lastError = error.message;
      throw new Error('启动失败：' + error.message);
    }
  }
  async stop() {
    if (this.core) this.core.ready = false;
    if (this.core?.list().some(task => ['running', 'starting', 'waitingApproval', 'stopping'].includes(task.status))) {
      this.core.ready = true;
      throw new Error('仍有任务在运行或等待审批。请先在手机中停止这些任务，再停止服务。');
    }
    this.pairing.cancel();
    if (this.server) {
      const server = this.server; this.server = null;
      server.closeIdleConnections();
      await new Promise(resolve => server.close(resolve));
    }
    this.state = 'stopped'; return this.status();
  }
  async createPairing(origin) {
    if (this.state !== 'running') throw new Error('请先启动手机连接服务。');
    if (!this.status().origins.includes(origin)) throw new Error('请选择本机当前可用的连接地址。');
    if (this.settings.value.networkMode === 'lan') {
      this.certificates = ensureCertificates(this.settings.directory, lanAddresses(), this.layout.launcher);
      this.server.setSecureContext({ cert: readFileSync(this.certificates.cert), key: readFileSync(this.certificates.key) });
    }
    const bundle = this.pairing.create({ origin, name: this.settings.value.name, caCertificate: this.certificates.caCertificate });
    const encoded = PAIRING_PREFIX + Buffer.from(JSON.stringify(bundle)).toString('base64url');
    const qr = await QRCode.toDataURL(encoded, { errorCorrectionLevel: 'L', width: 480, margin: 2 });
    return { bundle, encoded, qr, expiresAt: bundle.expiresAt, fingerprint: this.certificates.fingerprint };
  }
  exportPairing(filename, bundle) {
    // Native save dialog/CLI chooses the file; the short-lived secret never enters a log.
    writePrivate(filename, bundle); return { filename };
  }
  async dispatch(method, body = {}) {
    switch (method) {
      case 'status': await this.readAccount(); return this.status();
      case 'configure': return this.configure(body);
      case 'login': return this.login(body.type);
      case 'cancelLogin': await this.cancelLogin(); return this.status();
      case 'logout': return this.logout();
      case 'start': return this.start();
      case 'stop': return this.stop();
      case 'pair': return this.createPairing(body.origin);
      case 'revoke': this.pairing.revoke(body.id); return this.status();
      case 'interrupt': if (!this.core) throw new Error('没有活动任务。'); await this.core.interrupt(body.id); return this.status();
      case 'resetPairing':
        if (this.server) throw new Error('请先停止手机连接服务，再重置配对。');
        this.pairing.reset();
        for (const filename of ['pairing-ca.pem', 'pairing-ca-key.pem', 'server-cert.pem', 'server-key.pem']) {
          try { unlinkSync(path.join(this.settings.directory, filename)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        }
        this.certificates = null; return this.status();
      default: throw new Error('不支持的本机操作。');
    }
  }
  async close() {
    this.pairing.cancel();
    if (this.server) { this.server.closeAllConnections(); this.server.close(); this.server = null; }
    if (this.core) this.core.close(); else this.rpc?.close();
  }
}
