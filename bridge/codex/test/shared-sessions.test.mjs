import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { BridgeCore } from '../core.mjs';
import { createBridgeServer } from '../server.mjs';

async function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-handoff-'));
  const cwd = path.join(directory, 'project'); mkdirSync(cwd);
  const config = { host: '127.0.0.1', token: randomBytes(32).toString('base64url'), stateDir: path.join(directory, 'private'),
    workspaces: [{ id: 'project', name: 'Project', path: cwd }] };
  const source = { id: 'original', cwd, name: 'Original PC conversation', source: 'appServer', model: 'test',
    historyMode: 'paginated', status: { type: 'notLoaded' }, updatedAt: 100 };
  let history = [{ turnId: 'old-turn', item: { id: 'old', type: 'agentMessage', text: 'PC context' } }];
  const peers = []; const calls = []; const main = new EventEmitter(); const sent = [];
  main.initialize = async () => {}; main.close = () => {}; main.send = message => sent.push(message);
  main.request = async (method, params) => {
    calls.push({ method, params });
    if (method === 'model/list') return { data: [{ model: 'test', supportedReasoningEfforts: [] }] };
    if (method === 'thread/read') return { thread: { ...source } };
    if (method === 'thread/items/list') return { data: [...history].reverse(), nextCursor: null };
    if (method === 'thread/list') return { data: [{ ...source }] };
    throw new Error('Unexpected main RPC ' + method);
  };
  main.createPeer = () => {
    const peer = new EventEmitter(); peer.calls = []; peer.sent = []; peer.closed = false;
    peer.initialize = async () => {}; peer.send = message => peer.sent.push(message);
    peer.close = () => { peer.closed = true; peer.emit('stopped'); };
    peer.shutdown = async () => peer.close();
    peer.request = async (method, params) => {
      peer.calls.push({ method, params });
      if (method === 'thread/resume') return { thread: { ...source, status: { type: 'idle' } }, cwd,
        approvalPolicy: params.approvalPolicy, approvalsReviewer: params.approvalsReviewer,
        sandbox: { type: params.sandbox === 'danger-full-access' ? 'dangerFullAccess' : params.sandbox === 'read-only' ? 'readOnly' : 'workspaceWrite' } };
      if (method === 'turn/start') return { turn: { id: randomUUID(), status: 'inProgress' } };
      if (method === 'turn/interrupt') return {};
      throw new Error('Unexpected worker RPC ' + method);
    };
    peers.push(peer); return peer;
  };
  const core = new BridgeCore(config, main); await core.initialize();
  t.after(() => { core.close(); rmSync(directory, { recursive: true, force: true }); });
  const body = () => ({ requestId: randomUUID(), workspaceId: 'project', model: 'test', effort: '', mode: 'read-only' });
  const turn = () => ({ requestId: randomUUID(), text: 'Phone message', attachments: [], model: 'test', effort: '' });
  const complete = async (task, status = 'completed') => {
    const peer = peers.at(-1); peer.emit('message', { method: 'turn/completed', params: { threadId: task.id, turn: { id: task.turnId, status } } });
    await core.sharedSessions.entries.get(task.id)?.releasing;
  };
  return { core, main, config, source, calls, peers, sent, body, turn, complete, cwd,
    setHistory: value => { history = value; } };
}

test('registers original ID without execution; retries/restart never fork or widen permissions', async t => {
  const { core, config, main, body, calls, peers } = await fixture(t);
  const request = body(); const task = await core.history.resume('original', request);
  assert.equal(task.id, 'original'); assert.equal(task.sharedThread, true); assert.equal(task.external, false);
  assert.equal(task.mode, 'read-only'); assert.equal(task.items[0].text, 'PC context');
  assert.equal(await core.history.resume('original', request), task);
  assert.equal(peers.length, 0);
  assert.equal(calls.some(call => ['thread/resume', 'thread/fork', 'turn/start'].includes(call.method)), false);
  await assert.rejects(core.history.resume('original', { ...request, mode: 'workspace-write' }), /其他权限/);
  const restored = new BridgeCore(config, main); await restored.initialize();
  assert.equal((await restored.history.resume('original', request)).id, task.id); restored.close();
  assert.equal((await core.history.list()).threads[0].id, task.id, 'original remains in PC list');
});

