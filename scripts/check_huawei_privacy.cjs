// Production privacy-state checks with a synthetic Huawei provider. No system
// prompts, user data, network, HAP build or device operations are involved.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = 'entry/src/main/ets/';
let results = [], unavailable = false, preferenceReads = [], links = [], destroyCount = 0;
const disk = new Map(), app = new Map(), loaded = new Map();
const provider = {
  AppPrivacyType: { PRIVACY_AGREEMENT: 1, USER_AGREEMENT: 2 },
  AppPrivacyResultType: { DISAGREED: 0, FULL_MODE_AGREED: 1, REQUIRE_RESIGNING_VERSION_UPDATE: 2 },
  AppPrivacyLinkType: { PRIVACY_STATEMENT_LINK: 1, USER_AGREEMENT_LINK: 2 },
  getAppPrivacyResult() { if (unavailable) throw Error('1006700003'); return results; },
  getAppPrivacyMgmtInfo: () => ({ type: 1, privacyInfo: links })
};
const mocks = {
  '@kit.AppGalleryKit': { privacyManager: provider },
  '@kit.NetworkKit': { http: { createHttp: () => ({ destroy() { destroyCount++; } }) } },
  '@kit.ArkData': { preferences: { async getPreferences(_context, options) {
    preferenceReads.push(options.name);
    if (options.name === 'privacy_consent') throw Error('Legacy agreement must never be read');
    return { get: async (key, fallback) => disk.get(options.name + '/' + key) ?? fallback,
      put: async (key, value) => disk.set(options.name + '/' + key, value), flush: async () => {} };
  } } },
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } },
  'PromptSafe': { showToastSafely() {} }
};
function load(relative) {
  const file = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
  if (mocks[path.basename(file, '.ets')]) return mocks[path.basename(file, '.ets')];
  if (loaded.has(file)) return loaded.get(file);
  const source = fs.readFileSync(file, 'utf8');
  const output = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } });
  assert.equal((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0, file);
  const exports = {}; loaded.set(file, exports);
  vm.runInNewContext(output.outputText, { exports, AppStorage: { get: key => app.get(key), setOrCreate: (key, value) => app.set(key, value) },
    require: id => { if (mocks[id]) return mocks[id]; if (!id.startsWith('.')) throw Error('Unexpected import ' + id);
      return load(path.resolve(path.dirname(file), id)); } });
  return exports;
}
const { PrivacyConsent: consent, platformPrivacyChoice: choice } = load(base + 'utils/PrivacyConsent');
const { HuaweiPrivacyAccess: access } = load(base + 'utils/HuaweiPrivacyAccess');
const { PersonalMemoryAccess: memory, PERSONAL_MEMORY_A2A_SCOPE: scope } = load(base + 'agent/PersonalMemoryAccess');
const { AppRequests: requests } = load(base + 'utils/AppRequests');
const result = (value, type = 1) => ({ type, result: value, versionCode: 1, id: 'fixture' });
const context = { openLink: async url => { linksOpened.push(url); } }, linksOpened = [];
const ui = { getHostContext: () => context };
const tests = [], test = (name, run) => tests.push([name, run]);
test('external sharing accepts the system result without a local agreement record', async () => {
  results = [result(1)]; await consent.initialize(context);
  assert.equal(consent.isAccepted(), true); assert.equal(typeof access.ensure, 'undefined');
  assert.deepEqual(preferenceReads, []); assert.equal(app.get('privacyConsentState'), 'accepted');
});
test('missing, declined, updated and unknown platform results cannot be treated as consent', async () => {
  for (const [value, expected] of [[[], 'unselected'], [[result(0)], 'rejected'], [[result(2)], 'unselected'],
    [[result(99)], 'unselected'], [[result(1, 2)], 'unselected'], [[result(1), result(0)], 'rejected']]) {
    results = value; await consent.initialize(context);
    assert.equal(choice(value), expected); assert.equal(consent.isAccepted(), false);
    assert.throws(() => consent.createHttp());
  }
});
test('an unavailable Huawei provider does not fall back to a fabricated or old acceptance', async () => {
  results = [result(1)]; await consent.initialize(context); assert.equal(consent.isAccepted(), true);
  unavailable = true; await consent.initialize(context);
  assert.equal(consent.state(), 'unavailable'); assert.equal(consent.isAccepted(), false);
  unavailable = false; assert.equal(consent.isAccepted(), true);
});
test('platform revocation closes registered HTTP and external requests once and stops active work', async () => {
  results = [result(1)]; await consent.initialize(context);
  const request = consent.createHttp(); let httpCancel = 0, externalCancel = 0, workCancel = 0;
  consent.onHttpCancel(request, () => { httpCancel++; });
  consent.registerExternalRequest(() => { externalCancel++; });
  consent.setRevokeHandler(() => { workCancel++; }); const before = destroyCount;
  results = [result(0)]; assert.equal(consent.isAccepted(), false); assert.equal(consent.isAccepted(), false);
  assert.equal(httpCancel, 1); assert.equal(externalCancel, 1); assert.equal(workCancel, 1); assert.equal(destroyCount, before + 1);
  consent.destroyHttp(request); assert.equal(destroyCount, before + 1); consent.setRevokeHandler(null);
});
test('Xiaoyi sharing still requires its own explicit opt-in, correct scope and platform acceptance', async () => {
  results = [result(1)]; await consent.initialize(context); assert.equal(await memory.isEnabled(context), false);
  await memory.setEnabled(context, true); assert.equal(await memory.isEnabled(context), true);
  assert.equal(disk.get('personal_memory_a2a/scope'), scope);
  results = [result(0)]; assert.equal(await memory.isEnabled(context), false);
  await assert.rejects(memory.setEnabled(context, true));
  await memory.setEnabled(context, false); results = [result(1)]; assert.equal(await memory.isEnabled(context), false);
  assert.ok(!preferenceReads.includes('privacy_consent'));
});
test('privacy settings open only the system-provided web policy and never a consent dialog', async () => {
  links = [{ type: 1, url: 'https://policy.invalid/statement', id: 'fixture', versionCode: 1 }];
  await access.openPolicy(ui); assert.deepEqual(linksOpened, ['https://policy.invalid/statement']);
  links = [{ type: 1, url: 'file:///private', id: 'fixture', versionCode: 1 }];
  await assert.rejects(consent.openStatement(context)); assert.equal(linksOpened.length, 1);
  await access.openPolicy({ getHostContext: () => undefined }); assert.equal(linksOpened.length, 1);
});
test('all in-app entry points omit the duplicate check and preserve independent permission prompts', () => {
  assert.equal(fs.existsSync(path.join(root, base, 'components/PrivacyConsentDialog.ets')), false);
  for (const file of ['pages/Index.ets', 'pages/gallery/GalleryPage.ets', 'pages/task/TaskPage.ets',
    'pages/codex/CodexPage.ets','pages/codex/CodexClient.ets','pages/codex/CodexChatService.ets',
    'utils/AgentExecutionController.ets','utils/AgentRouterServer.ets','utils/WorkflowRunner.ets',
    'utils/wechat/PhoneWechatAutoSummaryClient.ets']) {
    const source = fs.readFileSync(path.join(root, base, file), 'utf8');
    assert.ok(!source.includes('PrivacyConsent'), file);
    assert.ok(!source.includes('HuaweiPrivacyAccess.ensure'), file);
    assert.ok(!source.includes('privacyState'), file);
  }
  const helper = fs.readFileSync(path.join(root, base, 'utils/HuaweiPrivacyAccess.ets'), 'utf8');
  assert.ok(!/showAlertDialog|openCustomDialog|requestAppPrivacyConsent|static async ensure/.test(helper));
  assert.ok(!fs.readFileSync(path.join(root, base, 'utils/PrivacyConsent.ets'), 'utf8').includes('请先在华为系统隐私协议中完成确认'));
  for (const file of ['datamanager/avatar/SeedreamAvatarProvider.ets','utils/voice/MimoVoiceClient.ets',
    'utils/HdcWorkflowBridge.ets','utils/gallery/GalleryReverseGeocoder.ets','utils/wechat/WechatAutoSummaryClient.ets']) {
    const source=fs.readFileSync(path.join(root,base,file),'utf8');assert.ok(source.includes('AppRequests'),file);
    assert.ok(!source.includes('PrivacyConsent'),file);
  }
  const scoped = new Set(['agent/PersonalMemoryAccess.ets','agent/PersonalMemoryAgentAbility.ets',
    'utils/PrivacyConsent.ets','utils/HuaweiPrivacyAccess.ets','pages/settings/SettingsCenterPage.ets']);
  function inspect(directory) {
    for (const entry of fs.readdirSync(directory,{withFileTypes:true})) {
      const file=path.join(directory,entry.name);
      if(entry.isDirectory()){inspect(file);continue;}
      if(!file.endsWith('.ets'))continue;
      const relative=path.relative(path.join(root,base),file).replaceAll('\\','/');
      const source=fs.readFileSync(file,'utf8');
      assert.ok(!/请先在华为系统隐私协议中完成确认|ensurePrivacyConsent|HuaweiPrivacyAccess\.ensure/.test(source),relative);
      if(!scoped.has(relative))assert.ok(!/\bPrivacyConsent\b|\bPRIVACY_STATE_KEY\b/.test(source),relative);
    }
  }
  inspect(path.join(root,base));
  assert.ok(fs.readFileSync(path.join(root, base, 'utils/calendar/CalendarMemoryService.ets'), 'utf8').includes('requestPermissionsFromUser'));
  assert.ok(fs.readFileSync(path.join(root, base, 'components/MailSettingsPanel.ets'), 'utf8').includes('允许AI筛选邮件？'));
});

