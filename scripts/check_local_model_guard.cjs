// Production readiness and send-entry checks with an in-memory filesystem.
// No model downloads, native inference, device actions or HAP builds.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8').replace(/\bstruct Index\b/, 'class Index');
const tree = ts.createSourceFile('Index.ts', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const component = tree.statements.find(item => ts.isClassDeclaration(item) && item.name?.text === 'Index');
const names = ['modelLoadableStatus','modelManifestLoadableStatus','hasModelWeightFile','isModelWeightFile',
  'ensureLocalChatModelIsAvailable','confirmModelScopeDownloadForLocalChat','ensureLocalModelLoaded',
  'sendLocalChatMessage','submitLocalAgentTask'];
const methods = names.map(name => {
  const method = component.members.find(item => ts.isMethodDeclaration(item) && item.name.getText(tree) === name);
  assert.ok(method, name); return method.getText(tree).replace(/\bprivate\s+/g, '');
}).join('\n');
const output = ts.transpileModule('export class Probe {\n' + methods + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(output.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const COMPLETE = 'complete.marker', MANIFEST = 'manifest.json';
const files = new Map(), calls = { dialogs: [], toasts: [], navigations: [], effects: [], loads: 0, reads: 0 };
let dialog = async () => ({ index: 0 });
const filesystem = {
  accessSync: filename => files.has(filename),
  statSync(filename) {
    calls.reads++; const value = files.get(filename); if (!value) throw Error('ENOENT');
    return { size: value.size, isFile: () => !value.directory, isDirectory: () => !!value.directory };
  },
  listFileSync(directory) { return [...files.keys()].filter(name => path.posix.dirname(name) === directory).map(name => path.posix.basename(name)); }
};
const exported = {};
vm.runInNewContext(output.outputText, { exports: exported, fs: filesystem,
  MODEL_DOWNLOAD_COMPLETE_FILE: COMPLETE, MODEL_DOWNLOAD_MANIFEST_FILE: MANIFEST,
  normalizeChatImageAttachments: items => items, LOCAL_CHAT_IMAGE_MAX_COUNT: 4,
  chatCanSendMessageWithImages: (text, images) => !!text.trim() || images.length > 0,
  SettingsSectionId: { ModelAgents: 2 }, MainTabIndex: { Chat: 2 },
  promptAction: { showDialog: options => { calls.dialogs.push(options); return dialog(options); } },
  AppTheme: { dialogText: color => color }, showToastSafely: text => calls.toasts.push(text),
  mnnllm: { loadModel: async () => { calls.loads++; return 'ok'; }, chat: () => { throw Error('inference must not start'); } },
  SelfHdcTestRunner: { shared: () => ({ snapshot: () => ({ running: false }) }) },
  AgentExecutionController: { isExecutionActive: () => false }
});
function add(filename, size = 128) {
  files.set(filename, { size });
  let parent = path.posix.dirname(filename);
  while (parent !== '/') { files.set(parent, { directory: true, size: 0 }); parent = path.posix.dirname(parent); }
}
function probe(directory = '/app/modelscope/owner__repo') {
  files.clear(); calls.dialogs.length = calls.toasts.length = calls.navigations.length = calls.effects.length = 0;
  calls.loads = calls.reads = 0; dialog = async () => ({ index: 0 });
  const app = new exported.Probe();
  Object.assign(app, { modelDir: directory, modelLoaded: false, downloading: false, modelScopeDownloading: false,
    modelManifest: null, localModelDownloadPromptVisible: false, userInput: '保留这条消息', localPendingChatImageUris: [],
    isThinking: false, localChatImagePreparing: false, localAgentCleaningUp: false, activeAgentRunner: null,
    activePhoneRunSession: null, restoringLocalSession: false,
    ensureAiServiceLogin: () => true, selectedAgentDeviceMode: () => 'phone',
    modelScopeRootDir: () => '/app/modelscope', readModelDownloadManifest: () => app.modelManifest,
    openSettingsFromTab: (section, origin) => calls.navigations.push({ section, origin }),
    downloadModelScopeModel: async () => { throw Error('a chat prompt must not start a download'); },
    ensureActiveChatSession: () => { calls.effects.push('session'); throw Error('no session before model readiness'); },
    appendActiveChatMessage: () => calls.effects.push('message'),
    ensureDesktopCompanionReminder: async () => { calls.effects.push('desktop'); return true; },
    reportLocalAgentStartupStatus: text => calls.toasts.push(text), reportLocalAgentCleanupStatus: text => calls.toasts.push(text),
    normalizedLocalNpuExecutionMode: () => 'cpu', prepareCustomOpp: () => true,
    prepareAllCpuRuntimeConfig: file => file, sleep: async () => {}
  }); return app;
}
const cases = [], test = (name, run) => cases.push([name, run]);
test('missing and partial managed downloads never pass from a cached loaded flag', async () => {
  for (const partial of [false, true]) {
    const app = probe(); app.modelLoaded = true;
    if (partial) { add(app.modelDir + '/config.json'); add(app.modelDir + '/vit.mnn'); }
    assert.equal(await app.ensureLocalChatModelIsAvailable(), false);
    assert.equal(app.modelLoaded, false); assert.equal(calls.dialogs.length, 1); assert.equal(calls.loads, 0);
    assert.equal(calls.dialogs[0].title, '请先下载本地模型'); assert.equal(app.userInput, '保留这条消息');
  }
});
test('all local send types stop before messages, sessions, image preparation or native calls', async () => {
  for (const images of [[], ['file:///private/photo.jpg']]) {
    const app = probe(); app.localPendingChatImageUris = images;
    await app.sendLocalChatMessage(); assert.equal(calls.dialogs.length, 1); assert.equal(calls.effects.length, 0);
    assert.equal(calls.loads, 0); assert.equal(app.userInput, '保留这条消息');
    assert.deepEqual(app.localPendingChatImageUris, images);
  }
});
test('local task dispatch checks the download before a task message, PC reminder or device action', async () => {
  for (const mode of ['phone', 'pc']) {
    const app = probe(); app.selectedAgentDeviceMode = () => mode;
    await app.submitLocalAgentTask(); assert.equal(calls.dialogs.length, 1);
    assert.equal(calls.effects.length, 0); assert.equal(app.userInput, '保留这条消息');
  }
});
test('going to model settings never downloads or resends the pending chat automatically', async () => {
  const app = probe(); dialog = async () => ({ index: 1 });
  await app.sendLocalChatMessage(); assert.deepEqual(calls.navigations, [{ section: 2, origin: 2 }]);
  assert.equal(calls.effects.length, 0); assert.equal(app.userInput, '保留这条消息');
});
test('a competing operation during readiness cannot create a second local send or task', async () => {
  for (const action of ['sendLocalChatMessage', 'submitLocalAgentTask']) {
    const app = probe(); app.ensureLocalChatModelIsAvailable = async () => { app.isThinking = true; return true; };
    await app[action](); assert.equal(calls.effects.length, 0); assert.equal(calls.loads, 0);
    assert.equal(app.userInput, '保留这条消息');
  }
});
test('the model loader independently rejects missing files even with a stale loaded flag', async () => {
  const app = probe(); app.modelLoaded = true;
  assert.equal(await app.ensureLocalModelLoaded(), false); assert.equal(app.modelLoaded, false);
  assert.equal(calls.loads, 0);
});
test('duplicate taps share one dialog, dismissal releases it, and another send can remind again', async () => {
  const app = probe(); let finish; dialog = () => new Promise(resolve => { finish = resolve; });
  const first = app.ensureLocalChatModelIsAvailable(); await Promise.resolve();
  assert.equal(await app.ensureLocalChatModelIsAvailable(), false); assert.equal(calls.dialogs.length, 1);
  finish({ index: 0 }); assert.equal(await first, false); assert.equal(app.localModelDownloadPromptVisible, false);
  dialog = async () => { throw Error('dialog dismissed'); };
  assert.equal(await app.ensureLocalChatModelIsAvailable(), false); assert.equal(calls.dialogs.length, 2);
  assert.equal(app.localModelDownloadPromptVisible, false);
});
test('both download flags block sending even when files and a loaded flag are present', async () => {
  for (const flag of ['downloading', 'modelScopeDownloading']) {
    const app = probe(); add(app.modelDir + '/config.json'); add(app.modelDir + '/llm.mnn'); add(app.modelDir + '/' + COMPLETE);
    app.modelLoaded = true; app[flag] = true;
    assert.equal(await app.ensureLocalChatModelIsAvailable(), false); assert.equal(calls.dialogs.length, 0);
    assert.ok(calls.toasts[0].includes('正在下载')); assert.equal(await app.ensureLocalModelLoaded(), false);
    assert.equal(calls.loads, 0);
  }
});
test('valid complete manifests work, but corrupt manifests and truncated/missing files cannot fall back to legacy readiness', async () => {
  const app = probe(); add(app.modelDir + '/config.json'); add(app.modelDir + '/llm.mnn', 64); add(app.modelDir + '/' + MANIFEST);
  assert.equal(app.modelLoadableStatus(app.modelDir), '下载记录损坏');
  app.modelManifest = { files: [{ path: 'config.json', size: 128 }, { path: 'llm.mnn', size: 64 }] };
  assert.equal(app.modelLoadableStatus(app.modelDir), '下载完成');
  assert.equal(await app.ensureLocalChatModelIsAvailable(), true); assert.equal(calls.dialogs.length, 0);
  files.set(app.modelDir + '/llm.mnn', { size: 32 });
  assert.equal(app.modelLoadableStatus(app.modelDir), '下载未完成');
  files.delete(app.modelDir + '/llm.mnn'); assert.equal(await app.ensureLocalModelLoaded(), false); assert.equal(calls.loads, 0);
});
test('legacy imported folders and completed downloads remain usable; empty config files do not', async () => {
  for (const directory of ['/app/model', '/app/modelscope/owner__repo']) {
    const app = probe(directory); add(directory + '/config.json'); add(directory + '/llm.mnn');
    if (directory.includes('modelscope')) add(directory + '/' + COMPLETE);
    assert.equal(await app.ensureLocalChatModelIsAvailable(), true);
    assert.equal(await app.ensureLocalModelLoaded(), true); assert.equal(calls.loads, 1);
    app.modelLoaded = true; assert.equal(await app.ensureLocalModelLoaded(), true); assert.equal(calls.loads, 1);
    files.set(directory + '/config.json', { size: 0 });
    assert.equal(await app.ensureLocalChatModelIsAvailable(), false); assert.equal(app.modelLoaded, false);
  }
});
(async () => { for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  console.log(cases.length + ' local model readiness checks passed; no downloads or inference');
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
