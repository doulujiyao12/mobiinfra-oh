import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';

// Only stdio is used. No unauthenticated Codex listener is opened.
export class CodexRpc extends EventEmitter {
  pending = new Map();
  sequence = 0;
  closed = false;

  constructor(command = 'codex', args = ['app-server', '--listen', 'stdio://']) {
    super();
    this.child = spawn(command, args, { shell: false, windowsHide: true,
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
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex ${method} timed out; inspect task state before retrying`));
      }, 45000);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ id, method, params });
    });
  }

  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'clawmate_harmony', title: 'ClawMate', version: '1.0.0' },
      capabilities: { experimentalApi: false }
    });
    this.send({ method: 'initialized', params: {} });
  }

  close() { this.child.kill(); this.fail(); }
}
