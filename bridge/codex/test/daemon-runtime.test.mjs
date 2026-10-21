// Opt-in: real Unix App Server, two clients, isolated CODEX_HOME and a local
// rejecting/holding provider. Never connect a user's daemon or real model.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { DaemonRpc } from '../daemon-rpc.mjs';
import { CodexRpc } from '../rpc.mjs';
import { BridgeCore } from '../core.mjs';
import { discoverDaemons, secureDaemonSocket } from '../daemon-discovery.mjs';

const until = async predicate => { const deadline = Date.now() + 10000; while (!predicate() && Date.now() < deadline) await new Promise(r => setTimeout(r, 20)); assert.ok(predicate(), 'condition reached before deadline'); };
test('native Unix daemon shares PC/phone turns, stop, permissions and safe disconnect', {
  skip: process.platform !== 'linux' || !process.env.CLAWMATE_TEST_DAEMON, timeout: 60000
}, async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'cm-native-'));
  const home = path.join(directory, 'home'), cwd = path.join(directory, 'project'); mkdirSync(home); mkdirSync(cwd);
  let hold = false; let requests = 0; let approvalFixture = false; let approvalIssued = false; let finalReply = '';
  const server = http.createServer((request, response) => {
    requests++; const chunks = []; request.on('data', bytes => chunks.push(bytes));
    request.on('end', () => {
      if (hold) return;
      if (finalReply || (approvalFixture && !approvalIssued)) {
        let item;
        if (finalReply) item = { type: 'message', id: 'msg_fixture_' + requests, role: 'assistant', status: 'completed', phase: 'final_answer',
          content: [{ type: 'output_text', text: finalReply, annotations: [] }] };
        else {
          approvalIssued = true; const body = JSON.parse(Buffer.concat(chunks));
          const tool = (body.tools || []).find(tool => ['exec_command', 'shell_command'].includes(tool.name));
          if (!tool) { console.log('fixture available tools', (body.tools || []).map(tool => tool.name)); response.writeHead(400); response.end(); return; }
          const args = { [tool.name === 'exec_command' ? 'cmd' : 'command']: 'printf isolated_approval_fixture',
            sandbox_permissions: 'require_escalated', justification: 'Isolated fixture approval; decline this command.' };
          item = { type: 'function_call', id: 'fc_fixture_' + requests, call_id: 'call_fixture_' + requests, name: tool.name, arguments: JSON.stringify(args), status: 'completed' };
        }
        const output = { id: 'resp_fixture_' + requests, status: 'completed', output: [item], usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20 } };
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        for (const event of [
          { type: 'response.created', response: { ...output, status: 'in_progress', output: [] } },
          { type: 'response.output_item.added', output_index: 0, item },
          { type: 'response.output_item.done', output_index: 0, item },
          { type: 'response.completed', response: output }
        ]) response.write('event: ' + event.type + '\ndata: ' + JSON.stringify(event) + '\n\n');
        response.end(); return;
      }
      response.writeHead(400, { 'Content-Type': 'application/json' });
      response.end('{"error":{"message":"Isolated test: no real inference","type":"invalid_request_error"}}');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  writeFileSync(path.join(home, 'config.toml'), 'model="test-model"\nmodel_provider="fixture"\n' +
    '[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:' + server.address().port + '/v1"\nwire_api="responses"\nrequest_max_retries=0\nstream_max_retries=0\n');
  const environment = { ...process.env, CODEX_HOME: home, OPENAI_API_KEY: '', CHATGPT_API_KEY: '' };
  const socket = path.join(directory, 'daemon.sock');
  const daemon = spawn(process.env.CLAWMATE_TEST_DAEMON, ['app-server', '--listen', 'unix://' + socket], {
    cwd, env: environment, stdio: ['ignore', 'ignore', 'pipe']
  }); daemon.stderr.resume();
  const clients = []; let core, observer;
  t.after(async () => {
    core?.close(); for (const client of clients) client.close();
    await observer?.shutdown(); daemon.kill('SIGKILL');
    await until(() => daemon.exitCode !== null || daemon.signalCode !== null);
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  });
  await until(() => existsSync(socket));
  const canonicalSocket = realpathSync(socket); // Native Codex creates a symlink to its private, hashed listener.
  assert.equal(secureDaemonSocket(canonicalSocket), true);
  assert.ok(discoverDaemons(environment).includes(canonicalSocket), 'discovers the native process with matching private socket and CODEX_HOME');
  const pc = new DaemonRpc(socket); clients.push(pc); await pc.initialize();
  const { thread } = await pc.request('thread/start', { cwd, model: 'test-model', sandbox: 'read-only', approvalPolicy: 'on-request' });
  let completed = 0; const pcRequests = []; const resolved = [];
  pc.on('message', message => {
    if (message.method === 'turn/completed' && message.params.threadId === thread.id) completed++;
    if (message.method === 'item/commandExecution/requestApproval') pcRequests.push(message);
    if (message.method === 'serverRequest/resolved') resolved.push(message.params.requestId);
  });
  await pc.request('turn/start', { threadId: thread.id, input: [{ type: 'text', text: 'PC original fixture' }] });
  await until(() => completed === 1);
  observer = new CodexRpc(process.env.CLAWMATE_TEST_DAEMON, undefined, { env: environment }); await observer.initialize();
  const configuration = { desktopCoordination: true, stateDir: path.join(directory, 'private'), workspaces: [{ id: 'project', name: 'Fixture', path: cwd }] };
  core = new BridgeCore(configuration, observer);
  core.desktopSessions.attach = async () => false;
  core.models = [{ model: 'test-model', supportedReasoningEfforts: [] }]; core.ready = true;
  const task = await core.history.resume(thread.id, { requestId: randomUUID(), workspaceId: 'project', model: 'test-model', mode: 'workspace-write' });
  await core.snapshot(task.id);
  assert.equal(task.desktopConnected, true); assert.equal(task.executionBackend, 'daemon');
  assert.ok(task.items.some(item => item.text === 'PC original fixture'));
  const body = { requestId: randomUUID(), text: 'Phone same daemon fixture', attachments: [], model: 'test-model', mode: 'workspace-write', approvalMode: 'ask' };
  await core.start(task.id, body); await until(() => completed === 2 && task.status === 'failed');
  assert.equal(task.executionSource, 'phone'); assert.equal(task.lastRequestConfirmed, true);
  assert.equal(task.items.filter(item => item.kind === 'user' && item.text === body.text).length, 1);
  const pcView = await pc.request('thread/read', { threadId: thread.id, includeTurns: true });
  assert.ok(pcView.thread.turns.some(turn => turn.items.some(item => item.type === 'userMessage' && item.content.some(part => part.text?.includes(body.text)))));
  const policy = await pc.request('thread/resume', { threadId: thread.id, excludeTurns: true });
  assert.equal(policy.sandbox.type, 'workspaceWrite'); assert.equal(policy.approvalPolicy, 'on-request'); assert.equal(policy.approvalsReviewer, 'user');
  const before = requests; await core.start(task.id, body); assert.equal(requests, before);
  hold = true;
  await pc.request('turn/start', { threadId: task.id, input: [{ type: 'text', text: 'PC while phone connected' }] });
  await until(() => task.status === 'running' && task.executionSource === 'computer');
  await assert.rejects(core.start(task.id, { ...body, requestId: randomUUID() }), /already running/);
  await core.interrupt(task.id); await until(() => task.status === 'interrupted' && completed === 3);
  assert.ok(task.items.some(item => item.text === 'PC while phone connected'));
  await core.start(task.id, { ...body, requestId: randomUUID(), text: 'Phone running during disconnect' });
  await until(() => task.status === 'running'); const runningId = task.turnId;
  core.daemonSessions.entries.get(task.id).rpc.close();
  assert.equal((await pc.request('thread/read', { threadId: task.id })).thread.status.type, 'active');
  assert.equal(task.status, 'unknown'); await core.snapshot(task.id);
  assert.equal(task.turnId, runningId); assert.equal(task.status, 'running');
  await core.interrupt(task.id); await until(() => completed === 4);
  hold = false; approvalFixture = true;
  await pc.request('turn/start', { threadId: task.id, input: [{ type: 'text', text: 'Isolated command approval fixture' }] });
  await until(() => task.status === 'waitingApproval' && pcRequests.length === 1);
  const firstApproval = task.approvals[0];
  core.daemonSessions.entries.get(task.id).rpc.close();
  await core.snapshot(task.id); await until(() => task.approvals.length === 1);
  assert.equal(task.approvals[0].rpcId, firstApproval.rpcId, 'resume replays original native pending request');
  pc.send({ id: pcRequests[0].id, result: { decision: 'decline' } });
  await until(() => task.approvals.length === 0 && completed === 5);
  assert.throws(() => core.answer(task.id, { id: firstApproval.id, decision: 'accept' }), /resolved/);
  approvalIssued = false;
  await core.start(task.id, { ...body, requestId: randomUUID(), text: 'Phone native approval fixture' });
  await until(() => task.status === 'waitingApproval' && pcRequests.length === 2);
  const lastApproval = task.approvals[0];
  await core.answer(task.id, { id: lastApproval.id, decision: 'decline' });
  await until(() => resolved.includes(pcRequests[1].id) && completed === 6);
  const outputPath = path.join(cwd, 'delivered.pdf'); writeFileSync(outputPath, '%PDF-1.7\nisolated fixture');
  finalReply = `[delivered.pdf](${outputPath})`;
  await core.start(task.id, { ...body, requestId: randomUUID(), text: 'Deliver isolated final file' });
  await until(() => task.status === 'completed' && completed === 7);
  assert.equal(task.artifacts.length, 1); assert.equal(task.artifacts[0].name, 'delivered.pdf');
  assert.equal(daemon.exitCode, null, 'disconnect did not kill Codex');
  console.log(JSON.stringify({ nativeSharedDaemon: 'passed', sameThread: true, twoWayTurns: true, explicitPermissions: true, stop: true, safeDisconnect: true, reconnect: true, nativeApprovalReplayAndBothClients: true, finalDeliverable: true }));
});
