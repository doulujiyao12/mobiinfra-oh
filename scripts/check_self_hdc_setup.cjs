// Execute the production prerequisite guard with synthetic settings/dialogs.
// No device connection, HDC commands, network, HAP build or installation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = 'entry/src/main/ets/';
const cache = new Map();
let settings, refreshed, refreshCalls, dialogs, routes, toasts, dialogResult, failure;
const Settings = {
  load() { if (failure) { throw Error('fixture settings unavailable'); } return { ...settings }; },
  async refreshLocalIp() { refreshCalls++; return { ...(refreshed || settings) }; },
  saveMode(_dir, mode) { settings.mode = mode; }
};
const mocks = {
  '@kit.ArkUI': { router: { RouterMode: { Single: 1 }, async pushUrl(route, mode) { routes.push({ route, mode }); } } },
  'SelfHdcTaskSettings': { SelfHdcTaskSettings: Settings },
  'AppLogger': { AppLogger: { info() {}, warnCause() {} } },
  'PromptSafe': { showToastSafely(message) { toasts.push(message); } },
  'SelfHdcSetupDialog': { async showSelfHdcSetupDialog(_ui, problem) { dialogs.push(problem); return await dialogResult(); } }
};
function load(file) {
  const absolute = path.resolve(root, file.endsWith('.ets') ? file : file + '.ets');
  const name = path.basename(absolute, '.ets');
  if (mocks[name]) { return mocks[name]; }
  if (cache.has(absolute)) { return cache.get(absolute); }
  const output = ts.transpileModule(fs.readFileSync(absolute, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const exports = {}; cache.set(absolute, exports);
  vm.runInNewContext(output, { exports, require: id => mocks[id] || load(path.resolve(path.dirname(absolute), id)) });
  return exports;
}
const { SelfHdcSetupGuard: guard } = load(base + 'utils/selfhdc/SelfHdcSetupGuard');
const policy = load(base + 'utils/selfhdc/SelfHdcSetupPolicy');
function reset(change = {}) {
  settings = { mode: 'phone', ip: '192.168.1.8', port: '33117', autoIp: true, skipSetupReminder: false, ...change };
  refreshed = null; refreshCalls = 0; dialogs = []; routes = []; toasts = []; failure = false;
  dialogResult = async () => false;
}
const cases = [];
function test(name, run) { cases.push([name, run]); }

test('configured phone proceeds without a guide, even if Wi-Fi detection is unavailable', async () => {
  reset(); assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), true);
  assert.equal(refreshCalls, 1); assert.equal(dialogs.length, 0); assert.equal(routes.length, 0);
  assert.equal(policy.selfHdcSetupProblem(settings), '');
});
test('missing IP or port blocks the operation and explains the missing field', async () => {
  for (const change of [{ ip: '' }, { port: '' }, { ip: '', port: '' }]) {
    reset(change); let executed = false;
    if (await guard.ensure({}, '/sandbox', 'fixture')) { executed = true; }
    assert.equal(executed, false); assert.equal(dialogs.length, 1); assert.equal(routes.length, 0);
    if (!settings.ip) { assert.ok(dialogs[0].includes('尚未填写手机 IP')); }
    if (!settings.port) { assert.ok(dialogs[0].includes('尚未填写无线调试连接端口')); }
  }
});
test('invalid configured endpoint is blocked before any operation', async () => {
  for (const change of [{ ip: 'not-an-ip' }, { ip: '192.168.1.999' }, { port: '0' }, { port: '65536' }, { port: '33x' }]) {
    reset(change); assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), false); assert.equal(dialogs.length, 1);
  }
});
test('legacy do-not-remind choice cannot suppress required operation setup', async () => {
  reset({ port: '', skipSetupReminder: true });
  assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), false); assert.equal(dialogs.length, 1);
});
test('Go to Settings opens the HDC configuration once without replaying the operation', async () => {
  reset({ port: '' }); dialogResult = async () => true;
  assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), false);
  assert.equal(routes.length, 1); assert.equal(routes[0].route.url, 'pages/settings/SelfHdcTestPage');
  assert.equal(routes[0].mode, 1);
});
test('PC-mode task does not require phone endpoint or show a guide', async () => {
  reset({ mode: 'pc', ip: '', port: '' });
  assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), true);
  assert.equal(refreshCalls, 0); assert.equal(dialogs.length, 0);
  assert.equal(await guard.ensure({}, '/sandbox', 'explicit-phone-operation', false), false);
  assert.equal(dialogs.length, 1);
});
test('fresh IP and mode edits are respected after asynchronous detection', async () => {
  reset({ ip: '' }); refreshed = { ...settings, ip: '192.168.1.9' };
  assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), true); assert.equal(dialogs.length, 0);
  reset({ ip: '', port: '' }); refreshed = { ...settings, mode: 'pc' };
  assert.equal(await guard.ensure({}, '/sandbox', 'fixture'), true); assert.equal(dialogs.length, 0);
});
test('concurrent starts are not queued and the lock is released after dismissal or failure', async () => {
  reset({ port: '' }); let finish;
  dialogResult = () => new Promise(resolve => { finish = resolve; });
  const first = guard.ensure({}, '/sandbox', 'fixture');
  for (let i = 0; i < 5 && dialogs.length === 0; i++) { await Promise.resolve(); }
  assert.equal(dialogs.length, 1); assert.equal(await guard.ensure({}, '/sandbox', 'second'), false);
  finish(false); assert.equal(await first, false);
  reset(); failure = true; assert.equal(await guard.ensure({}, '/sandbox', 'failed'), false); assert.equal(toasts.length, 1);
  failure = false; assert.equal(await guard.ensure({}, '/sandbox', 'retry'), true);
});
test('startup/foreground and control-mode selection have no HDC setup prompt path', () => {
  const index = fs.readFileSync(path.join(root, base + 'pages/Index.ets'), 'utf8');
  assert.ok(!/showPhoneSetupForForeground|phoneStartupGuidePending|startupReminderOnly/.test(index));
  assert.ok(!index.includes("'app-open'"));
  const source = ts.createSourceFile('Index.ts', index.replace(/\bstruct Index\b/, 'class Index'), ts.ScriptTarget.Latest, true);
  const allowed = new Set(['runPhoneMobileGuiTaskForChatSession', 'runWechatAutoSummary', 'runPhoneChatAgent']);
  const guarded = [];
  function walk(node) {
    if (ts.isMethodDeclaration(node) && /SelfHdcSetupGuard\.ensure\(/.test(node.getText(source))) {
      const name = node.name.getText(source); assert.ok(allowed.has(name), 'Unexpected prompt in ' + name); guarded.push(name);
    }
    ts.forEachChild(node, walk);
  }
  walk(source); assert.equal(guarded.length, allowed.size);
  const panel = fs.readFileSync(path.join(root, base + 'components/TaskDeviceControlPanel.ets'), 'utf8');
  assert.ok(!panel.includes('SelfHdcSetupGuard')); assert.ok(panel.includes('SelfHdcTaskSettings.saveMode'));
  const dialog = fs.readFileSync(path.join(root, base + 'components/SelfHdcSetupDialog.ets'), 'utf8');
  assert.ok(!dialog.includes('启动时不再提醒'));
});
test('task, chat, WeChat, gallery and debug operation entry points retain prerequisite guards', () => {
  const check = (file, reasons) => {
    const source = fs.readFileSync(path.join(root, base + file), 'utf8');
    for (const reason of reasons) { assert.ok(source.includes(reason), file + ' missing ' + reason); }
    assert.ok(source.includes('await SelfHdcSetupGuard.ensure('), file);
  };
  check('pages/task/TaskPage.ets', ['workflow-start', 'workflow-batch-start']);
  check('pages/Index.ets', ['phone-chat-workflow', 'phone-chat-', 'phone-wechat-collection']);
  check('pages/gallery/GalleryPage.ets', ['gallery-batch', 'gallery-original']);
  check('pages/settings/SelfHdcTestPage.ets', ['phone-hdc-test']);
  check('pages/settings/SelfHdcInputTestPage.ets', ['SelfHdcSetupGuard']);
});

(async () => {
  let failures = 0;
  for (const [name, run] of cases) {
    try { await run(); console.log('PASS ' + name); }
    catch (error) { failures++; console.error('FAIL ' + name + '\n' + error.stack); }
  }
  console.log(`${cases.length - failures}/${cases.length} HDC setup checks passed; no device operations`);
  process.exitCode = failures ? 1 : 0;
})();
