import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, symlinkSync, statSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import https from 'node:https';
import { BridgeCore, MAX_FILE_BYTES } from '../core.mjs';
import { createBridgeServer, initializeConfig } from '../server.mjs';

class FakeRpc extends EventEmitter {
  calls = [];
  sent = [];
  async initialize() {}
  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'model/list') return { data: [{ id: 'test', model: 'test', displayName: 'Test',
      defaultReasoningEffort: 'medium', supportedReasoningEfforts: [{ reasoningEffort: 'medium' }],
      inputModalities: ['text', 'image'] }], nextCursor: null };
    if (method === 'thread/start') return { thread: { id: randomUUID() } };
    if (method === 'thread/resume') return { thread: { id: params.threadId } };
    if (method === 'turn/start') return { turn: { id: randomUUID(), status: 'inProgress' } };
    return {};
  }
  send(message) { this.sent.push(message); }
  close() {}
}
async function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-bridge-test-'));
  const workspace = path.join(dir, 'project'); mkdirSync(workspace);
  const config = { token: randomBytes(32).toString('base64url'), host: '127.0.0.1',
    stateDir: path.join(dir, 'private-state'), workspaces: [{ id: 'project', name: 'Project', path: workspace }] };
  const rpc = new FakeRpc(); const core = new BridgeCore(config, rpc); await core.initialize();
  t.after(() => { core.close(); rmSync(dir, { recursive: true, force: true }); });
  return { dir, workspace, config, rpc, core };
}
const createBody = { workspaceId: 'project', model: 'test', effort: 'medium', mode: 'workspace-write' };
const turnBody = () => ({ requestId: randomUUID(), text: '修复这个问题', attachments: [], model: 'test', effort: 'medium' });

test('server binds only loopback without TLS and rejects weak tokens', async t => {
  const { config, core } = await fixture(t);
  assert.throws(() => createBridgeServer({ ...config, host: '0.0.0.0' }, core), /require TLS/);
  assert.throws(() => createBridgeServer({ ...config, token: 'password' }, core), /256 bits/);
});

test('HTTPS listener accepts a trusted matching certificate and enforces bearer auth', async t => {
  const { dir, config, core } = await fixture(t);
  const cert = path.join(dir, 'cert.pem'); const key = path.join(dir, 'key.pem');
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', key, '-out', cert], { stdio: 'ignore' });
  } catch (e) { if (e.code === 'ENOENT') return t.skip('OpenSSL not installed'); throw e; }
  const server = createBridgeServer({ ...config, tls: { cert, key } }, core);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const request = token => new Promise((resolve, reject) => {
    https.get({ hostname: '127.0.0.1', port: server.address().port, path: '/v1/info',
      ca: readFileSync(cert), headers: { Authorization: `Bearer ${token}` } }, response => {
      response.resume(); response.on('end', () => resolve(response.statusCode));
    }).on('error', reject);
  });
  assert.equal(await request(config.token), 200);
  assert.equal(await request('wrong'), 401);
});