test('each turn loads fresh original history and waits for release before another submission', async t => {
  const { core, body, turn, peers, complete, setHistory } = await fixture(t);
  const task = await core.history.resume('original', body());
  const first = turn(); await core.start(task.id, first);
  assert.deepEqual(peers[0].calls.map(call => call.method), ['thread/resume', 'turn/start']);
  const resumed = peers[0].calls[0].params;
  assert.equal(resumed.threadId, 'original'); assert.equal(resumed.approvalPolicy, 'on-request');
  assert.equal(resumed.approvalsReviewer, 'user'); assert.equal(resumed.sandbox, 'read-only');
  assert.equal(await core.start(task.id, first), task, 'lost response retry does not execute twice');
  let release; peers[0].shutdown = () => new Promise(resolve => { release = () => { peers[0].close(); resolve(); }; });
  const completing = complete(task); assert.equal(task.status, 'releasing');
  await assert.rejects(core.start(task.id, turn()), /already running/);
  release(); await completing;
  assert.equal(task.status, 'completed'); assert.equal(peers[0].closed, true);
  assert.equal(core.sharedSessions.entries.size, 0);
  setHistory([{ turnId: 'new-pc-turn', item: { id: 'pc-reply', type: 'agentMessage', text: 'New PC-written context' } }]);
  await core.start(task.id, turn());
  assert.equal(peers.length, 2); assert.equal(task.items[0].text, 'New PC-written context');
  assert.equal(peers[1].calls.find(call => call.method === 'turn/start').params.threadId, 'original');
  await complete(task);
});

test('native writer conflict fails before submission and permits retry after PC releases', async t => {
  const { core, main, body, turn, peers, complete } = await fixture(t);
  const task = await core.history.resume('original', body()); const factory = main.createPeer;
  main.createPeer = () => { const peer = factory(); peer.request = async () => { throw new Error('thread original already has an active writer'); }; return peer; };
  const request = turn(); await assert.rejects(core.start(task.id, request), /电脑仍持有.*尚未下发/);
  assert.equal(task.lastRequestId, undefined); assert.equal(peers[0].closed, true);
  assert.equal(core.sharedSessions.entries.size, 0);
  main.createPeer = factory;
  await core.start(task.id, request); await complete(task);
  assert.equal(peers[1].calls.filter(call => call.method === 'turn/start').length, 1);
});

test('source scope and resumed policy/cwd/identity must match before any turn', async t => {
  const { core, main, source, body, turn, peers } = await fixture(t);
  const task = await core.history.resume('original', body());
  source.cwd = path.dirname(source.cwd);
  await assert.rejects(core.start(task.id, turn()), /已授权/); assert.equal(peers.length, 0);
  source.cwd = task.cwd; const factory = main.createPeer;
  for (const patch of [{ thread: { ...source, id: 'another-id' } }, { sandbox: { type: 'externalSandbox' } }, { cwd: path.dirname(task.cwd) }, { approvalsReviewer: 'auto_review' }]) {
    main.createPeer = () => { const peer = factory(); const request = peer.request;
      peer.request = async (method, params) => ({ ...await request(method, params), ...patch }); return peer; };
    await assert.rejects(core.start(task.id, turn()), /权限不匹配/);
    assert.equal(peers.at(-1).calls.some(call => call.method === 'turn/start'), false); assert.equal(peers.at(-1).closed, true);
  }
});

test('approvals/stop target owner; final artifacts remain attached to original session', async t => {
  const { core, body, turn, peers, sent, cwd, complete } = await fixture(t);
  const task = await core.history.resume('original', { ...body(), mode: 'workspace-write' });
  await core.start(task.id, turn()); const peer = peers[0];
  peer.emit('message', { id: 42, method: 'item/commandExecution/requestApproval', params: { threadId: task.id, command: 'fixture' } });
  assert.equal(task.status, 'waitingApproval');
  core.answer(task.id, { id: task.approvals[0].id, decision: 'accept' });
  assert.equal(peer.sent[0].id, 42); assert.equal(sent.length, 0);
  await core.interrupt(task.id); assert.equal(peer.calls.at(-1).method, 'turn/interrupt');
  writeFileSync(path.join(cwd, 'report.pdf'), 'fixture PDF');
  peer.emit('message', { method: 'item/completed', params: { threadId: task.id, turnId: task.turnId,
    item: { id: 'final', type: 'agentMessage', phase: 'final_answer', text: '[Report](report.pdf)' } } });
  await complete(task); assert.equal(task.artifacts.length, 1); assert.equal(task.artifacts[0].name, 'report.pdf');
});

test('interrupted/failed turns and unexpected worker exit release ownership', async t => {
  const { core, body, turn, peers, complete } = await fixture(t);
  const task = await core.history.resume('original', body());
  for (const status of ['interrupted', 'failed']) {
    await core.start(task.id, turn()); await complete(task, status);
    assert.equal(task.status, status); assert.equal(core.sharedSessions.entries.size, 0);
  }
  await core.start(task.id, turn()); peers.at(-1).emit('stopped');
  await core.sharedSessions.entries.get(task.id)?.releasing;
  assert.equal(task.status, 'failed'); assert.match(task.error, /接力进程已退出/);
});

