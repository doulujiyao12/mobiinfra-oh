import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, symlinkSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { BridgeCore } from '../core.mjs';
import { createBridgeServer } from '../server.mjs';

async function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-history-'));
  const cwd = path.join(directory, 'project'); mkdirSync(cwd);
  const outside = path.join(directory, 'private-project'); mkdirSync(outside);
  const threads = new Map(); const calls = []; const rpc = new EventEmitter(); rpc.close = () => {};
  rpc.initialize = async () => {};
  const thread = (id, options = {}) => ({ id, cwd, name: '电脑测试会话', preview: 'Prompt', source: 'vscode',
    parentThreadId: null, ephemeral: false, status: { type: 'notLoaded' }, updatedAt: 100, model: 'test', ...options });
  threads.set('pc-1', thread('pc-1')); threads.set('outside', thread('outside', { cwd: outside }));
  const history = id => [{ turnId: 'turn-1', item: { id: 'assistant-1', type: 'agentMessage', text: 'Saved reply' } },
    { turnId: 'turn-1', item: { id: 'user-1', type: 'userMessage', content: [{ type: 'text', text: 'Saved question' }, { type: 'localImage', path: 'not-exposed' }] } }];
  rpc.request = async (method, params) => {
    calls.push({ method, params });
    if (method === 'model/list') return { data: [{ model: 'test', defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: [{ reasoningEffort: 'medium' }] }] };
    if (method === 'thread/list') return { data: [...threads.values()], nextCursor: 'next-page' };
    if (method === 'thread/read') return { thread: threads.get(params.threadId) };
    if (method === 'thread/items/list') return { data: history(params.threadId), nextCursor: 'older' };
    if (method === 'thread/fork') {
      const value = thread(randomUUID(), { source: 'appServer', forkedFromId: params.threadId });
      threads.set(value.id, value); return { thread: value, cwd, sandbox: { type: 'readOnly' },
        approvalPolicy: 'on-request', approvalsReviewer: 'user' };
    }
    if (method === 'turn/start') return { turn: { id: randomUUID(), status: 'inProgress' } };
    return {};
  };
  const config = { stateDir: path.join(directory, 'state'), host: '127.0.0.1', token: randomBytes(32).toString('base64url'),
    workspaces: [{ id: 'project', name: 'Project', path: cwd }] };
  const core = new BridgeCore(config, rpc); await core.initialize();
  t.after(() => { core.close(); rmSync(directory, { recursive: true, force: true }); });
  return { directory, cwd, outside, config, core, rpc, threads, thread, calls };
}
const forkBody = () => ({ requestId: randomUUID(), workspaceId: 'project', model: 'test', effort: 'medium', mode: 'read-only' });

test('list is paginated and restricted to authorized directories and interactive parent sessions', async t => {
  const { core, threads, thread, cwd, calls } = await fixture(t);
  threads.set('subagent', thread('subagent', { parentThreadId: 'pc-1', source: { subAgent: 'thread_spawn' } }));
  threads.set('ephemeral', thread('ephemeral', { ephemeral: true }));
  core.tasks.set('owned', { id: 'owned', title: '', status: 'idle', items: [] });
  threads.set('owned', thread('owned'));
  const result = await core.history.list('opaque');
  assert.deepEqual(result.threads.map(item => item.id), ['pc-1']);
  assert.equal(result.threads[0].updatedAt, 100000);
  assert.equal(result.nextThreadCursor, 'next-page');
  assert.equal(JSON.stringify(result).includes(cwd), false);
  const call = calls.find(call => call.method === 'thread/list');
  assert.deepEqual(call.params.cwd, [cwd]); assert.equal(call.params.cursor, 'opaque');
  assert.ok(call.params.sourceKinds.includes('appServer'));
  await assert.rejects(core.history.list('\ninvalid'), /cursor/);
});

