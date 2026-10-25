// Production ArkTS state-machine checks with a simulated bridge; no HAP build or device actions.
// node scripts/check_codex_chat_tool.cjs <typescript-module-path>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const codex = 'entry/src/main/ets/pages/codex/';
const cache = new Map(), disk = new Map(), storage = new Map();
const copy = value => JSON.parse(JSON.stringify(value));
const calls = [];
let handler, accepted = true, imageReads = 0, failDelivery = false;
const connection = { origin: 'https://pc:8787', token: 'private-token-never-to-model', caCertificate: 'private-ca' };
class MockClient {
  configure() {} close() {} cancelTaskUpdates() {} setArtifactChunkBytes() {}
  async call(route, body) { calls.push({ route, body: body && copy(body) }); return copy(await handler(route, body)); }
}
class MockDataStorage {
  readJson(file, fallback) { return disk.has(file) ? copy(disk.get(file)) : fallback; }
  writeJsonAtomic(file, value) { disk.set(file, copy(value)); }
}
const chatStorage = { sessionExists: () => true, sessionAssetsDir: (dir, id) => `${dir}/chat-sessions/assets/${id}` };
const privacy = { requireAccepted: () => { if (!accepted) throw new Error('Privacy refused'); }, isAccepted: () => accepted };
const mocks = {
  '@kit.ArkTS': { JSON, util: { generateRandomUUID: () => randomUUID(), Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
  } } },
  '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 1 }, open: async () => ({ fd: 1 }), close: async () => {},
    stat: async () => ({ size: 3 }), read: async (_fd, buffer) => { imageReads++; new Uint8Array(buffer).fill(1); return buffer.byteLength; } } }
};
function load(file) {
  file = path.resolve(root, file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const name = path.basename(file);
  const special = {
    'CodexClient.ets': { CodexClient: MockClient },
    'CodexCredentialStore.ets': { CodexCredentialStore: { load: async () => connection } },
    'PrivacyConsent.ets': { PrivacyConsent: privacy },
    'DataManagerStorage.ets': { DataManagerStorage: MockDataStorage },
    'ChatSessionStorage.ets': { ChatSessionStorage: chatStorage },
    'CloudModelClient.ets': { cloudPlannerApiKey: config => config.plannerApiKey },
    'CodexArtifactStore.ets': { validateCodexArtifact: artifact => { assert.ok(artifact.id && artifact.name && artifact.size > 0); },
      CodexArtifactStore: { create: async () => ({ receive: async (_task, artifact, _client, current) => {
        assert.equal(current(), true); if (failDelivery) throw new Error('Download failed');
        return { ...artifact, localPath: '/sandbox/codex/' + artifact.id + '/' + artifact.name };
      } }) } },
    'JsonCompat.ets': { parseJsonCompat: JSON.parse, stringifyJsonCompat: JSON.stringify }
  };
  if (special[name]) return special[name];
  const source = fs.readFileSync(file, 'utf8');
  const result = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } });
  assert.deepEqual((result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const module = { exports: {} }; cache.set(file, module.exports);
  vm.runInNewContext(result.outputText, { module, exports: module.exports,
    require: name => mocks[name] || load(path.resolve(path.dirname(file), name)), console,
    setTimeout: fn => { queueMicrotask(fn); return 1; },
    AppStorage: { setOrCreate: (k, v) => storage.set(k, v), get: k => storage.get(k) }
  }, { filename: file });
  return module.exports;
}
const { CodexChatService } = load(codex + 'CodexChatService');
const { CodexChatStore } = load(codex + 'CodexChatStore');
const toolModule = load('entry/src/main/ets/utils/CodexTaskTool');
const { ChatToolRegistry } = load('entry/src/main/ets/utils/ChatToolRegistry');
const tool = toolModule.createCodexTaskTool();
let sequence = 0;
function env() {
  const dir = '/sandbox/test-' + (++sequence);
  const service = CodexChatService.get(dir);
  const store = new CodexChatStore(dir);
  let created;
  const execution = { sessionId: 'chat-a', imagePaths: [], selectTarget: async () => ({ connectionId: 'pc-a', workspaceId: 'work' }),
    onCreated: run => { created = run.id; }, isCancelled: () => false };
  return { dir, service, store, execution, id: () => created };
}
function backend() {
  calls.length = 0;
  const tasks = new Map(); let n = 0;
  const info = { ready: true, name: 'Test PC', workspaces: [{ id: 'work', name: 'Project' }],
    models: [{ id: 'm', model: 'codex-model', isDefault: true, defaultReasoningEffort: 'medium' }],
    permissionSettingsSupported: true, artifactsSupported: true, taskUpdatesSupported: true, taskDeltaSupported: true };
  const file = (turnId, id = 'final') => ({ id, turnId, name: id + '.pptx', size: 10,
    mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', sha256: 'a'.repeat(64), createdAt: Date.now() });
  const finish = task => {
    task.status = 'completed'; task.revision++;
    task.items.push({ id: task.turnId + ':answer', kind: 'assistant', turnId: task.turnId, text: 'Created final presentation.' });
    task.artifacts.push(file(task.turnId, 'final-' + task.turnId)); return { task };
  };
  const call = async (route, body) => {
    if (route === '/v1/info') return info;
    if (route === '/v1/tasks') {
      const task = { id: 'session-' + (++n), title: 'New', status: 'idle', workspaceId: body.workspaceId,
        model: body.model, effort: body.effort, mode: body.mode, approvalMode: body.approvalMode, turnId: '',
        items: [], approvals: [], artifacts: [file('old', 'old-file')], updatedAt: Date.now(), revision: 1, error: '' };
      tasks.set(task.id, task); return { task };
    }
    if (route === '/v1/attachments') return { attachment: { id: 'upload-1' } };
    const task = tasks.get(route.split('?')[0].split('/')[3]);
    assert.ok(task, route);
    if (route.endsWith('/turns')) {
      task.lastRequestId = body.requestId; task.turnId = 'turn-' + task.revision;
      task.revision++; task.status = 'running'; return { task };
    }
    if (route.endsWith('/interrupt')) { task.status = 'interrupted'; task.approvals = []; task.revision++; return { task }; }
    if (route.endsWith('/approvals')) { task.approvals = []; return finish(task); }
    return task.status === 'running' ? finish(task) : { task };
  };
  handler = call;
  return { tasks, info, finish, call };
}
const request = { task: 'Create a presentation', continueRunId: '' };
async function main() {
  // Default creates isolated sessions, fixed permissions, only this turn's final files.
  backend(); let e = env();
  let result = await e.service.execute(request, e.execution);
  assert.equal(result.status, 'completed', result.error); assert.equal(result.received, 1);
  assert.equal(result.files[0].turnId, e.store.load(result.runId).turnId);
  assert.equal(result.files.some(f => f.id === 'old-file'), false);
  assert.equal(e.service.isActive(result.runId), false);
  assert.equal(e.store.load(result.runId).task.items.length, 0, 'intermediate remote transcripts are not persisted');
  let post = calls.find(c => c.route === '/v1/tasks');
  assert.equal(post.body.mode, 'workspace-write'); assert.equal(post.body.approvalMode, 'ask');
  const first = result;
  result = await e.service.execute(request, e.execution);
  assert.notEqual(e.store.load(result.runId).taskId, e.store.load(first.runId).taskId);
  const creates = calls.filter(c => c.route === '/v1/tasks').length;
  // Continuation uses original remote session but a NEW local result card.
  result = await e.service.execute({ task: 'Revise slide two', continueRunId: first.runId }, e.execution);
  assert.equal(result.status, 'completed'); assert.notEqual(result.runId, first.runId);
  assert.equal(e.store.load(result.runId).taskId, e.store.load(first.runId).taskId);
  assert.equal(calls.filter(c => c.route === '/v1/tasks').length, creates);
  assert.equal(e.store.load(first.runId).artifacts.length, 1);
  assert.equal(result.files.length, 1, 'prior turn deliveries must not attach to a revision');
  // Cross-chat IDs, malformed IDs and rejected user selections never submit.
  const count = calls.length;
  const invalid = await e.service.execute({ ...request, continueRunId: first.runId }, { ...e.execution, sessionId: 'other-chat' });
  assert.equal(invalid.status, 'failed'); assert.equal(calls.length, count);
  const rejected = await e.service.execute(request, { ...e.execution, selectTarget: async () => null });
  assert.equal(rejected.status, 'rejected'); assert.equal(calls.length, count);
  assert.throws(() => toolModule.parseCodexTaskArguments('{"task":"x","continue_run_id":"../../task"}'));
  assert.throws(() => toolModule.parseCodexTaskArguments('{"task":"x","mode":"full"}'));
  // Timeout AFTER a successful turn submission: reconcile, don't re-send.
  let b = backend(); e = env();
  handler = async (route, body) => { const value = await b.call(route, body); if (route.endsWith('/turns')) throw new Error('timeout'); return value; };
  result = await e.service.execute(request, e.execution);
  assert.equal(result.status, 'completed'); assert.equal(calls.filter(c => c.route.endsWith('/turns')).length, 1);
  // Timeout BEFORE acceptance: unknown remains unknown, including manual sync.
  b = backend(); e = env();
  handler = async (route, body) => { if (route.endsWith('/turns')) throw new Error('timeout'); return b.call(route, body); };
  result = await e.service.execute(request, e.execution);
  assert.equal(result.status, 'disconnected');
  await assert.rejects(e.service.synchronize(result.runId));
  assert.equal(calls.filter(c => c.route.endsWith('/turns')).length, 1);
  // Interrupted polling can recover by GET and receive final files, never another POST.
  b = backend(); e = env(); let drop = true;
  handler = async (route, body) => { if (route.includes('?') && drop) throw new Error('network lost'); return b.call(route, body); };
  result = await e.service.execute(request, e.execution); assert.equal(result.status, 'disconnected');
  const mutations = calls.filter(c => c.body).length; drop = false;
  await e.service.synchronize(result.runId);
  assert.equal(e.store.load(result.runId).status, 'completed'); assert.equal(e.store.load(result.runId).files.length, 1);
  assert.equal(calls.filter(c => c.body).length, mutations);
  // Generation success is not delivery success; retry only missing/reusable files.
  backend(); e = env(); failDelivery = true;
  result = await e.service.execute(request, e.execution);
  assert.equal(result.status, 'completed'); assert.equal(result.ok, false); assert.equal(result.received, 0);
  assert.equal(JSON.parse(toolModule.codexTaskToolPayload(result)).files[0].saved_on_phone, false);
  failDelivery = false; await e.service.synchronize(result.runId);
  assert.equal(e.store.load(result.runId).files.length, 1);
  // User stop during submission propagates an interrupt and terminates the tool loop.
  b = backend(); e = env();
  handler = async (route, body) => { const value = await b.call(route, body);
    if (route.endsWith('/turns')) e.service.stopSession('chat-a'); return value; };
  result = await e.service.execute(request, e.execution);
  assert.equal(result.status, 'cancelled'); assert.equal(calls.filter(c => c.route.endsWith('/interrupt')).length, 1);
  assert.match(tool.terminalResultMessage(toolModule.codexTaskToolPayload(result)), /取消/);
  // Waiting approval is surfaced and requires a distinct human answer.
  b = backend(); e = env(); let polled = 0;
  handler = async (route, body) => {
    if (route.includes('?')) {
      const task = [...b.tasks.values()][0];
      if (++polled === 1) { task.status = 'waitingApproval'; task.approvals = [{ id: 'approve-1', kind: 'command', title: 'Confirm', detail: '', questions: [] }]; task.revision++; return { task }; }
      assert.equal(calls.filter(c => c.route.endsWith('/approvals')).length, 0, 'never auto approve');
      await e.service.answer(e.id(), 'approve-1', 'accept', []);
      return { task };
    }
    return b.call(route, body);
  };
  result = await e.service.execute(request, e.execution); assert.equal(result.status, 'completed');
  assert.equal(calls.filter(c => c.route.endsWith('/approvals')).length, 1);
  // Scope uploads to user-adopted current-session images, including file:// URIs.
  backend(); e = env(); imageReads = 0;
  result = await e.service.execute(request, { ...e.execution, imagePaths: ['file://' + e.dir + '/chat-sessions/assets/chat-a/photo.png'] });
  assert.equal(result.status, 'completed'); assert.equal(imageReads, 1);
  assert.equal(calls.find(c => c.route.endsWith('/turns')).body.attachments[0], 'upload-1');
  backend(); e = env();
  result = await e.service.execute(request, { ...e.execution, imagePaths: ['/sandbox/other-chat/private.png'] });
  assert.equal(result.status, 'failed'); assert.equal(calls.filter(c => c.route === '/v1/attachments' || c.route.endsWith('/turns')).length, 0);
  // Old connector / revoked privacy fail closed before execution.
  b = backend(); e = env(); b.info.permissionSettingsSupported = false;
  result = await e.service.execute(request, e.execution); assert.equal(result.status, 'failed');
  assert.equal(calls.filter(c => c.body).length, 0);
  backend(); e = env(); accepted = false;
  result = await e.service.execute(request, e.execution); accepted = true;
  assert.equal(result.status, 'failed'); assert.equal(calls.length, 0);
  // JSON stays valid under the registry's limit, even with escaped control chars.
  for (const text of ['x'.repeat(50000), '\u0000'.repeat(50000), '中文"\\'.repeat(10000)]) {
    const payload = toolModule.codexTaskToolPayload({ ...first, summary: text, error: text, computer: text });
    assert.ok(payload.length <= 3900); JSON.parse(payload);
    assert.equal(payload.includes(connection.token), false); assert.equal(payload.includes('/sandbox/'), false);
  }
  const registry = new ChatToolRegistry(); registry.registerTool(tool);
  const delegated = await registry.executeToolCall({ id: 'call-1', function: { name: 'run_codex_task', arguments: '{"task":"Build a PPT"}' } },
    { filesDir: e.dir, sessionId: 'chat-a', userMessage: 'Build a PPT', runCodexTask: async () => ({ ...first, status: 'disconnected' }) });
  assert.equal(delegated.terminal, true, 'network ambiguity stops automatic model retries');
  JSON.parse(delegated.content);
  // Actual ReAct plumbing sends Codex output back to the phone Agent for another decision.
  const { ChatReactAgent } = load('entry/src/main/ets/utils/ChatReactAgent');
  let completions = 0, invocations = 0;
  const client = { chatCompletion: async options => {
    completions++;
    if (completions === 1) return { content: '', toolCalls: [{ id: 'delegate', function: {
      name: 'run_codex_task', arguments: '{"task":"Build a PPT"}' } }],
      assistantMessage: { role: 'assistant', content: '' }, finishReason: 'tool_calls' };
    const response = options.messages.find(message => message.role === 'tool');
    assert.equal(JSON.parse(response.content).run_id, first.runId);
    return { content: 'Reviewed the Codex result.', toolCalls: [], finishReason: 'stop' };
  } };
  const react = new ChatReactAgent(client, registry);
  const reviewed = await react.run([{ role: 'user', content: 'Build a PPT' }], { plannerBaseUrl: 'https://model', plannerApiKey: 'test', plannerModel: 'model' },
    { sessionId: 'chat-a', runCodexTask: async req => { invocations++; assert.equal(req.task, 'Build a PPT'); return first; } });
  assert.equal(invocations, 1); assert.equal(completions, 2); assert.equal(reviewed.content, 'Reviewed the Codex result.');
  // Message normalization and update paths must preserve the link to the card.
  for (const file of ['entry/src/main/ets/pages/chat/ChatSessionController.ets', 'entry/src/main/ets/utils/ChatSessionStorage.ets',
    'entry/src/main/ets/pages/chat/ChatMessageUiModel.ets']) assert.match(fs.readFileSync(path.join(root, file), 'utf8'), /codexRunId/);
  console.log('Codex chat tool checks passed: isolation, scoped continuation, permissions, timeout recovery, stop, approvals, uploads, delivery binding and bounded JSON.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
