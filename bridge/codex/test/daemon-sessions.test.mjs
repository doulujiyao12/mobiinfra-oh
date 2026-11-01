import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { BridgeCore } from '../core.mjs';
import { DELIVERY_INSTRUCTIONS } from '../artifacts.mjs';

async function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-daemon-test-'));
  const cwd = path.join(directory, 'project'); mkdirSync(cwd);
  const source = { id: 'original', source: 'cli', cwd, model: 'test', status: { type: 'idle' }, updatedAt: 100 };
  const main = new EventEmitter(); let peers = 0;
  main.initialize = async () => {}; main.close = () => {}; main.send = () => {};
  main.createPeer = () => { peers++; throw new Error('A second writer must not be spawned'); };
  main.request = async method => {
    if (method === 'model/list') return { data: [{ model: 'test', supportedReasoningEfforts: [] }] };
    if (method === 'thread/read') return { thread: { ...source, status: { type: 'notLoaded' } } };
    if (method === 'thread/items/list') return { data: [] };
    throw new Error('Unexpected main RPC ' + method);
  };
  const rpc = new EventEmitter(); rpc.calls = []; rpc.sent = []; rpc.closed = false;
  rpc.initialize = async () => {}; rpc.close = () => { rpc.closed = true; rpc.emit('stopped'); };
  rpc.send = message => rpc.sent.push(message);
  let nextTurn = 0; let replay;
  rpc.request = async (method, params) => {
    rpc.calls.push({ method, params });
    if (method === 'thread/loaded/list') return { data: [source.id] };
    if (method === 'thread/read') return { thread: { ...source } };
    if (method === 'thread/resume') { if (replay) rpc.emit('message', replay); return { thread: { ...source } }; }
    if (method === 'thread/turns/list') return { data: [] };
    if (method === 'turn/start') {
      source.status = { type: 'active', activeFlags: [] };
      const turn = { id: 'turn-' + (++nextTurn), status: 'inProgress' };
      emit('turn/started', { turn }); return { turn };
    }
    if (method === 'turn/interrupt') return {};
    throw new Error('Unexpected daemon RPC ' + method);
  };
  const emit = (method, params = {}, id) => rpc.emit('message', { method, params: { threadId: source.id, ...params }, ...(id !== undefined ? { id } : {}) });
  const config = { desktopCoordination: true, stateDir: path.join(directory, 'private'), workspaces: [{ id: 'project', name: 'Fixture', path: cwd }] };
  const ipc = new EventEmitter(); ipc.close = () => {}; ipc.findOwner = async () => null;
  // DesktopIpc's public owner method is stubbed at the boundary, preserving the Windows implementation.
  const core = new BridgeCore(config, main, { discoverDaemons: () => ['fixture.sock'], daemonRpc: () => rpc });
  core.desktopSessions.attach = async () => false;
  await core.initialize();
  t.after(() => { core.close(); rmSync(directory, { recursive: true, force: true }); });
  const body = () => ({ requestId: randomUUID(), text: 'Phone task', attachments: [], model: 'test', effort: '', mode: 'workspace-write', approvalMode: 'ask' });
  const task = await core.history.resume(source.id, { requestId: randomUUID(), workspaceId: 'project', model: 'test', mode: 'workspace-write' });
  return { core, rpc, source, task, emit, body, cwd, peers: () => peers, setReplay: message => { replay = message; } };
}

test('a cached session moved to another authorized directory reconnects to the original daemon', async t => {
  const f = await fixture(t); const next = path.join(path.dirname(f.cwd), 'new-chat'); mkdirSync(next);
  f.core.workspaces.push({ id: 'new-chat', name: 'New chat', path: next }); f.source.cwd = next;
  const task = await f.core.history.read(f.task.id);
  assert.equal(task, f.task); assert.equal(task.workspaceId, 'new-chat'); assert.equal(task.cwd, next);
  assert.equal(task.executionBackend, 'daemon'); assert.equal(task.desktopConnected, true);
  assert.equal(f.rpc.calls.some(call => call.method === 'turn/start'), false);
  await f.core.start(task.id, f.body());
  const start = f.rpc.calls.find(call => call.method === 'turn/start').params;
  assert.equal(start.cwd, next); assert.deepEqual(start.sandboxPolicy.writableRoots, [next]);
  assert.equal(f.peers(), 0);
});

