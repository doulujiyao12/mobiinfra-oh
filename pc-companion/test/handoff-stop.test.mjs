import test from 'node:test';
import assert from 'node:assert/strict';
import { CompanionManager } from '../host/manager.mjs';

test('daemon shutdown refuses a handoff that is still releasing its native writer lock', async () => {
  let cancelled = false;
  const manager = { core: { ready: true, locks: new Set(), list: () => [{ status: 'releasing' }] },
    pairing: { cancel: () => { cancelled = true; } }, server: null, state: 'running' };
  await assert.rejects(CompanionManager.prototype.stop.call(manager), /仍有任务/);
  assert.equal(manager.core.ready, true); assert.equal(manager.state, 'running'); assert.equal(cancelled, false);
  manager.core.list = () => [{ status: 'completed' }]; manager.status = () => ({ state: manager.state });
  assert.equal((await CompanionManager.prototype.stop.call(manager)).state, 'stopped');
  assert.equal(cancelled, true);
});

test('closing waits for all owned Codex executors before releasing the daemon', async () => {
  const calls = []; let finish;
  const shared = { close: () => calls.push('shared-close'), shutdown: async () => { calls.push('shared-exited'); } };
  const main = { shutdown: () => new Promise(resolve => { calls.push('main-wait'); finish = resolve; }) };
  const manager = { pairing: { cancel: () => calls.push('cancel') }, server: null, rpc: main,
    core: { sharedSessions: { entries: new Map([['task', { rpc: shared }]]) }, close: () => { shared.close(); calls.push('core-close'); } } };
  let done = false; const closing = CompanionManager.prototype.close.call(manager).then(() => { done = true; });
  await Promise.resolve(); assert.equal(done, false); assert.ok(calls.includes('shared-exited'));
  finish(); await closing; assert.equal(done, true);
});
