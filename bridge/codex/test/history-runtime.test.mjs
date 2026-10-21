// Opt-in check of the actual bundled protocol. Uses a separate CODEX_HOME and a
// loopback provider that rejects every request; no real account/model is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { CodexRpc } from '../rpc.mjs';
import { BridgeCore } from '../core.mjs';

test('bundled Codex reads legacy/paginated local history and forks without executing the source', {
  skip: !process.env.CLAWMATE_TEST_CODEX, timeout: 45000
}, async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-native-history-'));
  const home = path.join(directory, 'home'); const cwd = path.join(directory, 'project');
  mkdirSync(home); mkdirSync(cwd);
  let rejectedInference = 0;
  const server = http.createServer((request, response) => {
    rejectedInference++; request.resume(); response.writeHead(400, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ error: { message: 'Offline fixture: inference disabled', type: 'invalid_request_error' } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  writeFileSync(path.join(home, 'config.toml'), 'model="test-model"\nmodel_provider="offline_test"\n' +
    '[model_providers.offline_test]\nname="Offline test"\nbase_url="http://127.0.0.1:' + server.address().port + '/v1"\nwire_api="responses"\n');
  const rpc = new CodexRpc(process.env.CLAWMATE_TEST_CODEX, undefined, { env: {
    ...process.env, CODEX_HOME: home, OPENAI_API_KEY: '', CHATGPT_API_KEY: ''
  } });
  const core = new BridgeCore({ stateDir: path.join(directory, 'state'), workspaces: [{ id: 'project', name: 'Fixture', path: cwd }] }, rpc);
  t.after(async () => {
    const stopped = rpc.child.exitCode === null ? once(rpc.child, 'exit') : Promise.resolve();
    core.close(); await stopped; server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  });
  // Experimental opt-in is only for creating legacy fixtures on a modern runtime.
  await rpc.request('initialize', { clientInfo: { name: 'clawmate_history_fixture', version: '1.0.0' }, capabilities: { experimentalApi: true } });
  rpc.send({ method: 'initialized', params: {} });
  core.models = [{ model: 'test-model', defaultReasoningEffort: '', supportedReasoningEfforts: [] }]; core.ready = true;
  for (const historyMode of ['paginated', 'legacy']) {
    const created = await rpc.request('thread/start', { cwd, model: 'test-model', historyMode, sandbox: 'read-only', approvalPolicy: 'on-request' });
    const id = created.thread.id;
    await rpc.request('thread/name/set', { threadId: id, name: 'Isolated ' + historyMode });
    for (let index = 0; index < 3; index++) {
      const completed = new Promise(resolve => {
        const listener = message => { if (message.method === 'turn/completed' && message.params.threadId === id) {
          rpc.off('message', listener); resolve(message.params.turn);
        } }; rpc.on('message', listener);
      });
      await rpc.request('turn/start', { threadId: id, input: [{ type: 'text', text: historyMode + '-fixture-' + index }] });
      assert.equal((await completed).status, 'failed');
    }
    const listed = await core.history.list(); assert.ok(listed.threads.some(item => item.id === id));
    const preview = await core.history.read(id); assert.ok(preview.items.some(item => item.text === historyMode + '-fixture-2'));
    if (historyMode === 'legacy') {
      assert.ok(preview.historyCursor.startsWith('turns:'));
      const older = await core.history.read(id, preview.historyCursor);
      assert.ok(older.items.some(item => item.text === 'legacy-fixture-0'));
    } else {
      const page = await rpc.request('thread/items/list', { threadId: id, limit: 1, sortDirection: 'desc' });
      assert.ok(page.nextCursor);
      const older = await core.history.read(id, 'items:' + page.nextCursor);
      assert.ok(older.items.some(item => item.text === 'paginated-fixture-0'));
    }
    const before = rejectedInference;
    const task = await core.history.fork(id, { requestId: randomUUID(), workspaceId: 'project', model: 'test-model', effort: '', mode: 'read-only' });
    assert.notEqual(task.id, id); assert.equal(task.error, '');
    assert.ok(task.items.some(item => item.text === historyMode + '-fixture-2'));
    assert.equal(rejectedInference, before, 'reading and forking do not start another turn');
  }
});