test('idle snapshots refresh desktop history without replacing an executing phone turn', async t => {
  const { core, body, turn, setHistory, complete } = await fixture(t);
  const task = await core.history.resume('original', body());
  setHistory([{ turnId: 'pc-turn', item: { id: 'new', type: 'agentMessage', text: 'Updated on PC' } }]);
  const revised = task.revision; await core.snapshot(task.id);
  assert.equal(task.items[0].text, 'Updated on PC'); assert.ok(task.revision > revised);
  assert.equal((await core.history.read(task.id)).sharedThread, true);
  await core.start(task.id, turn()); const length = task.items.length;
  await core.snapshot(task.id); assert.equal(task.items.length, length); await complete(task);
});

test('resume route is authenticated, advertised and rejects query overrides', async t => {
  const { core, config, body } = await fixture(t);
  const server = createBridgeServer(config, core); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = 'http://127.0.0.1:' + server.address().port;
  const headers = { Authorization: 'Bearer ' + config.token, 'Content-Type': 'application/json' };
  const info = await (await fetch(url + '/v1/info', { headers })).json(); assert.equal(info.sameSessionSupported, true);
  const options = { method: 'POST', headers, body: JSON.stringify(body()) };
  assert.equal((await fetch(url + '/v1/threads/original/resume', { ...options, headers: { 'Content-Type': 'application/json' } })).status, 401);
  assert.equal((await fetch(url + '/v1/threads/original/resume?cwd=x', options)).status, 400);
  const result = await (await fetch(url + '/v1/threads/original/resume', options)).json();
  assert.equal(result.task.id, 'original'); assert.equal(result.task.sharedThread, true);
});

test('release failure blocks new work until explicit stop successfully releases our own executor', async t => {
  const { core, body, turn, peers, complete } = await fixture(t);
  const task = await core.history.resume('original', body()); await core.start(task.id, turn());
  peers[0].shutdown = async () => { throw new Error('Executor did not exit'); };
  await complete(task);
  assert.equal(task.status, 'releasing'); assert.match(task.error, /尚未释放/);
  await assert.rejects(core.start(task.id, turn()), /already running/);
  peers[0].shutdown = async () => peers[0].close();
  await core.interrupt(task.id);
  assert.equal(task.status, 'completed'); assert.equal(core.sharedSessions.entries.size, 0);
  assert.equal(task.error, '', 'a successful release clears the temporary release failure');
});

test('read-only refresh that started before a submission cannot overwrite its new user message', async t => {
  const { core, main, body, turn, complete } = await fixture(t);
  const task = await core.history.resume('original', body()); const request = main.request;
  let release; let entered; const entering = new Promise(resolve => { entered = resolve; });
  let blocked = true;
  main.request = async (method, params) => {
    if (method === 'thread/items/list' && blocked) {
      blocked = false; entered(); await new Promise(resolve => { release = resolve; });
    }
    return request(method, params);
  };
  const reading = core.snapshot(task.id); await entering;
  const bodyTurn = turn(); await core.start(task.id, bodyTurn); release(); await reading;
  assert.equal(task.items.at(-1).text, bodyTurn.text); assert.equal(task.status, 'running'); await complete(task);
});

test('completion before turn/start response is reconciled before closing its transport', async t => {
  const { core, main, body, turn, peers } = await fixture(t);
  const task = await core.history.resume('original', body()); const factory = main.createPeer;
  main.createPeer = () => {
    const peer = factory(); const request = peer.request;
    peer.request = async (method, params) => {
      if (method !== 'turn/start') return request(method, params);
      peer.emit('message', { method: 'turn/completed', params: { threadId: task.id, turn: { id: 'early-turn', status: 'completed' } } });
      assert.equal(peer.closed, false, 'turn/start still needs its response transport');
      return { turn: { id: 'early-turn' } };
    }; return peer;
  };
  await core.start(task.id, turn()); await core.sharedSessions.entries.get(task.id)?.releasing;
  assert.equal(task.status, 'completed'); assert.equal(task.turnId, 'early-turn'); assert.equal(peers[0].closed, true);
});

test('idle shared sessions can change sandbox/reviewer per turn while retaining the original ID', async t => {
  const { core, body, turn, peers, complete } = await fixture(t);
  const task = await core.history.resume('original', body());
  for (const settings of [
    { mode: 'workspace-write', approvalMode: 'auto' }, { mode: 'danger-full-access', approvalMode: 'full' },
    { mode: 'read-only', approvalMode: 'ask' }
  ]) {
    await core.start(task.id, { ...turn(), ...settings });
    const calls = peers.at(-1).calls;
    assert.equal(calls[0].params.threadId, 'original'); assert.equal(calls[0].params.sandbox, settings.mode);
    assert.equal(calls[0].params.approvalsReviewer, settings.approvalMode === 'auto' ? 'auto_review' : 'user');
    assert.equal(calls[1].params.approvalsReviewer, calls[0].params.approvalsReviewer);
    assert.equal(calls[1].params.approvalPolicy, settings.approvalMode === 'full' ? 'never' : 'on-request');
    assert.equal(task.mode, settings.mode); assert.equal(task.approvalMode, settings.approvalMode);
    await complete(task);
  }
});
