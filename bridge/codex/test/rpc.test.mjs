import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { CodexRpc } from '../rpc.mjs';
import { BridgeCore } from '../core.mjs';

const fixture = fileURLToPath(new URL('./fake-app-server.mjs', import.meta.url));
test('real subprocess stdio lifecycle carries requests, deltas and terminal state', async t => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-rpc-test-'));
  mkdirSync(path.join(dir, 'project'));
  const rpc = new CodexRpc(process.execPath, [fixture]);
  const core = new BridgeCore({ stateDir: path.join(dir, 'state'), workspaces: [{ id: 'p', name: 'Project', path: path.join(dir, 'project') }] }, rpc);
  t.after(() => { core.close(); rmSync(dir, { recursive: true, force: true }); });
  await core.initialize();
  const task = await core.create({ workspaceId: 'p', model: 'fixture', effort: 'medium', mode: 'read-only' });
  const completed = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Completion not received')), 3000);
    rpc.on('message', m => {
      if (m.method === 'turn/completed') { clearTimeout(timer); resolve(); }
    });
  });
  await core.start(task.id, { requestId: 'request-1234567890', text: 'hello', attachments: [], model: 'fixture', effort: 'medium' });
  await completed;
  assert.equal(task.status, 'completed');
  assert.equal(task.items.find(i => i.kind === 'assistant').text, '测试成功');
  await assert.rejects(rpc.request('fixture/unsupported'), /Unknown fixture method/);
});

test('subprocess exit rejects outstanding requests rather than hanging', async t => {
  const rpc = new CodexRpc(process.execPath, [fixture]); t.after(() => rpc.close());
  await rpc.initialize();
  await assert.rejects(rpc.request('fixture/exit'), /process stopped/);
  assert.equal(rpc.pending.size, 0);
});