test('daemon owns original session; phone sends one explicitly sandboxed turn; completion keeps shared backend connected', async t => {
  const f = await fixture(t); const request = f.body();
  await f.core.start(f.task.id, request);
  assert.equal(f.peers(), 0); assert.equal(f.task.desktopConnected, true); assert.equal(f.task.executionBackend, 'daemon');
  const resume = f.rpc.calls.find(call => call.method === 'thread/resume');
  assert.deepEqual(resume.params, { threadId: 'original', excludeTurns: true }, 'attach never changes CLI permissions');
  const start = f.rpc.calls.find(call => call.method === 'turn/start').params;
  assert.equal(start.clientUserMessageId, request.requestId); assert.equal(start.approvalPolicy, 'on-request');
  assert.equal(start.sandboxPolicy.type, 'workspaceWrite'); assert.deepEqual(start.sandboxPolicy.writableRoots, [f.cwd]);
  assert.equal(f.task.lastRequestConfirmed, true);
  await f.core.start(f.task.id, request);
  assert.equal(f.rpc.calls.filter(call => call.method === 'turn/start').length, 1);
  f.emit('item/completed', { turnId: f.task.turnId, item: { id: request.requestId, type: 'userMessage', content: [{ type: 'text', text: request.text + DELIVERY_INSTRUCTIONS }] } });
  assert.equal(f.task.items.filter(item => item.kind === 'user').length, 1);
  assert.equal(f.task.items[0].text, request.text);
  f.emit('turn/completed', { turn: { id: f.task.turnId, status: 'completed' } });
  assert.equal(f.task.status, 'completed'); assert.equal(f.rpc.closed, false); assert.equal(f.core.sharedSessions.entries.size, 0);
});

test('PC messages, stream, approvals resolved on either side, stop and final files use the same native connection', async t => {
  const f = await fixture(t); await f.core.snapshot(f.task.id);
  f.emit('turn/started', { turn: { id: 'pc-turn', status: 'inProgress' } });
  f.emit('item/completed', { turnId: 'pc-turn', item: { id: 'pc-user', type: 'userMessage', content: [{ type: 'text', text: 'PC message' }] } });
  f.emit('item/agentMessage/delta', { turnId: 'pc-turn', itemId: 'reply', delta: 'Hello' });
  assert.equal(f.task.items.at(-2).text, 'PC message'); assert.equal(f.task.items.at(-1).text, 'Hello');
  assert.equal(f.task.executionSource, 'computer');
  f.emit('item/commandExecution/requestApproval', { turnId: 'pc-turn', command: 'pwd', availableDecisions: ['accept', 'decline'] }, 90);
  assert.equal(f.task.status, 'waitingApproval'); const first = f.task.approvals[0];
  f.emit('serverRequest/resolved', { requestId: 90 });
  assert.throws(() => f.core.answer(f.task.id, { id: first.id, decision: 'accept' }), /resolved/);
  f.emit('item/fileChange/requestApproval', { turnId: 'pc-turn' }, 91);
  await f.core.answer(f.task.id, { id: f.task.approvals[0].id, decision: 'decline' });
  assert.deepEqual(f.rpc.sent.at(-1), { id: 91, result: { decision: 'decline' } });
  f.emit('item/tool/requestUserInput', { turnId: 'pc-turn', questions: [{ id: 'q', question: 'Which?' }] }, 92);
  await f.core.answer(f.task.id, { id: f.task.approvals[0].id, decision: 'answer', answers: [{ id: 'q', text: 'A' }] });
  assert.deepEqual(f.rpc.sent.at(-1).result, { answers: { q: { answers: ['A'] } } });
  const sent = f.rpc.sent.length;
  f.emit('mcpServer/elicitation/request', { turnId: 'pc-turn', secret: 'not-for-phone' }, 93);
  assert.equal(f.rpc.sent.length, sent, 'unsupported PC interactions are left on the PC, never canceled');
  assert.equal(JSON.stringify(f.task).includes('not-for-phone'), false);
  await f.core.interrupt(f.task.id);
  assert.deepEqual(f.rpc.calls.at(-1), { method: 'turn/interrupt', params: { threadId: 'original', turnId: 'pc-turn' } });
  const output = path.join(f.cwd, 'final.pdf'); writeFileSync(output, '%PDF-1.7\nfixture');
  f.emit('item/completed', { turnId: 'pc-turn', item: { id: 'reply', type: 'agentMessage', phase: 'final_answer', text: `[final](${output.replaceAll('\\', '/')})` } });
  f.emit('turn/completed', { turn: { id: 'pc-turn', status: 'completed' } });
  assert.equal(f.task.artifacts.length, 1); assert.equal(f.task.artifacts[0].name, 'final.pdf');
});

