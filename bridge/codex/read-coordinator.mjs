import { AsyncLocalStorage } from 'node:async_hooks';
import { BridgeError } from './errors.mjs';

// Propagate a single read budget through nested native RPCs. It never encloses
// turn/start, approvals or stop, and never kills a shared Codex process.
export const readContext = new AsyncLocalStorage();
export class ReadCoordinator {
  entries = new Map();
  constructor({ timeout = 20000, cooldown = 2000, limit = 16 } = {}) {
    this.timeout = timeout; this.cooldown = cooldown; this.limit = limit;
  }
  run(key, operation) {
    const prior = this.entries.get(key);
    if (prior) return prior.promise;
    if (this.entries.size >= this.limit) return Promise.reject(new BridgeError(429, '读取请求较多，请稍后重试'));
    const controller = new AbortController(); let timer;
    const entry = { controller };
    const deadline = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        reject(new BridgeError(504, '电脑读取会话超时，请稍后重试；本次没有下发任务'));
        controller.abort();
      }, this.timeout);
    });
    const work = readContext.run({ signal: controller.signal }, () => Promise.resolve().then(operation));
    entry.promise = Promise.race([work, deadline]).then(result => {
      clearTimeout(timer); if (this.entries.get(key) === entry) this.entries.delete(key); return result;
    }, error => {
      clearTimeout(timer);
      const release = setTimeout(() => { if (this.entries.get(key) === entry) this.entries.delete(key); }, this.cooldown);
      release.unref?.(); throw error;
    });
    this.entries.set(key, entry); return entry.promise;
  }
}

export function cancelledRead() {
  const error = new Error('Codex read cancelled'); error.code = 'ABORT_ERR'; return error;
}
