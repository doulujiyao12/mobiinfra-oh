import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { BridgeError } from './errors.mjs';
import { readContext, cancelledRead } from './read-coordinator.mjs';

const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
export const RESPONSE_TOO_LARGE = 'CODEX_RESPONSE_TOO_LARGE';

function readFrames(stream, onFrame, onOversized) {
  let chunks = []; let size = 0; let header = Buffer.alloc(0); let dropping = false;
  stream.on('data', packet => {
    for (let start = 0; start < packet.length;) {
      const newline = packet.indexOf(10, start);
      const end = newline < 0 ? packet.length : newline;
      const chunk = packet.subarray(start, end);
      if (!dropping && chunk.length) {
        if (header.length < 256) header = Buffer.concat([header, chunk.subarray(0, 256 - header.length)]);
        if (size + chunk.length > MAX_RESPONSE_BYTES) {
          chunks = []; dropping = true; onOversized(header.toString('utf8'));
        } else { chunks.push(chunk); size += chunk.length; }
      }
      if (newline < 0) break;
      if (!dropping && size) onFrame(Buffer.concat(chunks, size).toString('utf8'));
      chunks = []; size = 0; header = Buffer.alloc(0); dropping = false;
      start = end + 1;
    }
  });
}

// Only stdio is used. No unauthenticated Codex listener is opened.
export class CodexRpc extends EventEmitter {
  pending = new Map();
  sequence = 0;
  closed = false;

  constructor(command = 'codex', args = ['app-server', '--listen', 'stdio://'], options = {}) {
    super();
    this.command = command; this.args = args; this.environment = { ...(options.env || process.env) };
    this.child = spawn(command, args, { env: options.env || process.env, shell: false, windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'] });
    // Do not forward stderr: it may contain paths, prompts or credentials.
    this.child.stderr.resume();
    readFrames(this.child.stdout, line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (!message.method && message.id !== undefined) {
        const request = this.pending.get(message.id);
        if (!request) return;
        clearTimeout(request.timer);
        request.cleanup?.();
        this.pending.delete(message.id);
        if (message.error) request.reject(new Error(message.error.message || 'Codex RPC failed'));
        else request.resolve(message.result);
      } else this.emit('message', message);
    }, prefix => this.rejectOversized(prefix));
    this.child.stdin.on('error', error => this.fail(`stdin ${error.code || 'error'}`));
    this.child.on('error', error => this.fail(`process ${error.code || 'error'}`));
    this.child.on('exit', (code, signal) => this.fail(signal ? `signal ${signal}` : `exit code ${code}`));
  }

  rejectOversized(prefix) {
    // Codex replies start with the numeric request ID. An uncorrelated frame
    // may be a notification and must never cancel another request.
    const match = /^\s*\{\s*(?:"jsonrpc"\s*:\s*"2\.0"\s*,\s*)?"id"\s*:\s*(\d+)\s*,\s*"(?:result|error)"\s*:/.exec(prefix);
    const id = match ? Number(match[1]) : NaN;
    const request = this.pending.get(id);
    this.emit('oversized', request?.method || 'unmatched frame');
    if (!request) return;
    clearTimeout(request.timer);
    request.cleanup?.();
    this.pending.delete(id);
    const error = new BridgeError(413, 'Codex 返回的单条数据过大，请在电脑端查看。');
    error.code = RESPONSE_TOO_LARGE;
    if (request.method === 'turn/start') {
      error.outcomeUnknown = true;
      error.message = 'Codex 返回的数据过大，无法确认任务状态。请先在电脑端检查。';
    }
    request.reject(error);
  }

  fail(reason) {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.cleanup?.();
      p.reject(new Error('Codex process stopped; restart the bridge'));
    }
    this.pending.clear();
    this.emit('stopped', reason);
  }

  send(message) {
    if (this.closed) throw new Error('Codex process is unavailable');
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params = {}) {
    if (this.closed) return Promise.reject(new Error('Codex process is unavailable'));
    const signal = readContext.getStore()?.signal;
    if (signal?.aborted) return Promise.reject(cancelledRead());
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        cleanup();
        reject(new Error(`Codex ${method} timed out; inspect task state before retrying`));
      }, 45000);
      const abort = () => { clearTimeout(timer); this.pending.delete(id); cleanup(); reject(cancelledRead()); };
      const cleanup = () => signal?.removeEventListener('abort', abort);
      this.pending.set(id, { method, resolve, reject, timer, cleanup }); signal?.addEventListener('abort', abort, { once: true });
      try { this.send({ id, method, params }); } catch (error) { clearTimeout(timer); this.pending.delete(id); cleanup(); reject(error); }
    });
  }

  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'clawmate_harmony', title: 'ClawMate', version: '1.0.0' },
      capabilities: { experimentalApi: false }
    });
    this.send({ method: 'initialized', params: {} });
  }

  // A handoff gets a fresh executor so PC-written history is never hidden by a
  // previously loaded in-memory thread. Credentials remain in the local runtime.
  createPeer() { return new CodexRpc(this.command, this.args, { env: this.environment }); }

  async shutdown() {
    if (!this.child.pid || this.child.exitCode !== null || this.child.signalCode !== null) return;
    await new Promise((resolve, reject) => {
      let forceTimer; let deadline;
      const exited = () => { clearTimeout(forceTimer); clearTimeout(deadline); resolve(); };
      this.child.once('exit', exited);
      forceTimer = setTimeout(() => { this.child.kill(); }, 5000);
      deadline = setTimeout(() => {
        this.child.off('exit', exited); reject(new Error('Codex executor did not exit; restart the bridge'));
      }, 10000);
      this.child.stdin.end();
    });
  }

  close() { this.child.kill(); this.fail('closed by bridge'); }
}
