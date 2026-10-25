import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { BridgeCore } from '../core.mjs';
import { applyDesktopPatches, desktopTurns, desktopInputs } from '../desktop-sessions.mjs';

async function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-desktop-share-'));
  const cwd = path.join(directory, 'project'); mkdirSync(cwd); const calls = [];
  let threadCwd = cwd;
  const rpc = new EventEmitter(); rpc.initialize = async () => {}; rpc.close = () => {};
  rpc.createPeer = () => { throw new Error('Must not start a second executor for a desktop-owned session'); };
  rpc.request = async (method, params) => {
    calls.push({ method, params });
    if (method === 'model/list') return { data: [{ model: 'test', supportedReasoningEfforts: [] }] };
    if (method === 'thread/read') return { thread: { id: params.threadId, cwd: threadCwd, name: 'Shared', model: 'test', source: 'appServer', status: { type: 'notLoaded' } } };
    if (method === 'thread/items/list') return { data: [], nextCursor: null };
    throw new Error('Unexpected native call ' + method);
  };
  const ipc = new EventEmitter(); ipc.ownerValue = 'desktop-owner'; ipc.calls = []; ipc.closed = false; ipc.revision = 0; ipc.version = 11;
  ipc.state = { id: 'original', hostId: 'local', cwd, workspaceKind: 'project', title: 'Shared live', threadRuntimeStatus: { type: 'idle' },
    turns: [], requests: [], environments: [], currentPermissions: { sandboxPolicy: { type: 'dangerFullAccess' } } };
  ipc.owner = async () => ipc.ownerValue;
  ipc.snapshot = () => ipc.emit('broadcast', { type: 'broadcast', method: 'thread-stream-state-changed', version: ipc.version,
    sourceClientId: ipc.ownerValue, params: { conversationId: 'original', hostId: 'local', change: { type: 'snapshot', revision: ++ipc.revision, conversationState: structuredClone(ipc.state) } } });
  ipc.follow = (_id, owner, following) => { ipc.calls.push({ method: 'follow', owner, following }); if (following && ipc.autoSnapshot !== false) queueMicrotask(() => ipc.snapshot()); };
  ipc.request = async (method, params, owner) => {
    ipc.calls.push({ method, params, owner });
    if (method === 'thread-follower-start-turn') {
      ipc.state.turns.push({ turnId: 'phone-turn', status: 'inProgress', params: params.turnStart.request, items: [] });
      ipc.state.threadRuntimeStatus = { type: 'active' }; ipc.snapshot();
      return { result: { result: { turn: { id: 'phone-turn', status: 'inProgress' } } } };
    }
    if (method === 'thread-follower-interrupt-turn') {
      ipc.state.turns.at(-1).status = 'interrupted'; ipc.state.threadRuntimeStatus = { type: 'idle' }; ipc.snapshot();
      return { result: { ok: true, interruptedTurnId: params.expectedTurnId } };
    }
    ipc.state.requests = []; ipc.snapshot(); return { result: { ok: true } };
  };
  ipc.close = () => { ipc.closed = true; };
  const core = new BridgeCore({ desktopCoordination: true, stateDir: path.join(directory, 'private'),
    workspaces: [{ id: 'project', name: 'Project', path: cwd }] }, rpc, { desktopIpc: ipc });
  await core.initialize(); t.after(() => { core.close(); rmSync(directory, { recursive: true, force: true }); });
  const turn = () => ({ requestId: randomUUID(), text: 'Phone request', attachments: [], model: 'test', effort: '', mode: 'workspace-write', approvalMode: 'ask' });
  return { core, ipc, rpc, calls, cwd, directory, turn, setThreadCwd: value => { threadCwd = value; } };
}

function moveThread(f, authorized = true) {
  const cwd = path.join(f.directory, 'new-chat'); mkdirSync(cwd);
  if (authorized) f.core.workspaces.push({ id: 'new-chat', name: 'New chat', path: cwd });
  f.setThreadCwd(cwd); f.ipc.state.cwd = cwd; f.ipc.state.workspaceKind = 'projectless';
  return cwd;
}

