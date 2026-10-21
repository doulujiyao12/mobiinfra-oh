import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, linkSync } from 'node:fs';
import { randomBytes, createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { ArtifactStore, finalFileLinks, ARTIFACT_CHUNK_BYTES } from '../artifacts.mjs';
import { BridgeCore } from '../core.mjs';
import { createBridgeServer } from '../server.mjs';

function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-artifacts-'));
  const cwd = path.join(directory, 'workspace'); mkdirSync(cwd);
  const privateDir = path.join(directory, 'state'); mkdirSync(privateDir);
  const store = new ArtifactStore(privateDir);
  const beforeCleanup = [];
  t.after(() => { for (const action of beforeCleanup) action(); rmSync(directory, { recursive: true, force: true }); });
  return { directory, cwd, privateDir, store, beforeCleanup, task: { id: 'session-a', turnId: 'turn-a', cwd } };
}
const link = filename => `[成品](<${filename}>)`;

test('final file links support spaces, Unicode, encoded paths and nested parentheses; fenced examples are ignored', () => {
  assert.deepEqual(finalFileLinks('[报告](outputs/计划%20A.pdf) [表](outputs/data\(1\).xlsx) [图](outputs/img(2).png)'),
    ['outputs/计划%20A.pdf', 'outputs/data(1).xlsx', 'outputs/img(2).png']);
  assert.deepEqual(finalFileLinks('```md\n[fake](tmp.pdf)\n```\n[real](<outputs/最终 版本.docx>)'), ['outputs/最终 版本.docx']);
});

test('only explicitly linked, supported final files are snapshotted and survive original changes/restarts', t => {
  const { cwd, privateDir, store, task } = fixture(t);
  const files = ['slides.pptx', 'report.pdf', '文档.docx', 'table.xlsx', 'picture.png', 'notes.txt'];
  for (const filename of files) writeFileSync(path.join(cwd, filename), Buffer.from(filename));
  writeFileSync(path.join(cwd, 'unlinked.pdf'), 'not delivered');
  mkdirSync(path.join(cwd, 'tmp')); writeFileSync(path.join(cwd, 'tmp', 'draft.pdf'), 'temporary');
  const result = store.publish(task, files.map(name => link(path.join(cwd, name))).join('\n') + '\n' +
    link(path.join(cwd, 'tmp', 'draft.pdf')) + '\n[remote](https://example.com/p.pdf)');
  assert.equal(result.artifacts.length, files.length);
  const first = result.artifacts[0];
  assert.equal(first.sha256, createHash('sha256').update(files[0]).digest('hex'));
  assert.equal(JSON.stringify(first).includes(cwd), false, 'metadata never reveals the source path');
  writeFileSync(path.join(cwd, files[0]), 'changed');
  assert.equal(Buffer.from(store.chunk(task.id, first.id, 0).base64, 'base64').toString(), files[0]);
  const restored = new ArtifactStore(privateDir);
  assert.equal(restored.chunk(task.id, first.id, 0).sha256, first.sha256);
  assert.equal(restored.chunk('other-session', first.id, 0), null);
});

test('path traversal, outside files, hidden directories, uploads, symlinks and hard links are rejected', t => {
  const { directory, cwd, store, task } = fixture(t);
  const outside = path.join(directory, 'private.pdf'); writeFileSync(outside, 'secret');
  for (const dir of ['.git', '.clawmate-upload-a', 'node_modules', '.codex-tmp']) {
    mkdirSync(path.join(cwd, dir)); writeFileSync(path.join(cwd, dir, 'secret.pdf'), 'secret');
  }
  const destinations = ['../private.pdf', ...['.git', '.clawmate-upload-a', 'node_modules', '.codex-tmp'].map(dir => dir + '/secret.pdf')];
  linkSync(outside, path.join(cwd, 'hard.pdf')); destinations.push('hard.pdf');
  try { symlinkSync(outside, path.join(cwd, 'linked.pdf')); destinations.push('linked.pdf'); } catch (error) {
    if (error.code !== 'EPERM') throw error;
  }
  const outsideDir = path.join(directory, 'outside-dir'); mkdirSync(outsideDir); writeFileSync(path.join(outsideDir, 'secret.pdf'), 'secret');
  symlinkSync(outsideDir, path.join(cwd, 'junction'), process.platform === 'win32' ? 'junction' : 'dir');
  destinations.push('junction/secret.pdf');
  assert.equal(store.publish(task, destinations.map(link).join('\n')).artifacts.length, 0);
});