test('resume replays pending approval; disconnect marks unknown, closes only our client and never sends stop/unload', async t => {
  const f = await fixture(t);
  f.setReplay({ id: 50, method: 'item/commandExecution/requestApproval', params: { threadId: 'original', command: 'pwd' } });
  await f.core.snapshot(f.task.id);
  assert.equal(f.task.approvals.length, 1); assert.equal(f.task.status, 'waitingApproval');
  f.core.daemonSessions.close();
  assert.equal(f.task.status, 'unknown'); assert.equal(f.task.desktopConnected, false); assert.equal(f.task.approvals.length, 0);
  assert.equal(f.rpc.calls.some(call => ['turn/interrupt', 'thread/unsubscribe', 'thread/unload'].includes(call.method)), false);
  await assert.rejects(f.core.interrupt(f.task.id), /共享连接/);
});

test('busy/project changes prevent submission and drop the untrusted connection', async t => {
  const f = await fixture(t); await f.core.snapshot(f.task.id);
  f.source.status = { type: 'active' };
  await assert.rejects(f.core.start(f.task.id, f.body()), /正在执行/);
  assert.equal(f.rpc.calls.some(call => call.method === 'turn/start'), false);
  f.source.status = { type: 'idle' }; f.source.cwd = path.dirname(f.cwd);
  await assert.rejects(f.core.start(f.task.id, f.body()), /已授权|授权项目/);
  assert.equal(f.rpc.closed, true); assert.equal(f.core.daemonSessions.has(f.task.id), false);
});

test('uncertain daemon submission is not automatically retried', async t => {
  const f = await fixture(t); await f.core.snapshot(f.task.id);
  const original = f.rpc.request;
  f.rpc.request = async (method, params) => { if (method !== 'turn/start') return original(method, params); const error = new Error('Connection lost'); error.outcomeUnknown = true; throw error; };
  const body = f.body(); await assert.rejects(f.core.start(f.task.id, body), /Connection lost/);
  assert.equal(f.task.status, 'unknown');
  await f.core.start(f.task.id, body); // Idempotent, no second model request.
});

test('approval and stop recheck identity and do not act on a replacement turn during an async read', async t => {
  const f = await fixture(t); await f.core.snapshot(f.task.id);
  f.emit('turn/started', { turn: { id: 'first', status: 'inProgress' } });
  f.emit('item/commandExecution/requestApproval', { turnId: 'first', command: 'pwd' }, 10);
  const approval = f.task.approvals[0]; const original = f.rpc.request;
  f.rpc.request = async (method, params) => {
    const result = await original(method, params);
    if (method === 'thread/read') f.emit('serverRequest/resolved', { requestId: 10 });
    return result;
  };
  await assert.rejects(f.core.answer(f.task.id, { id: approval.id, decision: 'accept' }), /resolved/);
  assert.equal(f.rpc.sent.length, 0);
  f.rpc.request = async (method, params) => {
    const result = await original(method, params);
    if (method === 'thread/read') f.emit('turn/started', { turn: { id: 'replacement', status: 'inProgress' } });
    return result;
  };
  await assert.rejects(f.core.interrupt(f.task.id), /原轮次已结束/);
  assert.equal(f.rpc.calls.some(call => call.method === 'turn/interrupt'), false);
});

test('multiple daemons claiming the same loaded ID fail closed and all probes detach', async t => {
  const f = await fixture(t);
  const second = new EventEmitter(); second.initialize = async () => {}; second.closed = false;
  second.close = () => { second.closed = true; }; second.request = async () => ({ data: [f.task.id] });
  f.core.daemonSessions.discover = () => ['one', 'two'];
  f.core.daemonSessions.connect = socket => socket === 'one' ? f.rpc : second;
  await assert.rejects(f.core.start(f.task.id, f.body()), /多个后台/);
  assert.equal(f.rpc.closed, true); assert.equal(second.closed, true); assert.equal(f.peers(), 0);
});
