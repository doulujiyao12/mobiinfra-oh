// Uses only isolated synthetic history and a provider that rejects inference.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { CodexRpc } from '../rpc.mjs';
import { BridgeCore } from '../core.mjs';

test('bundled runtime preserves one original session across PC/phone/PC handoffs and enforces native writer locks', {
  skip: !process.env.CLAWMATE_TEST_CODEX, timeout: 60000
}, async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-real-handoff-'));
  const home = path.join(directory, 'home'); const cwd = path.join(directory, 'project'); mkdirSync(home); mkdirSync(cwd);
  let requests = 0;
  let hold = false; const pending = [];
  const rejectInference = response => {
    response.writeHead(400, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ error: { message: 'Isolated fixture: no inference', type: 'invalid_request_error' } }));
  };
  const server = http.createServer((request, response) => {
    requests++; request.resume(); if (hold) pending.push(response); else rejectInference(response);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  writeFileSync(path.join(home, 'config.toml'), 'model="test-model"\nmodel_provider="fixture"\n' +
    '[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:' + server.address().port + '/v1"\nwire_api="responses"\n');
  const env = { ...process.env, CODEX_HOME: home, OPENAI_API_KEY: '', CHATGPT_API_KEY: '' };
  const clients = [];
  const create = () => { const rpc = new CodexRpc(process.env.CLAWMATE_TEST_CODEX, undefined, { env }); clients.push(rpc); return rpc; };
  const observer = create(); await observer.initialize();
  const core = new BridgeCore({ stateDir: path.join(directory, 'private'), workspaces: [{ id: 'project', name: 'Fixture', path: cwd }] }, observer);
  core.models = [{ model: 'test-model', supportedReasoningEfforts: [] }]; core.ready = true;
  t.after(async () => {
    for (const entry of [...core.sharedSessions.entries.values()]) await entry.rpc.shutdown();
    for (const rpc of clients) await rpc.shutdown();
    core.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  });
  const failedTurn = async (rpc, id, text) => {
    const done = new Promise(resolve => {
      const listener = message => { if (message.method === 'turn/completed' && message.params.threadId === id) {
        rpc.off('message', listener); resolve(message.params.turn);
      } }; rpc.on('message', listener);
    });
    await rpc.request('turn/start', { threadId: id, input: [{ type: 'text', text }] });
    assert.equal((await done).status, 'failed');
  };
  const finish = async task => {
    const deadline = Date.now() + 15000;
    while (core.sharedSessions.entries.has(task.id) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(core.sharedSessions.entries.has(task.id), false, 'executor exited and writer lock released');
    assert.equal(task.status, 'failed', 'synthetic provider rejects all model calls');
  };
  for (const historyMode of ['paginated', 'legacy']) {
    const pc = create();
    await pc.request('initialize', { clientInfo: { name: 'isolated_pc', version: '1' }, capabilities: { experimentalApi: true } });
    pc.send({ method: 'initialized', params: {} });
    const { thread } = await pc.request('thread/start', { cwd, model: 'test-model', historyMode,
      sandbox: 'read-only', approvalPolicy: 'on-request', approvalsReviewer: 'user' });
    await failedTurn(pc, thread.id, 'PC original ' + historyMode);
    const task = await core.history.resume(thread.id, { requestId: randomUUID(), workspaceId: 'project', model: 'test-model', effort: '', mode: 'read-only' });
    assert.equal(task.id, thread.id);
    const body = { requestId: randomUUID(), text: 'Phone continuation ' + historyMode, attachments: [], model: 'test-model', effort: '' };
    const before = requests;
    await assert.rejects(core.start(task.id, body), /电脑仍持有/);
    assert.equal(requests, before, 'occupied original receives no phone turn/model request');
    await pc.shutdown();
    await core.start(task.id, body); await finish(task);
    assert.equal(task.items[0].text, 'PC original ' + historyMode);
    const nextPc = create(); await nextPc.initialize();
    const resumed = await nextPc.request('thread/resume', { threadId: task.id, excludeTurns: true });
    assert.equal(resumed.thread.id, thread.id);
    const visible = await core.history.readPage(task.id);
    assert.ok(visible.items.some(item => item.text === body.text), 'phone input appears in persisted original: ' + JSON.stringify({ items: visible.items, error: task.error }));
    await failedTurn(nextPc, task.id, 'PC after phone ' + historyMode);
    await nextPc.shutdown();
    await core.snapshot(task.id);
    assert.ok(task.items.some(item => item.text === 'PC after phone ' + historyMode));
    await core.start(task.id, { ...body, requestId: randomUUID(), text: 'Phone second ' + historyMode });
    assert.ok(task.items.some(item => item.text === 'PC after phone ' + historyMode), 'fresh executor loads intervening desktop context');
    await finish(task);
    const persisted = await observer.request('thread/list', { cwd: [cwd], limit: 100 });
    assert.equal(persisted.data.filter(item => item.id === thread.id).length, 1);
    assert.ok(persisted.data.every(item => !item.forkedFromId), 'handoff creates no forks');
    for (const settings of [
      { mode: 'workspace-write', approvalMode: 'auto' }, { mode: 'danger-full-access', approvalMode: 'full' },
      { mode: 'workspace-write', approvalMode: 'ask' }
    ]) {
      hold = true;
      await core.start(task.id, { ...body, requestId: randomUUID(), ...settings });
      assert.equal(task.mode, settings.mode); assert.equal(task.approvalMode, settings.approvalMode);
      const executor = core.sharedSessions.rpc(task.id);
      const policy = await executor.request('thread/resume', { threadId: task.id, excludeTurns: true });
      assert.equal(policy.approvalsReviewer, settings.approvalMode === 'auto' ? 'auto_review' : 'user');
      assert.equal(policy.approvalPolicy, settings.approvalMode === 'full' ? 'never' : 'on-request');
      assert.equal(policy.sandbox.type, settings.approvalMode === 'full' ? 'dangerFullAccess' : 'workspaceWrite');
      hold = false; for (const response of pending.splice(0)) rejectInference(response); await finish(task);
    }
  }
});