test('HTTP auth, origin rejection, curated routes, media type and status snapshot', async t => {
  const { config, core } = await fixture(t);
  const server = createBridgeServer(config, core);
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const root = `http://127.0.0.1:${server.address().port}`;
  const headers = { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' };
  assert.equal((await fetch(root + '/v1/info')).status, 401);
  assert.equal((await fetch(root + '/v1/info', { headers: { ...headers, Origin: 'https://evil.invalid' } })).status, 403);
  const info = await fetch(root + '/v1/info', { headers });
  assert.equal(info.headers.get('cache-control'), 'no-store');
  assert.equal((await info.json()).protocol, 1);
  assert.equal((await fetch(root + '/v1/rpc', { method: 'POST', headers, body: '{}' })).status, 404);
  assert.equal((await fetch(root + '/v1/tasks', { method: 'POST', headers: { Authorization: headers.Authorization }, body: '{}' })).status, 415);
  const created = await fetch(root + '/v1/tasks', { method: 'POST', headers, body: JSON.stringify(createBody) });
  assert.equal(created.status, 201);
  const { task } = await created.json();
  assert.equal((await (await fetch(root + `/v1/tasks/${task.id}?revision=${task.revision}`, { headers })).json()).unchanged, true);
  assert.equal((await fetch(root + '/v1/info?token=bad', { headers })).status, 400);
  const malformed = await fetch(root + '/v1/tasks', { method: 'POST', headers, body: '{bad' });
  assert.equal(malformed.status, 400);
});

test('workspaces/models/permissions are server controlled', async t => {
  const { core, rpc } = await fixture(t);
  await assert.rejects(core.create({ ...createBody, workspaceId: '../../etc' }), /Unknown workspace/);
  await assert.rejects(core.create({ ...createBody, model: 'arbitrary' }), /catalog/);
  await assert.rejects(core.create({ ...createBody, effort: 'unlimited' }), /Unsupported/);
  await assert.rejects(core.create({ ...createBody, mode: 'danger-full-access' }), /sandbox/);
  const task = await core.create(createBody);
  await core.start(task.id, { ...turnBody(), cwd: '/etc', approvalPolicy: 'never', sandboxPolicy: { type: 'dangerFullAccess' } });
  const call = rpc.calls.find(c => c.method === 'turn/start');
  assert.equal(call.params.cwd, task.cwd);
  assert.equal(call.params.approvalPolicy, 'on-request');
  assert.equal(call.params.sandboxPolicy.networkAccess, false);
  assert.deepEqual(call.params.sandboxPolicy.writableRoots, [task.cwd]);
});

test('upload is bounded, exclusive, detects image bytes and cannot cross workspace', async t => {
  const { core, workspace, config, rpc } = await fixture(t);
  const png = Buffer.from([137,80,78,71,13,10,26,10,0,0,0,0]);
  const upload = await core.upload({ workspaceId: 'project', name: '图.png', base64: png.toString('base64'), image: true });
  const stored = core.uploads.get(upload.id);
  assert.deepEqual(readFileSync(stored.path), png);
  assert.ok(stored.path.startsWith(workspace + path.sep));
  assert.equal(statSync(stored.path).mode & 0o777, 0o600);
  await assert.rejects(core.upload({ workspaceId: 'project', name: '../attack', base64: 'dGVzdA==' }), /filename/);
  await assert.rejects(core.upload({ workspaceId: 'project', name: 'fake.png', base64: 'dGVzdA==', image: true }), /Images must/);
  await assert.rejects(core.upload({ workspaceId: 'project', name: 'x', base64: 'invalid!!!' }), /base64/);
  await assert.rejects(core.upload({ workspaceId: 'project', name: 'x', base64: Buffer.alloc(MAX_FILE_BYTES + 1).toString('base64') }), /8 MiB/);
  const task = await core.create(createBody);
  await core.start(task.id, { ...turnBody(), attachments: [upload.id] });
  assert.equal(rpc.calls.find(c => c.method === 'turn/start').params.input[1].type, 'localImage');
  core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { status: 'completed' } } });
  core.uploads.set('foreign', { ...stored, workspaceId: 'other' });
  await assert.rejects(core.start(task.id, { ...turnBody(), attachments: ['foreign'] }), /another workspace/);
  assert.throws(() => new BridgeCore({ ...config, stateDir: path.join(workspace, 'secrets') }, new FakeRpc()), /outside/);
});

test('large valid upload does not overflow regex stack', async t => {
  const { core } = await fixture(t);
  const upload = await core.upload({ workspaceId: 'project', name: 'large.bin', base64: Buffer.alloc(MAX_FILE_BYTES).toString('base64') });
  assert.equal(upload.size, MAX_FILE_BYTES);
});

test('image model modality is checked before submitting a turn', async t => {
  const { core } = await fixture(t);
  const upload = await core.upload({ workspaceId: 'project', name: 'x.png', image: true,
    base64: Buffer.from([137,80,78,71,13,10,26,10]).toString('base64') });
  core.models[0].inputModalities = ['text'];
  const task = await core.create(createBody);
  await assert.rejects(core.start(task.id, { ...turnBody(), attachments: [upload.id] }), /cannot accept images/);
});

test('idempotent retry never runs a second turn, rejects changed body and concurrent submit', async t => {
  const { core, rpc } = await fixture(t); const task = await core.create(createBody); const body = turnBody();
  await core.start(task.id, body);
  await core.start(task.id, body);
  assert.equal(rpc.calls.filter(c => c.method === 'turn/start').length, 1);
  await assert.rejects(core.start(task.id, { ...body, text: 'different' }), /different input/);
  await assert.rejects(core.start(task.id, turnBody()), /already running/);
});

test('assistant streaming, tool output, diff and terminal errors survive snapshots', async t => {
  const { core } = await fixture(t); const task = await core.create(createBody);
  for (const delta of ['hello ', 'world']) core.onMessage({ method: 'item/agentMessage/delta', params: { threadId: task.id, itemId: 'a', delta } });
  assert.equal(task.items[0].text, 'hello world');
  core.onMessage({ method: 'item/completed', params: { threadId: task.id, item: { id: 'a', type: 'agentMessage', text: 'authoritative' } } });
  assert.equal(task.items[0].text, 'authoritative');
  core.onMessage({ method: 'turn/diff/updated', params: { threadId: task.id, turnId: 't', diff: '+ changed' } });
  core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { status: 'failed', error: { message: 'limit exceeded' } } } });
  assert.equal(task.status, 'failed'); assert.equal(task.error, 'limit exceeded');
  assert.equal(task.items[1].kind, 'diff');
});