test('ordinary app requests do not depend on a second platform result or fabricate external sharing consent', async () => {
  unavailable = true; await consent.initialize(context);
  disk.set('personal_memory_a2a/enabled', true); disk.set('personal_memory_a2a/scope', scope);
  const request = requests.createHttp(); assert.ok(request);
  assert.equal(consent.state(), 'unavailable');
  assert.equal(await memory.isEnabled(context), false, 'external sharing still fails closed');
  requests.destroyHttp(request); unavailable = false; disk.set('personal_memory_a2a/enabled', false);
});

test('app request lifecycle retains cancellation, unregister and single-destruction semantics', () => {
  let cancelled = 0, external = 0, removed = 0; const before = destroyCount;
  const request = requests.createHttp(); requests.onHttpCancel(request, () => { cancelled++; });
  requests.registerExternalRequest(() => { external++; });
  const unregister = requests.registerExternalRequest(() => { removed++; }); unregister();
  requests.cancelAll(); requests.cancelAll(); requests.destroyHttp(request);
  assert.equal(cancelled, 1); assert.equal(external, 1); assert.equal(removed, 0);
  assert.equal(destroyCount, before + 1);
});
(async () => { for (const [name, run] of tests) { await run(); console.log('PASS ' + name); }
  console.log(tests.length + '/' + tests.length + ' Huawei privacy checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
