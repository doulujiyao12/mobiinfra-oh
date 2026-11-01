import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { lstatSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';

// Versioned desktop/IDE coordination protocol, observed in desktop 26.1013.4894.
// This is not the public app-server JSONL protocol. Never impersonate a desktop
// client, start its router, expose it remotely, or offer arbitrary method forwarding.
export const DESKTOP_VERSIONS = Object.freeze({
  'thread-owner-discovery': 1, 'thread-follower-start-turn': 2,
  'thread-follower-interrupt-turn': 4, 'thread-follower-command-approval-decision': 1,
  'thread-follower-file-approval-decision': 1, 'thread-follower-submit-user-input': 1
});
export const desktopUnavailable = error => ['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code);
export function desktopEndpoint(env = process.env, platform = process.platform) {
  if (platform === 'win32') return '\\\\.\\pipe\\codex-ipc';
  const home = path.resolve(env.CODEX_HOME || path.join(os.homedir(), '.codex'));
  const folder = path.join(home, 'ipc'); const filename = path.join(folder, 'ipc.sock');
  const directory = lstatSync(folder); const socket = lstatSync(filename);
  if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid() ||
      (directory.mode & 0o022) || !socket.isSocket() || socket.uid !== process.getuid() || (socket.mode & 0o077)) {
    throw new Error('Codex 本地协调通道的所有者或权限不安全');
  }
  return filename;
}
const limit = 16 * 1024 * 1024;
export class DesktopIpc extends EventEmitter {
  pending = new Map(); clientId = ''; socket = null; connecting = null;
  constructor(options = {}) { super(); this.options = options; }
  connect() {
    if (this.clientId && this.socket && !this.socket.destroyed) return Promise.resolve();
    if (this.connecting) return this.connecting;
    this.connecting = this.open().finally(() => { this.connecting = null; });
    return this.connecting;
  }
  async open() {
    const endpoint = this.options.endpoint || desktopEndpoint();
    const socket = (this.options.connect || net.createConnection)(endpoint); this.socket = socket;
    let buffer = Buffer.alloc(0);
    const retire = error => {
      // A delayed close from the old socket must not clear a reconnected client.
      if (this.socket !== socket) return;
      this.socket = null; this.fail(error); socket.destroy();
    };
    socket.on('data', chunk => {
      if (this.socket !== socket) return;
      buffer = Buffer.concat([buffer, chunk]);
      try {
        while (buffer.length >= 4) {
          const length = buffer.readUInt32LE(0);
          if (!length || length > limit) throw new Error('Codex 协调消息长度超出安全限制');
          if (buffer.length < length + 4) break;
          const message = JSON.parse(buffer.subarray(4, length + 4).toString('utf8'));
          buffer = buffer.subarray(length + 4); this.receive(message);
        }
      } catch (error) { socket.destroy(error); }
    });
    socket.on('error', retire);
    socket.on('close', () => { buffer = Buffer.alloc(0); retire(new Error('Codex 桌面连接已断开，请刷新后确认本轮是否已经执行')); });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { cleanup(); socket.destroy(); reject(new Error('Codex 桌面连接超时')); }, 5000);
      const cleanup = () => { clearTimeout(timer); socket.off('connect', connected); socket.off('error', failed); socket.off('close', closed); };
      const connected = () => { cleanup(); resolve(); }; const failed = error => { cleanup(); reject(error); };
      const closed = () => failed(new Error('Codex 桌面连接在握手前关闭'));
      socket.once('connect', connected); socket.once('error', failed); socket.once('close', closed);
    });
    try {
      if (this.socket !== socket || socket.destroyed) throw new Error('Codex 桌面连接已关闭');
      const result = await this.call('initialize', { clientType: 'clawmate' }, 0);
      if (typeof result.result?.clientId !== 'string' || !result.result.clientId) throw new Error('Codex 桌面协调握手不兼容');
      if (this.socket !== socket || socket.destroyed) throw new Error('Codex 桌面连接已关闭');
      this.clientId = result.result.clientId;
    } catch (error) { socket.destroy(); throw error; }
  }
  receive(message) {
    if (message.type === 'response') {
      const entry = this.pending.get(message.requestId); if (!entry) return;
      this.pending.delete(message.requestId); clearTimeout(entry.timer);
      if (message.resultType !== 'success') entry.reject(Object.assign(new Error(message.error || 'Codex 桌面请求失败'), { desktopCode: message.error }));
      else if (entry.owner && message.handledByClientId !== entry.owner) entry.reject(new Error('Codex 会话持有者已改变，已停止本次操作'));
      else if (message.method !== entry.method) entry.reject(new Error('Codex 桌面响应协议不匹配'));
      else entry.resolve(message);
    } else if (message.type === 'client-discovery-request') {
      this.write({ type: 'client-discovery-response', requestId: message.requestId, response: { canHandle: false } });
    } else if (message.type === 'request') {
      this.write({ type: 'response', requestId: message.requestId, resultType: 'error', error: 'ClawMate does not own desktop threads' });
    } else if (message.type === 'broadcast' && (!message.targetClientIds || message.targetClientIds.includes(this.clientId)) &&
        ['thread-stream-state-changed', 'thread-stream-following-status-requested', 'client-status-changed', 'ipc-connection-reset'].includes(message.method)) {
      this.emit('broadcast', message);
    }
  }
  write(message) {
    if (!this.socket || this.socket.destroyed) throw new Error('Codex 桌面通道未连接');
    const bytes = Buffer.from(JSON.stringify(message)); if (bytes.length > limit) throw new Error('Codex 协调消息过大');
    const header = Buffer.alloc(4); header.writeUInt32LE(bytes.length); this.socket.write(Buffer.concat([header, bytes]));
  }
  call(method, params, version, owner) {
    if (this.pending.size >= 32) return Promise.reject(new Error('Codex 桌面请求过多，请稍后重试'));
    const requestId = randomUUID();
    return new Promise((resolve, reject) => {
      const fail = error => reject(Object.assign(error, { outcomeUnknown: method !== 'initialize' && method !== 'thread-owner-discovery' }));
      const timeout = method === 'initialize' || method === 'thread-owner-discovery' ? 5000 : 45000;
      const timer = setTimeout(() => { this.pending.delete(requestId); fail(new Error('Codex 桌面请求超时，请确认本轮状态后再试')); }, timeout);
      this.pending.set(requestId, { resolve, reject: fail, timer, owner, method });
      try { this.write({ type: 'request', requestId, sourceClientId: this.clientId, version, method, params, targetClientId: owner, timeoutMs: timeout - 500 }); }
      catch (error) { clearTimeout(timer); this.pending.delete(requestId); reject(error); }
    });
  }
  async request(method, params, owner) {
    if (!Object.hasOwn(DESKTOP_VERSIONS, method)) throw new Error('ClawMate 不支持此桌面操作');
    await this.connect(); return this.call(method, params, DESKTOP_VERSIONS[method], owner);
  }
  async owner(id) {
    try { const response = await this.request('thread-owner-discovery', { hostId: 'local', conversationId: id }); return response.handledByClientId; }
    catch (error) { if (desktopUnavailable(error) || error.desktopCode === 'no-client-found') return null; throw error; }
  }
  follow(id, owner, following) {
    this.write({ type: 'broadcast', sourceClientId: this.clientId, targetClientIds: [owner],
      method: 'thread-stream-following-changed', version: 1, params: { hostId: 'local', conversationId: id, following } });
  }
  fail(error) {
    const active = !!this.clientId; this.clientId = '';
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    this.pending.clear(); if (active) this.emit('disconnected', error);
  }
  close() { const socket = this.socket; this.socket = null; socket?.destroy(); this.fail(new Error('ClawMate 已断开桌面协调通道')); }
}