test('approvals require explicit scoped decisions; unknown requests fail closed', async t => {
  const { core, rpc } = await fixture(t); const task = await core.create(createBody);
  core.onMessage({ id: 99, method: 'item/commandExecution/requestApproval', params: { threadId: task.id, command: 'npm install', cwd: task.cwd } });
  assert.equal(task.status, 'waitingApproval');
  const approval = task.approvals[0];
  assert.throws(() => core.answer(task.id, { id: approval.id, decision: 'acceptForSession' }), /Invalid/);
  core.answer(task.id, { id: approval.id, decision: 'decline' });
  assert.deepEqual(rpc.sent.at(-1), { id: 99, result: { decision: 'decline' } });
  assert.throws(() => core.answer(task.id, { id: approval.id, decision: 'accept' }), /expired/);
  core.onMessage({ id: 100, method: 'item/permissions/requestApproval', params: { threadId: task.id } });
  assert.equal(rpc.sent.at(-1).error.code, -32601);
  assert.equal(task.approvals.length, 0);
});

test('question answers use Codex wire shape and require all questions', async t => {
  const { core, rpc } = await fixture(t); const task = await core.create(createBody);
  core.onMessage({ id: 'question', method: 'item/tool/requestUserInput', params: { threadId: task.id,
    questions: [{ id: 'q1', header: 'Scope', question: 'Which scope?' }] } });
  const id = task.approvals[0].id;
  assert.throws(() => core.answer(task.id, { id, decision: 'answer', answers: [] }), /every question/);
  core.answer(task.id, { id, decision: 'answer', answers: [{ id: 'q1', text: 'current project' }] });
  assert.deepEqual(rpc.sent.at(-1).result, { answers: { q1: { answers: ['current project'] } } });
});

test('oversized or constrained approval cannot be accepted on the phone', async t => {
  const { core } = await fixture(t); const task = await core.create(createBody);
  core.onMessage({ id: 11, method: 'item/commandExecution/requestApproval', params: { threadId: task.id,
    command: 'x'.repeat(18000) } });
  const first = task.approvals[0];
  assert.equal(first.canAccept, false);
  assert.throws(() => core.answer(task.id, { id: first.id, decision: 'accept' }), /cannot be safely approved/);
  core.onMessage({ id: 12, method: 'item/commandExecution/requestApproval', params: { threadId: task.id,
    availableDecisions: ['decline', 'cancel'] } });
  assert.equal(task.approvals[1].canAccept, false);
});

test('completion racing before turn/start response stays completed', async t => {
  const { core, rpc } = await fixture(t); const task = await core.create(createBody);
  const original = rpc.request.bind(rpc);
  rpc.request = async (method, params) => {
    if (method === 'turn/start') core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { status: 'completed' } } });
    return original(method, params);
  };
  await core.start(task.id, turnBody()); assert.equal(task.status, 'completed');
});

test('restart restores transcript and attachments, interrupts stale tasks and resumes with sandbox', async t => {
  const { core, config } = await fixture(t); const task = await core.create(createBody);
  await core.start(task.id, turnBody()); core.save();
  const rpc2 = new FakeRpc(); const core2 = new BridgeCore(config, rpc2); await core2.initialize();
  t.after(() => core2.close());
  assert.equal(core2.get(task.id).status, 'interrupted');
  assert.equal(core2.get(task.id).items[0].kind, 'user');
  await core2.start(task.id, turnBody());
  const resume = rpc2.calls.find(c => c.method === 'thread/resume');
  assert.equal(resume.params.sandbox, 'workspace-write');
  assert.equal(resume.params.approvalPolicy, 'on-request');
  core2.close();
});

test('config initialization uses fresh secret and never overwrites existing config', async t => {
  const { dir, workspace } = await fixture(t);
  const filename = path.join(dir, 'config.json');
  const config = initializeConfig(filename, workspace);
  assert.equal(config.token.length, 43);
  assert.equal(statSync(filename).mode & 0o777, 0o600);
  assert.throws(() => initializeConfig(filename, workspace), /EEXIST/);
});

test('symlink replacement of uploaded file is rejected before submission', async t => {
  const { core, dir } = await fixture(t); const task = await core.create(createBody);
  const upload = await core.upload({ workspaceId: 'project', name: 'data', base64: 'dGVzdA==' });
  const file = core.uploads.get(upload.id).path;
  const outside = path.join(dir, 'outside'); writeFileSync(outside, 'secret');
  rmSync(file); symlinkSync(outside, file);
  await assert.rejects(core.start(task.id, { ...turnBody(), attachments: [upload.id] }), /moved or replaced/);
});