test('reading does not resume or mutate original sessions and denies out-of-scope item reads', async t => {
  const { core, calls, threads, thread, outside, cwd } = await fixture(t);
  const preview = await core.history.read('pc-1');
  assert.equal(preview.external, true); assert.equal(preview.mode, 'workspace-write'); assert.equal(preview.approvalMode, 'ask');
  assert.deepEqual(preview.items.map(item => item.kind), ['user', 'assistant']);
  assert.equal(preview.items[0].text, 'Saved question\n[图片]');
  assert.equal(preview.historyCursor, 'items:older');
  assert.equal(core.tasks.size, 0);
  assert.equal(calls.some(call => ['thread/resume', 'thread/fork', 'turn/start'].includes(call.method)), false);
  const count = calls.filter(call => call.method === 'thread/items/list').length;
  await assert.rejects(core.history.read('outside'), /已授权/);
  assert.equal(calls.filter(call => call.method === 'thread/items/list').length, count);
  const junction = path.join(cwd, 'junction'); symlinkSync(outside, junction, process.platform === 'win32' ? 'junction' : 'dir');
  threads.set('junction', thread('junction', { cwd: junction }));
  await assert.rejects(core.history.read('junction'), /已授权/);
  await assert.rejects(core.history.read('pc-1', 'arbitrary'), /cursor/);
});

test('legacy turn pagination is used only for unsupported item pagination; chronology and cursor survive', async t => {
  const { core, rpc, calls } = await fixture(t); const original = rpc.request;
  rpc.request = async (method, params) => {
    if (method === 'thread/items/list') throw new Error('thread/items/list is not supported for legacy threads');
    if (method === 'thread/turns/list') { calls.push({ method, params }); return { data: [{ id: 'turn-old', items: [
      { id: 'u', type: 'userMessage', content: [{ type: 'text', text: 'old question' }] },
      { id: 'a', type: 'agentMessage', text: 'old reply' }] }], nextCursor: 'older-turn' }; }
    return original(method, params);
  };
  const result = await core.history.read('pc-1');
  assert.deepEqual(result.items.map(item => item.text), ['old question', 'old reply']);
  assert.equal(result.historyCursor, 'turns:older-turn');
  await core.history.read('pc-1', result.historyCursor);
  assert.equal(calls.filter(call => call.method === 'thread/turns/list').at(-1).params.cursor, 'older-turn');
  rpc.request = async (method, params) => { if (method === 'thread/items/list') throw new Error('transport timed out'); return original(method, params); };
  await assert.rejects(core.history.read('pc-1'), /timed out/);
});

test('authorization is rechecked after content paging and no stale history is returned', async t => {
  const { core, rpc, threads, outside } = await fixture(t); const original = rpc.request;
  rpc.request = async (method, params) => {
    const result = await original(method, params);
    if (method === 'thread/items/list') threads.get('pc-1').cwd = outside;
    return result;
  };
  await assert.rejects(core.history.read('pc-1'), /已授权/);
});

test('fork retains context, has independent controlled permissions and is idempotent across bridge restart', async t => {
  const { core, rpc, calls, config, threads } = await fixture(t);
  threads.get('pc-1').status = { type: 'active', activeFlags: [] };
  const body = forkBody(); const task = await core.history.fork('pc-1', { ...body, approvalPolicy: 'never', cwd: '/' });
  assert.notEqual(task.id, 'pc-1'); assert.equal(task.sourceThreadId, 'pc-1'); assert.equal(task.mode, 'read-only');
  assert.equal(task.items[0].kind, 'user'); assert.equal(task.external, undefined);
  const call = calls.find(call => call.method === 'thread/fork');
  assert.equal(call.params.approvalPolicy, 'on-request'); assert.equal(call.params.approvalsReviewer, 'user');
  assert.equal(call.params.sandbox, 'read-only'); assert.equal(call.params.excludeTurns, true);
  assert.equal(calls.some(call => call.method === 'thread/resume'), false);
  assert.equal(await core.history.fork('pc-1', body), task);
  await assert.rejects(core.history.fork('pc-1', { ...body, mode: 'workspace-write' }), /导入编号/);
  const restored = new BridgeCore(config, rpc); await restored.initialize();
  assert.equal((await restored.history.fork('pc-1', body)).id, task.id);
  restored.close();
  assert.equal(calls.filter(call => call.method === 'thread/fork').length, 1);
  await core.start(task.id, { requestId: randomUUID(), text: 'continue', attachments: [], model: 'test', effort: 'medium' });
  assert.equal(calls.find(call => call.method === 'turn/start').params.threadId, task.id);
  assert.equal(threads.get('pc-1').status.type, 'active');
});