test('explicitly authorized local projectless sessions support the original shared executor', async t => {
  const f = await fixture(t); f.ipc.state.workspaceKind = 'projectless';
  const task = await f.core.history.read('original');
  assert.equal(task.desktopConnected, true); assert.equal(task.workspaceId, 'project');
  await f.core.start(task.id, f.turn());
  const sent = f.ipc.calls.find(call => call.method === 'thread-follower-start-turn');
  assert.deepEqual(sent.params.turnStart.request.sandboxPolicy.writableRoots, [f.cwd]);
  assert.equal(f.calls.some(call => ['thread/resume', 'thread/fork', 'turn/start'].includes(call.method)), false);
});

test('cached workspace rebind preserves session, artifacts and uncertain request IDs without replay', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  const filename = path.join(f.cwd, 'old.pdf'); writeFileSync(filename, '%PDF-old-delivery');
  task.turnId = 'old-turn'; task.artifacts = f.core.artifacts.publish(task, `[Old](${filename})`).artifacts;
  task.lastRequestId = 'uncertain-request-id'; task.lastRequestFingerprint = 'saved-fingerprint'; task.lastRequestConfirmed = false;
  task.approvals = [{ id: 'stale-approval' }]; task.progress = { kind: 'reconnecting' };
  const originalArtifacts = structuredClone(task.artifacts); const next = moveThread(f);
  const rebound = await f.core.history.read(task.id);
  assert.equal(rebound, task); assert.equal(task.id, 'original'); assert.equal(task.cwd, next);
  assert.equal(task.workspaceId, 'new-chat'); assert.equal(task.desktopConnected, true);
  assert.equal(task.lastRequestId, 'uncertain-request-id'); assert.equal(task.lastRequestFingerprint, 'saved-fingerprint');
  assert.equal(task.lastRequestConfirmed, false); assert.deepEqual(task.artifacts, originalArtifacts);
  assert.deepEqual(task.approvals, []); assert.equal(task.progress, undefined);
  assert.equal(Buffer.from(f.core.artifacts.chunk(task.id, task.artifacts[0].id, 0).base64, 'base64').toString(), '%PDF-old-delivery');
  assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-start-turn'), false);
  const saved = JSON.parse(readFileSync(f.core.stateFile, 'utf8')).tasks.find(item => item.id === task.id);
  assert.equal(saved.workspaceId, 'new-chat'); assert.equal(saved.cwd, next);
  await f.core.start(task.id, f.turn());
  const sent = f.ipc.calls.find(call => call.method === 'thread-follower-start-turn');
  assert.equal(sent.params.turnStart.request.cwd, next);
  assert.deepEqual(sent.params.turnStart.request.sandboxPolicy.writableRoots, [next]);
  const newFile = path.join(next, 'new.pdf'); writeFileSync(newFile, '%PDF-new-delivery');
  f.ipc.state.turns.at(-1).status = 'completed'; f.ipc.state.threadRuntimeStatus = { type: 'idle' };
  f.ipc.state.turns.at(-1).items.push({ id: 'final', type: 'agentMessage', phase: 'final_answer', text: `[New](${newFile})` });
  f.ipc.snapshot();
  assert.deepEqual(task.artifacts.map(item => item.name), ['old.pdf', 'new.pdf']);
});

test('polling a stale registration refreshes its authorized workspace and live status', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  f.core.desktopSessions.detach(task.id); moveThread(f);
  const result = await f.core.snapshot(task.id);
  assert.equal(result.workspaceId, 'new-chat'); assert.equal(result.desktopConnected, true);
  assert.equal(result.error, ''); assert.equal(result.status, 'idle');
});

test('a send discovering a directory change stops before submission and requires reopening', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); moveThread(f);
  const body = f.turn();
  await assert.rejects(f.core.start(task.id, body), /重新打开.*尚未下发/);
  assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-start-turn'), false);
  assert.equal(task.lastRequestId, undefined);
  await f.core.history.read(task.id); await f.core.start(task.id, body);
  assert.equal(f.ipc.calls.filter(call => call.method === 'thread-follower-start-turn').length, 1);
});