test('chunk boundaries and hash describe exact bytes; auth, task ownership and offset validation are enforced', async t => {
  const { cwd, privateDir, store, task } = fixture(t);
  const content = randomBytes(ARTIFACT_CHUNK_BYTES + 37); writeFileSync(path.join(cwd, 'report.pdf'), content);
  const artifact = store.publish(task, '[PDF](report.pdf)').artifacts[0];
  const one = store.chunk(task.id, artifact.id, 0); const two = store.chunk(task.id, artifact.id, ARTIFACT_CHUNK_BYTES);
  assert.deepEqual(Buffer.concat([Buffer.from(one.base64, 'base64'), Buffer.from(two.base64, 'base64')]), content);
  assert.throws(() => store.chunk(task.id, artifact.id, -1));
  assert.throws(() => store.chunk(task.id, artifact.id, content.length));
  const token = randomBytes(32).toString('base64url');
  const core = { artifacts: store, get: id => { if (!['session-a', 'other-session'].includes(id)) throw new Error('Missing'); } };
  const server = createBridgeServer({ host: '127.0.0.1', token }, core);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/v1/tasks/`;
  const headers = { Authorization: 'Bearer ' + token };
  assert.equal((await fetch(base + task.id + '/artifacts/' + artifact.id + '?offset=0')).status, 401);
  assert.equal((await fetch(base + 'other-session/artifacts/' + artifact.id + '?offset=0', { headers })).status, 404);
  assert.equal((await fetch(base + task.id + '/artifacts/' + artifact.id + '?offset=0&offset=1', { headers })).status, 400);
  assert.equal((await fetch(base + task.id + '/artifacts/' + artifact.id + '?offset=0&path=secret', { headers })).status, 400);
  assert.equal((await fetch(base + task.id + '/artifacts/' + artifact.id + '?offset=0', { headers })).status, 200);
  const route = base + task.id + '/artifacts/' + artifact.id;
  const small = await (await fetch(route + '?offset=16384&length=65536', { headers })).json();
  assert.deepEqual(Buffer.from(small.artifactChunk.base64, 'base64'), content.subarray(16384, 16384 + 65536));
  for (const query of ['offset=0&length=1', 'offset=0&length=1048577', 'offset=0&length=65536&length=65536', 'offset=0&length=-1']) {
    assert.equal((await fetch(route + '?' + query, { headers })).status, 400);
  }
});

test('commentary, failed turns and unlinked intermediate files never become deliverables', async t => {
  const { cwd, privateDir, beforeCleanup } = fixture(t);
  const rpc = new EventEmitter(); rpc.close = () => {};
  const core = new BridgeCore({ stateDir: privateDir, workspaces: [{ id: 'p', name: 'P', path: cwd }] }, rpc);
  beforeCleanup.push(() => core.close());
  const task = { id: 'session-a', cwd, workspaceId: 'p', turnId: 'turn-a', status: 'running', items: [], approvals: [], revision: 0 };
  core.tasks.set(task.id, task); writeFileSync(path.join(cwd, 'final.pdf'), 'final');
  core.onMessage({ method: 'item/completed', params: { threadId: task.id, turnId: task.turnId,
    item: { id: 'comment', type: 'agentMessage', phase: 'commentary', text: '[draft](final.pdf)' } } });
  core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { id: task.turnId, status: 'completed' } } });
  assert.equal(task.artifacts?.length || 0, 0);
  core.onMessage({ method: 'item/completed', params: { threadId: task.id, turnId: task.turnId,
    item: { id: 'final', type: 'agentMessage', phase: 'final_answer', text: '[Final](final.pdf)' } } });
  core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { id: task.turnId, status: 'failed' } } });
  assert.equal(task.artifacts?.length || 0, 0);
  core.onMessage({ method: 'item/completed', params: { threadId: task.id, turnId: task.turnId,
    item: { id: 'final2', type: 'agentMessage', phase: 'final_answer', text: '[Final](final.pdf)' } } });
  core.onMessage({ method: 'turn/completed', params: { threadId: task.id, turn: { id: task.turnId, status: 'completed' } } });
  assert.equal(task.artifacts.length, 1);
});
