import { EventEmitter } from 'node:events';
import { existsSync, readFileSync, unlinkSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { CodexRpc } from '../../bridge/codex/rpc.mjs';
import { BridgeCore } from '../../bridge/codex/core.mjs';
import { createBridgeServer } from '../../bridge/codex/server.mjs';
import { PairingManager, PAIRING_PREFIX } from '../../bridge/codex/pairing.mjs';
import { Settings, writePrivate } from './settings.mjs';
import { ensureCertificates, lanAddresses } from './certificates.mjs';
import { VERSION } from './paths.mjs';
import { TailscaleDiscovery } from './tailscale.mjs';
import { findCodexRuntime, resolveCodexSelection } from './codex-runtime.mjs';
import QRCode from 'qrcode';

export class CompanionManager extends EventEmitter {
  server = null; core = null; rpc = null; state = 'stopped'; lastError = ''; account = null;
  runtimeError = ''; runtimeSetup = null;
  constructor(directory, layout, dependencies = {}) {
    super(); this.settings = new Settings(directory); this.layout = layout;
    this.tailscale = dependencies.tailscale || new TailscaleDiscovery();
    this.rpcFactory = dependencies.rpcFactory || (() => {
      const executable = findCodexRuntime({ resources: layout.base, preferredExecutable: this.settings.value.codexExecutable });
      const tools = path.join(path.dirname(executable), '..', 'codex-path');
      // A Unix npm launcher may need Node.js via its shebang when started from a GUI.
      const runtimePath = [existsSync(tools) ? tools : '', process.env.PATH, path.dirname(layout.node)].filter(Boolean);
      const env = { ...process.env, PATH: runtimePath.join(path.delimiter) };
      return new CodexRpc(executable, undefined, { env });
    });
    this.pairing = new PairingManager(this.settings.directory);
  }
  async initialize() {
    await this.ensureRuntime();
    await this.tailscale.refresh();
  }

  async ensureRuntime() {
    if (!this.runtimeSetup && (!this.rpc || this.rpc.closed)) {
      this.runtimeSetup = this.connectRuntime().finally(() => { this.runtimeSetup = null; });
    }
    await this.runtimeSetup;
    return !!this.rpc && !this.rpc.closed;
  }

  async connectRuntime() {
    this.account = null;
    let rpc;
    try { rpc = this.rpcFactory(); }
    catch (error) { this.runtimeError = error.message; return; }
    this.rpc = rpc;
    rpc.on('oversized', method => {
      if (this.rpc === rpc) console.warn('本机 Codex 返回超大数据：' + method);
    });
    rpc.on('message', message => {
      if (this.rpc !== rpc) return;
      if (message.method === 'account/login/completed') {
        this.lastLogin = { success: !!message.params.success, error: message.params.error || '' };
        this.readAccount().catch(() => {}); this.emit('change');
      }
      if (message.id !== undefined && message.method && !this.core) {
        rpc.send({ id: message.id, error: { code: -32601, message: 'Unsupported local interaction' } });
      }
    });
    rpc.on('stopped', reason => {
      if (this.rpc !== rpc) return;
      this.account = null;
      this.runtimeError = '本机 Codex 已退出，请重新启动手机连接。';
      if (this.state !== 'starting' && this.state !== 'stopping') this.state = 'error';
      console.error('本机 Codex 运行进程已退出：' + (reason || 'unknown'));
      this.emit('change');
    });
    try { await rpc.initialize(); await this.readAccount(); this.runtimeError = ''; }
    catch {
      this.rpc = null; rpc.close();
      this.runtimeError = '无法启动本机 Codex。请更新 Codex，或选择另一个 Codex 程序。';
    }
  }
  async readAccount() {
    const rpc = this.rpc;
    if (!rpc || rpc.closed) return this.account = null;
    const result = await rpc.request('account/read', { refreshToken: false });
    if (this.rpc !== rpc || rpc.closed) return this.account;
    this.requiresOpenaiAuth = result.requiresOpenaiAuth;
    this.account = result.account ? { type: result.account.type,
      email: result.account.email || '', planType: result.account.planType || '' } : null;
    return this.account;
  }
  connectionAddresses() {
    return [...new Set([...this.tailscale.status().addresses, ...lanAddresses()])];
  }
  status() {
    const config = this.settings.publicValue();
    const addresses = this.connectionAddresses();
    const origins = config.networkMode === 'public' ? [config.publicOrigin].filter(Boolean) :
      (config.host === '127.0.0.1' ? ['127.0.0.1'] : addresses).map(ip => `https://${ip}:${config.port}`);
    return { version: VERSION, state: this.state, listening: this.server?.listening === true, lastError: this.lastError, account: this.account,
      runtimeError: this.runtimeError, codexExecutable: this.rpc?.closed ? '' : this.rpc?.command || '',
      ...(process.platform === 'darwin' ? { codexHome: path.resolve((this.rpc?.environment || process.env).CODEX_HOME ||
        path.join(os.homedir(), '.codex')) } : {}),
      hasCustomCodex: !!this.settings.value.codexExecutable,
      login: this.lastLogin || null, config, origins, devices: this.pairing.list(),
      fingerprint: this.certificates?.fingerprint || '', tasks: this.core?.list() || [],
      dataDirectory: this.settings.directory, launcher: this.layout.launcher,
      ...(this.tailscale.enabled ? { network: { tailscale: this.tailscale.status() } } : {}) };
  }
  configure(body) {
    if (this.server || this.state === 'starting') throw new Error('请先停止手机连接服务，再修改项目或网络配置。');
    this.settings.update(body); return this.status();
  }
  async selectCodexExecutable(filename) {
    if (this.server || ['running', 'starting'].includes(this.state)) throw new Error('请先停止手机连接服务，再切换 Codex。');
    if (this.runtimeSetup) throw new Error('正在连接 Codex，请稍候。');
    if (typeof filename !== 'string') throw new Error('无效的 Codex 程序路径。');
    const executable = filename ? resolveCodexSelection(filename, this.layout.base) : '';
    this.settings.setCodexExecutable(executable);

    const previous = this.rpc;
    this.rpc = null;
    if (this.core) { this.core.close(); this.core = null; }
    else previous?.close();
    this.loginId = null;
    this.lastLogin = null;
    await this.ensureRuntime();
    if (!this.server && this.state === 'error' && !this.runtimeError) {
      this.state = 'stopped'; this.lastError = '';
    }
    return this.status();
  }
  async login(type = 'chatgpt') {
    if (!['chatgpt', 'chatgptDeviceCode'].includes(type)) throw new Error('无效的登录方式。');
    if (!await this.ensureRuntime()) throw new Error(this.runtimeError);
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
    if (!await this.ensureRuntime()) throw new Error(this.runtimeError);
    await this.rpc.request('account/logout'); await this.readAccount(); return this.status();
  }
  async start() {
    if (this.state === 'starting') throw new Error('服务正在启动，请稍候。');
    if (this.state === 'stopping') throw new Error('服务正在停止，请稍候。');
    if (this.state === 'running' && this.server?.listening && this.core?.ready && this.rpc && !this.rpc.closed) {
      return this.status();
    }
    if (this.server) this.requireIdle();
    this.state = 'starting'; this.lastError = '';
    try {
      if (this.server) {
        if (this.core) this.core.ready = false;
        this.pairing.cancel();
        await this.closeServer(true);
      }
      if (this.core) { this.rpc = null; this.core.close(); this.core = null; }
      if (!await this.ensureRuntime()) throw new Error(this.runtimeError);
      await this.readAccount();
      if (!this.account && this.requiresOpenaiAuth !== false) throw new Error('请先登录 Codex。');
      const config = this.settings.value;
      if (!config.workspaces.length) throw new Error('请先选择至少一个项目文件夹。');
      await this.tailscale.refresh({ force: true });
      this.certificates = config.networkMode === 'lan' ? ensureCertificates(this.settings.directory, this.connectionAddresses(), this.layout.launcher) :
        { cert: config.certFile, key: config.keyFile, caCertificate: '', fingerprint: '' };
      const bridgeConfig = { ...config, stateDir: path.join(this.settings.directory, 'tasks'), tls: this.certificates,
        desktopCoordination: true };
      this.core = new BridgeCore(bridgeConfig, this.rpc);
      await this.core.initialize({ initializeRpc: false });
      const server = createBridgeServer(bridgeConfig, this.core, { pairing: this.pairing });
      this.server = server;
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(config.port, config.host, () => { server.off('error', reject); resolve(); });
      });
      if (!this.core.ready || this.rpc.closed) throw new Error(this.runtimeError || '本机 Codex 尚未就绪。');
      this.state = 'running';
      server.on('error', () => {
        if (this.server !== server || this.state !== 'running') return;
        this.core.ready = false;
        this.state = 'error'; this.lastError = '连接服务异常，请重新启动手机连接。';
      });
      return this.status();
    } catch (error) {
      if (this.core) this.core.ready = false;
      await this.closeServer(true);
      this.state = 'error'; this.lastError = error.message;
      throw new Error('启动失败：' + error.message);
    }
  }
  requireIdle() {
    if (this.core?.locks.size || this.core?.list().some(task => ['running', 'starting', 'waitingApproval', 'stopping', 'releasing'].includes(task.status))) {
      throw new Error('仍有任务在运行或等待审批。请先在手机中停止这些任务，再停止服务。');
    }
  }
  async closeServer(force = false) {
    const server = this.server;
    if (!server) return;
    await new Promise(resolve => {
      server.close(resolve);
      if (force) server.closeAllConnections();
      else server.closeIdleConnections();
    });
    if (this.server === server) this.server = null;
  }
  async stop() {
    if (this.state === 'starting' || this.state === 'stopping') throw new Error('连接服务正在切换状态，请稍候。');
    this.requireIdle();
    this.state = 'stopping';
    if (this.core) this.core.ready = false;
    this.pairing.cancel();
    await this.closeServer();
    this.state = 'stopped'; return this.status();
  }
  async createPairing(origin) {
    if (this.state !== 'running') throw new Error('请先启动手机连接服务。');
    await this.tailscale.refresh({ force: true });
    if (this.state !== 'running' || !this.server) throw new Error('手机连接服务已停止，请重新启动后配对。');
    if (!this.status().origins.includes(origin)) throw new Error('请选择本机当前可用的连接地址。');
    if (this.settings.value.networkMode === 'lan') {
      this.certificates = ensureCertificates(this.settings.directory, this.connectionAddresses(), this.layout.launcher);
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
    if (this.updatePreparing && !['status', 'cancelUpdate'].includes(method)) throw new Error('正在准备安装更新，请稍候');
    switch (method) {
      case 'status': if (!this.runtimeSetup) await this.readAccount(); await this.tailscale.refresh(); return this.status();
      case 'configure': return this.configure(body);
      case 'selectCodexExecutable': return this.selectCodexExecutable(body.filename);
      case 'login': return this.login(body.type);
      case 'cancelLogin': await this.cancelLogin(); return this.status();
      case 'logout': return this.logout();
      case 'start': return this.start();
      case 'stop': return this.stop();
      case 'pair': return this.createPairing(body.origin);
      case 'revoke': this.pairing.revoke(body.id); return this.status();
      case 'interrupt': if (!this.core) throw new Error('没有活动任务。'); await this.core.interrupt(body.id); return this.status();
      case 'prepareUpdate': {
        if (this.core?.locks.size || this.core?.list().some(task => ['starting', 'running', 'waitingApproval', 'stopping', 'releasing', 'unknown'].includes(task.status))) {
          throw new Error('还有任务正在执行或状态未确认，请等待完成后再更新');
        }
        this.updateWasRunning = this.state === 'running'; this.updatePreparing = true;
        try { await this.stop(); return { wasRunning: this.updateWasRunning }; }
        catch (error) { this.updatePreparing = false; throw error; }
      }
      case 'cancelUpdate': {
        const restart = this.updatePreparing && this.updateWasRunning; this.updatePreparing = false;
        if (restart) await this.start(); return this.status();
      }
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
    const executors = [this.rpc, ...[...(this.core?.sharedSessions.entries.values() || [])].map(entry => entry.rpc)].filter(Boolean);
    const rpc = this.rpc;
    this.rpc = null;
    try { if (this.core) this.core.close(); else rpc?.close(); }
    finally { await Promise.all(executors.map(rpc => rpc.shutdown?.())); }
  }
}