test('registering a moved session reconciles before acquiring its own registration lock', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); moveThread(f);
  const result = await f.core.history.resume(task.id, { requestId: randomUUID(), workspaceId: 'new-chat',
    model: 'test', mode: 'workspace-write', approvalMode: 'ask' });
  assert.equal(result, task); assert.equal(result.workspaceId, 'new-chat');
  assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-start-turn'), false);
  assert.equal(f.core.locks.has(task.id), false);
});

test('an unauthorized changed directory never replaces the saved binding or submits a task', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); moveThread(f, false);
  await assert.rejects(f.core.history.read(task.id), /已授权/);
  await assert.rejects(f.core.start(task.id, f.turn()), /已授权/);
  assert.equal(task.workspaceId, 'project'); assert.equal(task.cwd, f.cwd);
  assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-start-turn'), false);
});

test('workspace rebind waits for active execution or a pending control operation', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); moveThread(f);
  task.status = 'waitingApproval';
  await assert.rejects(f.core.history.read(task.id), /当前操作结束/);
  task.status = 'idle'; f.core.locks.add(task.id);
  await assert.rejects(f.core.history.read(task.id), /当前操作结束/);
  f.core.locks.delete(task.id);
  f.core.sharedSessions.entries.set(task.id, {});
  await assert.rejects(f.core.history.read(task.id), /当前操作结束/);
  f.core.sharedSessions.entries.delete(task.id);
  assert.equal(task.cwd, f.cwd);
  await f.core.history.read(task.id); assert.equal(task.workspaceId, 'new-chat');
});

test('projectless status never permits foreign hosts, subagents or unauthorized live cwd', async t => {
  const f = await fixture(t); f.ipc.state.workspaceKind = 'projectless';
  const task = await f.core.history.read('original');
  for (const change of [{ hostId: 'remote' }, { parentThreadId: 'parent' },
    { environments: [{ environmentId: 'remote' }] }, { cwd: f.directory }]) {
    assert.throws(() => f.core.desktopSessions.validate(task, { ...f.ipc.state, ...change }), /本地项目|授权项目/);
  }
});
test('opening a computer session follows its live owner without resuming or starting inference', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  assert.equal(task.external, false); assert.equal(task.desktopConnected, true); assert.equal(task.executionTransport, 'desktop');
  assert.equal(task.sharedThread, true); assert.equal(f.calls.some(call => call.method === 'thread/resume' || call.method === 'turn/start'), false);
  assert.equal(f.ipc.calls.filter(call => call.method === 'thread-follower-start-turn').length, 0);
  assert.equal(await f.core.snapshot(task.id), task);
});
test('phone turn goes through the original owner with explicit permissions; duplicate requests do not execute again', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); const input = f.turn();
  await f.core.start(task.id, input); await f.core.start(task.id, input);
  const sent = f.ipc.calls.filter(call => call.method === 'thread-follower-start-turn'); assert.equal(sent.length, 1);
  const request = sent[0].params.turnStart.request;
  assert.equal(request.threadId, task.id); assert.equal(request.permissions, null); assert.equal(request.approvalsReviewer, 'user');
  assert.deepEqual(request.sandboxPolicy.writableRoots, [f.cwd]); assert.deepEqual(request.runtimeWorkspaceRoots, [f.cwd]);
  assert.equal(sent[0].params.turnStart.context.inheritThreadSettings, false); assert.equal(sent[0].owner, 'desktop-owner');
  assert.equal(task.executionSource, 'phone'); assert.equal(task.status, 'running');
  await assert.rejects(f.core.start(task.id, f.turn()), /already running/);
});

test('mobile inputs satisfy the desktop renderer contract before the owner stores the turn', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); const request = f.ipc.request;
  f.ipc.request = async (method, params, owner) => {
    if (method === 'thread-follower-start-turn') {
      for (const input of params.turnStart.request.input) if (input.type === 'text') {
        // The installed desktop's message parser dereferences this array even
        // for ordinary plain text; the public app-server accepts it omitted.
        assert.equal(input.text_elements.length, 0);
      }
      const combined = params.turnStart.request.input.filter(input => input.type === 'text').map(input => input.text).join('');
      assert.match(combined, /Phone request\n\n文件交付约定/);
    }
    return request(method, params, owner);
  };
  await f.core.start(task.id, f.turn()); assert.equal(task.status, 'running');
});

