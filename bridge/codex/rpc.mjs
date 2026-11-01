import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { readContext, cancelledRead } from './read-coordinator.mjs';

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
    const lines = createInterface({ input: this.child.stdout });
    lines.on('line', line => {
      if (line.length > 16 * 1024 * 1024) return this.child.kill();
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
    });
    this.child.stdin.on('error', () => this.fail());
    this.child.on('error', () => this.fail());
    this.child.on('exit', () => this.fail());
  }

  fail() {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.cleanup?.();
      p.reject(new Error('Codex process stopped; restart the bridge'));
    }
    this.pending.clear();
    this.emit('stopped');
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
      this.pending.set(id, { resolve, reject, timer, cleanup }); signal?.addEventListener('abort', abort, { once: true });
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

  close() { this.child.kill(); this.fail(); }
}
