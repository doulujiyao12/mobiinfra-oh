import { EventEmitter } from 'node:events';
import net from 'node:net';
import WebSocket from 'ws';
import { readContext, cancelledRead } from './read-coordinator.mjs';

// A client of an existing App Server. This transport never starts, updates or
// terminates Codex; closing ClawMate only closes its own WebSocket connection.
export class DaemonRpc extends EventEmitter {
  pending = new Map(); sequence = 0; closed = false;
  constructor(socketPath, { timeout = 15000 } = {}) {
    super(); this.timeout = timeout;
    this.socket = new WebSocket('ws://localhost/', {
      createConnection: () => net.connect({ path: socketPath }),
      handshakeTimeout: 5000, perMessageDeflate: false, maxPayload: 16 * 1024 * 1024,
      followRedirects: false
    });
    this.opened = new Promise((resolve, reject) => {
      this.socket.once('open', resolve);
      this.socket.once('error', () => reject(new Error('无法连接本机 Codex daemon')));
      this.socket.once('close', () => reject(new Error('Codex daemon 连接已关闭')));
    });
    this.opened.catch(() => {});
    this.socket.on('error', () => this.fail());
    this.socket.on('close', () => this.fail());
    this.socket.on('message', (bytes, binary) => {
      let message;
      try { if (binary) throw new Error(); message = JSON.parse(bytes.toString()); }
      catch { this.close(); return; }
      if (!message || typeof message !== 'object' || Array.isArray(message)) { this.close(); return; }
      if (!message.method && message.id !== undefined) {
        const pending = this.pending.get(message.id); if (!pending) return;
        this.pending.delete(message.id); clearTimeout(pending.timer);
        pending.cleanup?.();
        if (message.error) {
          const error = new Error(message.error.message || 'Codex daemon RPC failed');
          error.rpcCode = message.error.code; pending.reject(error);
        } else pending.resolve(message.result);
      } else this.emit('message', message);
    });
  }
  fail() {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.cleanup?.();
      const error = new Error('Codex daemon 连接已断开，请刷新状态后再发送');
      error.outcomeUnknown = pending.method === 'turn/start'; pending.reject(error);
    }
    this.pending.clear(); this.emit('stopped');
  }
  send(message) {
    if (this.closed || this.socket.readyState !== WebSocket.OPEN) throw new Error('Codex daemon 未连接');
    this.socket.send(JSON.stringify(message));
  }
  async request(method, params = {}) {
    const signal = readContext.getStore()?.signal;
    if (signal?.aborted) throw cancelledRead();
    await this.opened;
    if (signal?.aborted) throw cancelledRead();
    if (this.closed) throw new Error('Codex daemon 未连接');
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        cleanup();
        const error = new Error(`Codex daemon ${method} timed out; refresh before retrying`);
        error.outcomeUnknown = method === 'turn/start'; reject(error);
      }, this.timeout);
      const abort = () => { clearTimeout(timer); this.pending.delete(id); cleanup(); reject(cancelledRead()); };
      const cleanup = () => signal?.removeEventListener('abort', abort);
      this.pending.set(id, { resolve, reject, timer, method, cleanup }); signal?.addEventListener('abort', abort, { once: true });
      try { this.send({ id, method, params }); }
      catch (error) { this.pending.delete(id); clearTimeout(timer); cleanup(); reject(error); }
    });
  }
  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'clawmate_harmony', title: 'ClawMate', version: '1.1.13' },
      capabilities: { experimentalApi: false }
    });
    this.send({ method: 'initialized', params: {} });
  }
  close() { this.fail(); this.socket.terminate(); }
}