test('desktop input normalization preserves Unicode and image order without mutating standalone inputs', () => {
  const source = [{ type: 'text', text: '你好🙂' }, { type: 'text', text: '附件说明' },
    { type: 'localImage', path: 'project/photo.png' }, { type: 'text', text: '文件交付约定', text_elements: [] }];
  const before = structuredClone(source); const result = desktopInputs(source);
  assert.deepEqual(result, [{ type: 'text', text: '你好🙂\n\n附件说明', text_elements: [] },
    { type: 'localImage', path: 'project/photo.png' }, { type: 'text', text: '文件交付约定', text_elements: [] }]);
  assert.deepEqual(source, before); assert.equal(Object.hasOwn(source[0], 'text_elements'), false);
  for (const invalid of [[], null, [null], [{ type: 'text', text: 3 }], [{ type: 'localImage', path: '' }], [{ type: 'skill', name: 'untrusted' }]]) {
    assert.throws(() => desktopInputs(invalid), error => error.status === 400);
  }
});
test('computer-originated turns, stream patches, approvals and stopping are reflected and routed to the same owner', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  f.ipc.state.turns = [{ turnId: 'pc-turn', status: 'inProgress', params: { input: [{ type: 'text', text: 'PC instruction' }] }, items: [{ id: 'answer', type: 'agentMessage', text: 'Live answer' }] }];
  f.ipc.state.threadRuntimeStatus = { type: 'active' }; f.ipc.snapshot();
  assert.equal(task.status, 'running'); assert.equal(task.executionSource, 'desktop'); assert.equal(task.items[0].text, 'PC instruction');
  const before = f.core.desktopSessions.entries.get(task.id).revision;
  f.ipc.emit('broadcast', { method: 'thread-stream-state-changed', version: 11, sourceClientId: 'desktop-owner', params: {
    hostId: 'local', conversationId: task.id, change: { type: 'patches', baseRevision: before, revision: ++f.ipc.revision,
      patches: [{ op: 'replace', path: ['turns', 0, 'items', 0, 'text'], value: 'Streaming changed' }] } } });
  assert.equal(task.items.at(-1).text, 'Streaming changed');
  f.ipc.state.requests = [{ id: 'approve-1', method: 'item/commandExecution/requestApproval', params: { turnId: 'pc-turn', command: 'test command' } }]; f.ipc.snapshot();
  assert.equal(task.status, 'waitingApproval'); const oldId = task.approvals[0].id;
  await f.core.answer(task.id, { id: oldId, decision: 'accept' });
  assert.equal(f.ipc.calls.at(-1).method, 'thread-follower-command-approval-decision'); assert.equal(f.ipc.calls.at(-1).params.requestId, 'approve-1');
  assert.throws(() => f.core.answer(task.id, { id: oldId, decision: 'accept' }), /expired/);
  await f.core.interrupt(task.id); assert.equal(task.status, 'interrupted');
  assert.equal(f.ipc.calls.at(-1).params.expectedTurnId, 'pc-turn');
});
test('same-turn approval resolved on the PC cannot be replayed from the phone; user questions use the owner channel', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  f.ipc.state.requests = [{ id: 7, method: 'item/fileChange/requestApproval', params: { turnId: 'first', reason: 'edit' } }]; f.ipc.snapshot();
  const expired = task.approvals[0].id; f.ipc.state.requests[0].params.turnId = 'second'; f.ipc.snapshot();
  assert.throws(() => f.core.answer(task.id, { id: expired, decision: 'accept' }), /expired/);
  f.ipc.state.requests = [{ id: 8, method: 'item/tool/requestUserInput', params: { questions: [{ id: 'q', question: 'Question?' }] } }]; f.ipc.snapshot();
  await f.core.answer(task.id, { id: task.approvals[0].id, decision: 'answer', answers: [{ id: 'q', text: 'Answer' }] });
  assert.equal(f.ipc.calls.at(-1).method, 'thread-follower-submit-user-input');
  assert.deepEqual(f.ipc.calls.at(-1).params.response.answers, { q: { answers: ['Answer'] } });
});
test('unsupported protocol, changed project, foreign owner and disconnect fail closed without killing the desktop', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  const oldTitle = task.title;
  f.ipc.emit('broadcast', { method: 'thread-stream-state-changed', version: 11, sourceClientId: 'foreign', params: { hostId: 'local', conversationId: task.id, change: { type: 'snapshot', revision: 500, conversationState: { title: 'foreign' } } } });
  assert.equal(task.title, oldTitle);
  f.ipc.state.cwd = f.directory; f.ipc.snapshot(); assert.equal(task.status, 'unknown'); assert.equal(task.desktopConnected, false);
  assert.equal(f.core.desktopSessions.has(task.id), false); assert.equal(task.title, oldTitle);
  f.ipc.state.cwd = f.cwd; f.ipc.version = 12;
  await assert.rejects(f.core.desktopSessions.attach(task), /协议版本不兼容/);
  f.ipc.version = 11; await f.core.desktopSessions.attach(task); f.ipc.emit('disconnected', new Error('offline'));
  assert.equal(task.status, 'unknown'); assert.equal(task.desktopConnected, false); assert.equal(f.ipc.closed, false);
});
test('shared completion only publishes new final deliverables and closing the bridge merely detaches', async t => {
  const f = await fixture(t); const filename = path.join(f.cwd, 'final.pdf'); writeFileSync(filename, '%PDF-final');
  f.ipc.state.turns = [{ turnId: 'historic', status: 'completed', params: {}, items: [{ id: 'old', type: 'agentMessage', phase: 'final_answer', text: `[old](<${filename}>)` }] }];
  const task = await f.core.history.read('original'); assert.equal(task.artifacts.length, 0);
  f.ipc.state.turns.push({ turnId: 'new', status: 'completed', params: {}, items: [
    { id: 'temp', type: 'agentMessage', phase: 'commentary', text: `[temp](<${filename}>)` },
    { id: 'final', type: 'agentMessage', phase: 'final_answer', text: `[Report](<${filename}>)` }] });
  f.ipc.snapshot(); f.ipc.snapshot(); assert.equal(task.artifacts.length, 1); assert.equal(task.artifacts[0].turnId, 'new');
  f.core.close(); assert.equal(f.ipc.closed, true); assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-interrupt-turn'), false);
});
test('canonical histories are ordered by islands; patch replay rejects prototype pollution and gaps', () => {
  const a = { turnId: 'a' }, b = { turnId: 'b' };
  assert.deepEqual(desktopTurns({ turnHistory: { kind: 'canonical', history: { entitiesByKey: { a, b }, islands: [{ entries: [{ value: 'b' }, { value: 'a' }] }] } } }), [b, a]);
  for (const key of ['__proto__', 'constructor', 'prototype']) assert.throws(() => applyDesktopPatches({}, [{ op: 'add', path: [key, 'polluted'], value: true }]), /不安全/);
  assert.equal({}.polluted, undefined);
  assert.throws(() => applyDesktopPatches({ turns: [] }, [{ op: 'add', path: ['turns', 9999], value: {} }]), /数组/);
});

