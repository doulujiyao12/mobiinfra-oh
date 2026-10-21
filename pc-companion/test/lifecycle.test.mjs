import test from 'node:test';
import assert from 'node:assert/strict';
import { DesktopLifecycle } from '../desktop/lifecycle.mjs';

function fixture(response = 1, tray = true) {
  const calls = []; let resolveShutdown;
  const controller = new DesktopLifecycle({ hasTray: () => tray,
    confirm: async options => { calls.push(options); return { response }; },
    hide: () => calls.push('hide'), show: () => calls.push('show'),
    shutdown: () => { calls.push('shutdown'); return new Promise(resolve => { resolveShutdown = resolve; }); },
    quit: () => calls.push('quit'), report: async error => calls.push(error.message) });
  return { controller, calls, finish: () => resolveShutdown() };
}
test('X offers hide or close; hide keeps the daemon and GUI alive', async () => {
  const f = fixture(0); await f.controller.requestClose();
  assert.deepEqual(f.calls[0].buttons, ['隐藏窗口', '关闭应用', '取消']);
  assert.deepEqual(f.calls.slice(1), ['hide']); assert.equal(f.controller.closing, false);
});
test('close blocks background IPC immediately and quits only after the daemon exits', async () => {
  const f = fixture(); const operation = f.controller.requestClose();
  assert.equal(f.controller.requestClose(), operation); await Promise.resolve();
  assert.equal(f.controller.closing, true); assert.equal(f.calls.includes('quit'), false);
  await f.controller.requestClose(); assert.equal(f.calls.filter(call => call === 'shutdown').length, 1);
  f.finish(); assert.equal(await operation, true); assert.equal(f.calls.at(-1), 'quit');
});
test('cancel preserves everything; tray close and systems without trays never offer GUI-only exit', async () => {
  const f = fixture(2); await f.controller.requestClose(); assert.equal(f.calls.length, 1);
  const g = fixture(1, false); await g.controller.requestClose();
  assert.deepEqual(g.calls[0].buttons, ['关闭应用', '取消']); assert.equal(g.calls.length, 1);
  const h = fixture(1); await h.controller.requestClose(false);
  assert.deepEqual(h.calls[0].buttons, ['关闭应用', '取消']); assert.equal(h.calls.length, 1);
});
test('shutdown failure preserves a visible usable window and reports the actual error', async () => {
  const f = fixture(); f.controller.actions.shutdown = async () => { throw new Error('daemon did not exit'); };
  assert.equal(await f.controller.requestClose(), false); assert.equal(f.controller.closing, false);
  assert.deepEqual(f.calls.slice(1), ['show', 'daemon did not exit']);
});
