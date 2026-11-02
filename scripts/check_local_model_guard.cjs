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
  'sendLocalChatMessage','submitLocalAgentTask','openSettingsFromTab','clearSettingsOrigin'];
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
  SettingsSectionId: { ModelAgents: 2 }, SettingsScrollTarget: { None: 0, LocalModelDownload: 1 },
  SETTINGS_SECTION_NONE: -1, MainTabIndex: { Chat: 2, Mine: 5 },
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
    settingsScrollTarget: 0,
    isThinking: false, localChatImagePreparing: false, localAgentCleaningUp: false, activeAgentRunner: null,
    activePhoneRunSession: null, restoringLocalSession: false,
    ensureAiServiceLogin: () => true, selectedAgentDeviceMode: () => 'phone',
    modelScopeRootDir: () => '/app/modelscope', readModelDownloadManifest: () => app.modelManifest,
    openSettingsFromTab: (section, origin, target) => {
      calls.navigations.push({ section, origin, target });
      exported.Probe.prototype.openSettingsFromTab.call(app, section, origin, target);
    },
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
  await app.sendLocalChatMessage(); assert.deepEqual(calls.navigations, [{ section: 2, origin: 2, target: 1 }]);
  assert.equal(app.settingsScrollTarget, 1); assert.equal(app.currentTab, 5);
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

const settingsSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/settings/SettingsCenterPage.ets'), 'utf8')
  .replace(/\bstruct SettingsCenterPage\b/, 'class SettingsCenterPage');
const settingsTree = ts.createSourceFile('SettingsCenterPage.ts', settingsSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const settingsClass = settingsTree.statements.find(item => ts.isClassDeclaration(item) && item.name?.text === 'SettingsCenterPage');
const frameClass = settingsTree.statements.find(item => ts.isClassDeclaration(item) && item.name?.text === 'SettingsScrollFrame');
const scrollMethods = ['resetDetailScroll', 'scheduleDetailScroll', 'onScrollTargetChanged', 'onSelectedSectionChanged', 'openSection', 'aboutToDisappear'];
const settingsOutput = ts.transpileModule(frameClass.getText(settingsTree) + '\nexport class SettingsProbe {\n' + scrollMethods.map(name => {
  const method = settingsClass.members.find(item => ts.isMethodDeclaration(item) && item.name.getText(settingsTree) === name);
  assert.ok(method, name); return method.getText(settingsTree).replace(/\bprivate\s+/g, '');
}).join('\n') + '\n}', { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal(settingsOutput.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const scrollExported = {};
vm.runInNewContext(settingsOutput.outputText, { exports: scrollExported, FrameCallback: class {},
  SettingsSectionId: { ModelAgents: 2 }, SettingsScrollTarget: { None: 0, LocalModelDownload: 1 },
  Edge: { Top: 'top', Bottom: 'bottom' }, isSettingsSectionSelected: id => id >= 0, normalizeSettingsSectionId: id => id });
function scrollProbe(section = 2, target = 0) {
  const page = new scrollExported.SettingsProbe(), frames = [], edges = [];
  Object.assign(page, { selectedSectionId: section, scrollTarget: target, detailScrollRevision: 0,
    closeSensitiveInputs() {}, detailScroller: { scrollEdge: edge => edges.push(edge) },
    getUIContext: () => ({ postFrameCallback: frame => frames.push(frame) }) });
  return { page, frames, edges, flush() { while (frames.length) { const frame = frames.shift(); frame.onFrame(0); frame.onIdle(0); } } };
}
test('model download navigation scrolls after layout exactly once and supports repeated prompts', () => {
  const view = scrollProbe(2, 1);
  view.page.scheduleDetailScroll(); view.page.onSelectedSectionChanged();
  assert.equal(view.edges.length, 0, 'Do not scroll before the new page has laid out');
  view.flush(); assert.deepEqual(view.edges, ['bottom']); assert.equal(view.page.scrollTarget, 0);
  view.page.onScrollTargetChanged(); assert.equal(view.frames.length, 0, 'Consuming the target must not scroll back up');
  view.page.scrollTarget = 1; view.page.onScrollTargetChanged(); view.flush();
  assert.deepEqual(view.edges, ['bottom', 'bottom']);
});
test('stale top callbacks, navigation away and component disposal cannot override the download destination', () => {
  const view = scrollProbe(); view.page.scheduleDetailScroll();
  view.page.scrollTarget = 1; view.page.onScrollTargetChanged(); view.flush();
  assert.deepEqual(view.edges, ['bottom']);
  view.edges.length = 0; view.page.scrollTarget = 1; view.page.onScrollTargetChanged();
  view.page.selectedSectionId = 7; view.page.onSelectedSectionChanged(); view.flush();
  assert.deepEqual(view.edges, ['top']); assert.equal(view.page.scrollTarget, 0);
  view.edges.length = 0; view.page.scheduleDetailScroll(); view.page.aboutToDisappear(); view.flush();
  assert.equal(view.edges.length, 0);
});
test('normal settings entries still start at the top and clear any old local-model destination', () => {
  const view = scrollProbe(2, 1); view.page.openSection(2); view.page.onSelectedSectionChanged(); view.flush();
  assert.deepEqual(view.edges, ['top']); assert.equal(view.page.scrollTarget, 0);
  const app = probe(); app.settingsScrollTarget = 1; app.openSettingsFromTab(7, 0);
  assert.equal(app.settingsScrollTarget, 0); app.settingsScrollTarget = 1; app.clearSettingsOrigin();
  assert.equal(app.settingsScrollTarget, 0);
  assert.ok(settingsSource.includes('.onAppear((): void => { this.scheduleDetailScroll(); })'), 'New detail content schedules its first layout scroll');
});
(async () => { for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  console.log(cases.length + ' local model readiness checks passed; no downloads or inference');
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