test('missing stream revisions block all controls until a fresh snapshot is received', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); f.ipc.autoSnapshot = false;
  f.ipc.emit('broadcast', { method: 'thread-stream-state-changed', version: 11, sourceClientId: 'desktop-owner', params: {
    conversationId: task.id, hostId: 'local', change: { type: 'patches', revision: 20, baseRevision: 19, patches: [] } } });
  assert.equal(task.status, 'unknown'); assert.equal(f.core.desktopSessions.synchronized(task.id), false);
  await assert.rejects(f.core.start(task.id, f.turn()), /尚未同步/);
  assert.equal(f.ipc.calls.some(call => call.method === 'thread-follower-start-turn'), false);
  f.ipc.revision = 21; f.ipc.snapshot(); assert.equal(task.desktopConnected, true);
  await f.core.start(task.id, f.turn()); assert.equal(task.status, 'running');
});
test('uncertain submission is not retried or marked stopped, and is only confirmed by matching desktop input', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original'); const body = f.turn();
  const original = f.ipc.request;
  f.ipc.request = async (method, params, owner) => {
    f.ipc.calls.push({ method, params, owner }); throw Object.assign(new Error('connection lost'), { outcomeUnknown: true });
  };
  await assert.rejects(f.core.start(task.id, body), /connection lost/); assert.equal(task.status, 'unknown'); assert.equal(task.lastRequestConfirmed, false);
  await f.core.start(task.id, body); assert.equal(f.ipc.calls.filter(call => call.method === 'thread-follower-start-turn').length, 1);
  f.ipc.snapshot(); assert.equal(task.lastRequestConfirmed, false);
  f.ipc.request = original; f.ipc.state.turns = [{ turnId: 'accepted-on-pc', status: 'inProgress', params: { clientUserMessageId: body.requestId, input: [] }, items: [] }];
  f.ipc.state.threadRuntimeStatus = { type: 'active' }; f.ipc.snapshot(); assert.equal(task.lastRequestConfirmed, true); assert.equal(task.status, 'running');
});
test('retry progress clears on new output; unsupported desktop confirmations stay on the PC', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  f.ipc.state.turns = [{ turnId: 'retry', status: 'inProgress', params: {}, items: [{ id: 'retry-1', type: 'error', willRetry: true, message: 'Reconnecting 1/5' }] }];
  f.ipc.state.threadRuntimeStatus = { type: 'active' }; f.ipc.snapshot(); assert.equal(task.progress.kind, 'reconnecting');
  f.ipc.state.turns[0].items.push({ id: 'output', type: 'agentMessage', text: 'Recovered' }); f.ipc.snapshot(); assert.equal(task.progress, undefined);
  f.ipc.snapshot(); assert.equal(task.progress, undefined);
  f.ipc.state.requests = [{ id: 1, method: 'mcpServer/elicitation/request', params: { token: 'must-not-render' } }]; f.ipc.snapshot();
  assert.equal(task.approvals.length, 0); assert.equal(task.progress.kind, 'desktopApproval'); assert.equal(JSON.stringify(task).includes('must-not-render'), false);
});
test('simultaneous reads share one observer and duplicate approval submissions are blocked', async t => {
  const f = await fixture(t); const [a, b] = await Promise.all([f.core.history.read('original'), f.core.history.read('original')]);
  assert.equal(a, b); assert.equal(f.core.desktopSessions.entries.size, 1);
  f.ipc.state.requests = [{ id: 'pending', method: 'item/commandExecution/requestApproval', params: {} }]; f.ipc.snapshot();
  let finish; f.ipc.request = () => new Promise(resolve => { finish = () => resolve({ result: { ok: true } }); });
  const id = a.approvals[0].id; const first = f.core.answer(a.id, { id, decision: 'accept' });
  await assert.rejects(f.core.answer(a.id, { id, decision: 'accept' }), /正在提交/);
  finish(); await first;
});

test('an acknowledged stop stays stopping until the desktop reports the terminal state', async t => {
  const f = await fixture(t); const task = await f.core.history.read('original');
  f.ipc.state.turns = [{ turnId: 'active', status: 'inProgress', params: {}, items: [] }]; f.ipc.snapshot();
  let finish; f.ipc.request = () => new Promise(resolve => { finish = () => resolve({ result: { ok: true, interruptedTurnId: 'active' } }); });
  const stopping = f.core.interrupt(task.id);
  await assert.rejects(f.core.interrupt(task.id), /正在提交/); finish(); await stopping;
  assert.equal(task.status, 'stopping'); f.ipc.snapshot(); assert.equal(task.status, 'stopping');
  f.ipc.state.turns[0].status = 'interrupted'; f.ipc.snapshot(); assert.equal(task.status, 'interrupted');
});
