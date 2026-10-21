// Observe the real pinned runtime's first retry notification using a broken
// local SSE fixture. No user history, account or real inference is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { CodexRpc } from '../rpc.mjs';
import { BridgeCore } from '../core.mjs';

test('first real Codex retry notification immediately becomes phone-visible progress', {
  skip: !process.env.CLAWMATE_TEST_CODEX, timeout: 20000
}, async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-retry-'));
  const home = path.join(directory, 'home'); const cwd = path.join(directory, 'project'); mkdirSync(home); mkdirSync(cwd);
  let requests = 0;
  const server = http.createServer((request, response) => {
    request.resume(); requests++;
    if (requests === 1) {
      response.writeHead(200, { 'Content-Type': 'text/event-stream' });
      response.end('event: response.created\ndata: {"type":"response.created","response":{"id":"isolated_fixture","status":"in_progress"}}\n\n');
    } else {
      response.writeHead(400, { 'Content-Type': 'application/json' });
      response.end('{"error":{"message":"Fixture ended; no inference","type":"invalid_request_error"}}');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  writeFileSync(path.join(home, 'config.toml'), 'model="test-model"\nmodel_provider="fixture"\n' +
    '[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:' + server.address().port +
    '/v1"\nwire_api="responses"\nrequest_max_retries=0\nstream_max_retries=2\n');
  const rpc = new CodexRpc(process.env.CLAWMATE_TEST_CODEX, undefined, { env: { ...process.env,
    CODEX_HOME: home, OPENAI_API_KEY: '', CHATGPT_API_KEY: '' } });
  const core = new BridgeCore({ stateDir: path.join(directory, 'private'), workspaces: [{ id: 'project', name: 'Fixture', path: cwd }] }, rpc);
  t.after(async () => {
    await rpc.shutdown(); core.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  });
  await rpc.initialize(); core.models = [{ model: 'test-model', supportedReasoningEfforts: [] }]; core.ready = true;
  const task = await core.create({ workspaceId: 'project', model: 'test-model', effort: '' });
  const notices = [];
  rpc.on('message', message => {
    if (message.method === 'error' && message.params.threadId === task.id && message.params.willRetry) {
      notices.push({ progress: { ...task.progress }, error: task.error, status: task.status });
    }
  });
  const completed = new Promise(resolve => {
    const listener = message => { if (message.method === 'turn/completed' && message.params.threadId === task.id) {
      rpc.off('message', listener); resolve();
    } }; rpc.on('message', listener);
  });
  await core.start(task.id, { requestId: randomUUID(), text: 'Synthetic retry test', attachments: [], model: 'test-model', effort: '' });
  await completed;
  assert.ok(notices.length > 0, 'the real runtime emitted a retry event for the broken SSE stream');
  assert.equal(notices[0].progress.kind, 'reconnecting'); assert.equal(notices[0].error, '');
  assert.ok(['starting', 'running'].includes(notices[0].status));
  assert.match(notices[0].progress.message, /正在重连/); assert.equal(task.progress, undefined);
});