test('curated history routes require auth and reject arbitrary query/RPC parameters', async t => {
  const { core, config } = await fixture(t);
  let forkError; const originalFork = core.history.fork.bind(core.history);
  core.history.fork = async (...args) => { try { return await originalFork(...args); } catch (error) { forkError = error; throw error; } };
  const server = createBridgeServer(config, core);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const root = `http://127.0.0.1:${server.address().port}`;
  const headers = { Authorization: 'Bearer ' + config.token, 'Content-Type': 'application/json' };
  assert.equal((await fetch(root + '/v1/threads')).status, 401);
  for (const suffix of ['?cwd=/', '?cursor=a&cursor=b', '?token=secret']) assert.equal((await fetch(root + '/v1/threads' + suffix, { headers })).status, 400);
  assert.equal((await fetch(root + '/v1/threads/outside', { headers })).status, 404);
  const listed = await (await fetch(root + '/v1/threads', { headers })).json(); assert.equal(listed.threads[0].id, 'pc-1');
  const preview = await (await fetch(root + '/v1/threads/pc-1', { headers })).json(); assert.equal(preview.task.external, true);
  const body = forkBody();
  assert.equal((await fetch(root + '/v1/threads/pc-1/fork', { method: 'POST', headers, body: JSON.stringify(body) })).status, 201, forkError?.stack);
  assert.equal((await fetch(root + '/v1/threads/pc-1/fork?cwd=/', { method: 'POST', headers, body: JSON.stringify(body) })).status, 400);
});

test('concurrent imports and uncertain RPC results cannot silently fork twice', async t => {
  const { core, rpc, calls, config } = await fixture(t); const original = rpc.request;
  let entered; const entering = new Promise(resolve => { entered = resolve; }); let release;
  const waiting = new Promise(resolve => { release = resolve; });
  rpc.request = async (method, params) => {
    if (method === 'thread/fork') { entered(); await waiting; throw new Error('Codex thread/fork timed out'); }
    return original(method, params);
  };
  const body = forkBody(); const pending = core.history.fork('pc-1', body); await entering;
  await assert.rejects(core.history.fork('pc-1', forkBody()), /正在导入/);
  release(); await assert.rejects(pending, /timed out/);
  await assert.rejects(core.history.fork('pc-1', body), /尚未确认/);
  const restored = new BridgeCore(config, rpc); await restored.initialize();
  try { await assert.rejects(restored.history.fork('pc-1', body), /尚未确认/); } finally { restored.close(); }
  assert.equal(calls.some(call => call.method === 'turn/start'), false);
});

test('source permissions cannot bypass the mobile sandbox policy', async t => {
  const { core, rpc, calls } = await fixture(t); const original = rpc.request;
  await assert.rejects(core.history.fork('pc-1', { ...forkBody(), mode: 'danger-full-access' }), /sandbox/);
  await assert.rejects(core.history.fork('outside', forkBody()), /已授权/);
  assert.equal(calls.some(call => call.method === 'thread/fork'), false);
  rpc.request = async (method, params) => {
    const result = await original(method, params);
    return method === 'thread/fork' ? { ...result, sandbox: { type: 'dangerFullAccess' } } : result;
  };
  await assert.rejects(core.history.fork('pc-1', forkBody()), /权限不匹配/);
  assert.equal(core.tasks.size, 0);
  assert.equal(calls.some(call => call.method === 'turn/start'), false);
});
