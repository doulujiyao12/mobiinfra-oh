// Source-level simulation only: no HAP build, network, phone input, or device installation.
// node scripts/check_phone_wechat.cjs <typescript-module-path>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const base = 'entry/src/main/ets/utils/';
const fixtures = path.join(root, 'entry/src/main/python/wechat_collect/fixtures');
const cache = new Map(), disk = new Map();
const appValues = new Map(), preferenceDisk = new Map(), preferenceHandles = new Map();
const clone = v => JSON.parse(JSON.stringify(v));
let accepted = true, debug = false, stop = false, shellHandler, shellCalls = [], restored = 0;
let preferenceFailure = false;
class DataStorage {
  join(...parts) { return parts.join('/'); }
  writeTextAtomic(file, text) { disk.set(file, text); }
}
const privacy = { requireAccepted() { if (!accepted) throw new Error('PRIVACY_REQUIRED'); }, isAccepted: () => accepted };
const kit = { JSON, util: { Base64Helper: class {
  decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
} } };
const external = {
  '@kit.ArkTS': kit, '@kit.AbilityKit': {}, '@kit.ImageKit': {},
  '@kit.BackgroundTasksKit': { backgroundTaskManager: {} },
  '@kit.BasicServicesKit': { deviceInfo: {} },
  '@kit.ArkData': { preferences: { getPreferencesSync(context, options) {
    const key = context.filesDir + '/' + options.name;
    if (!preferenceHandles.has(key)) {
      const pending = new Map(preferenceDisk.get(key) || []);
      preferenceHandles.set(key, {
        getSync(name, fallback) { return pending.has(name) ? pending.get(name) : fallback; },
        putSync(name, value) { pending.set(name, value); },
        flushSync() {
          if (preferenceFailure) throw new Error('disk unavailable');
          preferenceDisk.set(key, new Map(pending));
        }
      });
    }
    return preferenceHandles.get(key);
  } } }
};
const mocks = {
  'PrivacyConsent.ets': { PrivacyConsent: privacy },
  'DebugSettings.ets': { DebugSettings: { isEnabled: () => debug } },
  'DataManagerStorage.ets': { DataManagerStorage: DataStorage },
  'JsonCompat.ets': { stringifyJsonCompat: JSON.stringify },
  'HdcWorkflowBridge.ets': { HdcWorkflowBridge: class {} },
  'HdcClient.ets': { HdcClient: class {
    async shell(command) { shellCalls.push(command); return await shellHandler(command); }
    close() {}
  } },
  'SelfHdcTestRunner.ets': { SelfHdcTestRunner: { shared: () => ({ snapshot: () => ({ runId: 'mock-run' }) }) } },
  'SelfHdcTaskSettings.ets': { SelfHdcTaskSettings: class {} },
  'SelfHdcFiles.ets': {},
  'AppIdentity.ets': { getAppBundleName: () => 'com.coevomind.clawmate' },
  'TextEncodingCompat.ets': { decodeUtf8Compat: bytes => Buffer.from(bytes).toString('utf8') },
  'AgentExecutionController.ets': { AgentExecutionController: {
    isCancelRequested: () => stop, waitIfPaused: async () => {},
    hideCaptureOverlay: async () => true, restoreCaptureOverlay: async () => { restored++; }
  } }
};
function load(file) {
  const absolute = path.resolve(root, file.endsWith('.ets') ? file : file + '.ets');
  const name = path.basename(absolute);
  if (mocks[name]) return mocks[name];
  if (cache.has(absolute)) return cache.get(absolute);
  const source = fs.readFileSync(absolute, 'utf8');
  const result = ts.transpileModule(source, { fileName: absolute.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } });
  const errors = (result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, name + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const module = { exports: {} }; cache.set(absolute, module.exports);
  vm.runInNewContext(result.outputText, { module, exports: module.exports, require: id =>
    external[id] || load(path.resolve(path.dirname(absolute), id)), setTimeout, clearTimeout, console, Date, Map, Set,
    Uint8Array, AppStorage: { get: key => appValues.get(key) } }, { filename: absolute });
  return module.exports;
}
const parser = load(base + 'wechat/WechatUiParser');
const { PhoneWechatAutoSummaryClient, WechatPhoneHdcDevice } = load(base + 'wechat/PhoneWechatAutoSummaryClient');
const { WechatAutoSummarySettings, WechatCollectionForm } = load(base + 'wechat/WechatAutoSummarySettings');
const storeModule = load(base + 'wechat/WechatAutoSummaryStorage');
const { PhoneHdcActions } = load(base + 'selfhdc/PhoneHdcActions');
const fixture = name => JSON.parse(fs.readFileSync(path.join(fixtures, name), 'utf8'));
const home = fixture('home.json'), chat = fixture('chat_xiao_zhao.json');
const request = { mode: 'recent_contacts', days: 7, max_contacts: 1, target_contact: '', max_list_swipes: 3,
  swipe_speed: 2000, history_swipe_ratio: 0.4, stable_swipes: 2, max_history_swipes: 3, wait: 0 };
const node = (type, text = '', bounds = '[0,0][1256,2760]', children = []) =>
  ({ attributes: { type, text, origBounds: bounds }, children });
const withTitle = (source, title) => {
  let copy = clone(source);
  const text = copy.children.find(x => x.attributes.type === 'Text');
  text.attributes.text = title;
  return copy;
};
function setup(frames, options = {}) {
  disk.clear(); accepted = true; debug = false; stop = false;
  const calls = [], checkpoints = [], logs = [];
  let index = 0;
  const device = {
    async openWechat() { calls.push({ action: 'open' }); },
    async dump() {
      calls.push({ action: 'dump' });
      if (options.onDump) options.onDump(index);
      const frame = frames[Math.min(index++, frames.length - 1)];
      if (frame instanceof Error) throw frame;
      return JSON.stringify(frame);
    },
    async action(payload) {
      calls.push(clone(payload));
      if (options.onAction) options.onAction(payload, calls);
    }
  };
  const client = new PhoneWechatAutoSummaryClient(device, new storeModule.WechatAutoSummaryStorage('/sandbox'),
    text => logs.push(text), () => {}, () => { if (stop) throw new Error('PHONE_HDC_CANCELLED'); },
    response => { checkpoints.push(clone(response)); if (options.onCheckpoint) options.onCheckpoint(response); });
  return { client, calls, checkpoints, logs };
}
const cases = [];
function test(name, fn) { cases.push([name, fn]); }
test('collection form: migrate legacy input, synchronously save and restore after process restart', () => {
  appValues.clear(); preferenceDisk.clear(); preferenceHandles.clear(); preferenceFailure = false;
  appValues.set('wechatAutoSummaryCollectionMode', 'target_contact');
  appValues.set('wechatAutoSummaryCollectionDaysInput', '3');
  appValues.set('wechatAutoSummaryCollectionMaxContactsInput', '8');
  appValues.set('wechatAutoSummaryCollectionTargetContactInput', '小赵');
  const context = { filesDir: '/sandbox/form' };
  let form = WechatAutoSummarySettings.load(context);
  assert.equal(form.mode, 'target_contact'); assert.equal(form.daysInput, '3');
  assert.equal(form.targetContactInput, '小赵');
  form.daysInput = '14'; form.targetContactInput = '项目群';
  WechatAutoSummarySettings.save(context, form);
  // Remove in-memory AppStorage and cached preference handles, retaining only flushed disk data.
  appValues.clear(); preferenceHandles.clear();
  form = WechatAutoSummarySettings.load(context);
  assert.equal(form.daysInput, '14'); assert.equal(form.targetContactInput, '项目群');
  assert.equal(form.maxContactsInput, '8'); assert.equal(form.mode, 'target_contact');
  form.mode = 'recent_contacts'; WechatAutoSummarySettings.save(context, form);
  preferenceHandles.clear();
  assert.equal(WechatAutoSummarySettings.load(context).targetContactInput, '项目群');
});
test('collection form: explicit clears persist, and save/read failures are not silently ignored', () => {
  const context = { filesDir: '/sandbox/form-clear' };
  const form = new WechatCollectionForm();
  WechatAutoSummarySettings.save(context, form);
  appValues.set('wechatAutoSummaryCollectionDaysInput', '30');
  appValues.set('wechatAutoSummaryCollectionTargetContactInput', 'legacy-contact');
  preferenceHandles.clear();
  const restored = WechatAutoSummarySettings.load(context);
  assert.equal(restored.daysInput, ''); assert.equal(restored.targetContactInput, '');
  preferenceFailure = true;
  assert.throws(() => WechatAutoSummarySettings.save(context, form), /disk unavailable/);
  preferenceFailure = false;
  preferenceHandles.clear();
  const key = context.filesDir + '/wechat_collection_settings';
  preferenceDisk.set(key, new Map([['form', '{invalid json']]));
  assert.throws(() => WechatAutoSummarySettings.load(context));
  appValues.clear();
});
test('restart WeChat: force-stop precedes launch for both bundles, and uncertain commands are not replayed', async () => {
  const { PhoneHdcWorkflowBridge } = load(base + 'selfhdc/PhoneHdcWorkflowBridge');
  stop = false; shellCalls = [];
  const metadata = '{"moduleInfos":[{"mainAbility":"MainAbility"}]}';
  shellHandler = async command => ({ exitCode: 0, output: command.startsWith('bm dump') ? metadata : '' });
  const bridge = new PhoneHdcWorkflowBridge({ filesDir: '/sandbox' }, {}, () => {});
  bridge.pause = async () => {};
  await new WechatPhoneHdcDevice(bridge).openWechat();
  const stopped = shellCalls.findIndex(x => x === "aa force-stop 'com.tencent.wechat'");
  const started = shellCalls.findIndex(x => x.startsWith("aa start -b 'com.tencent.wechat'"));
  assert.ok(stopped >= 0 && started > stopped);
  shellCalls = [];
  shellHandler = async command => ({ exitCode: 0,
    output: command.startsWith("bm dump -n 'com.tencent.mm'") ? metadata : '' });
  await new WechatPhoneHdcDevice(bridge).openWechat();
  assert.ok(shellCalls.indexOf("aa force-stop 'com.tencent.mm'") <
    shellCalls.findIndex(x => x.startsWith("aa start -b 'com.tencent.mm'")));
  shellCalls = [];
  shellHandler = async command => ({
    exitCode: command.startsWith('aa force-stop') ? 1 : 0,
    output: command.startsWith('bm dump') ? metadata : ''
  });
  await assert.rejects(new WechatPhoneHdcDevice(bridge).openWechat(), /PHONE_HDC_COMMAND/);
  assert.equal(shellCalls.filter(x => x.startsWith('aa force-stop')).length, 1);
  assert.ok(!shellCalls.some(x => x.startsWith('aa start')));
});
test('PC fixtures: contacts, title, sender direction and relative time', () => {
  assert.deepEqual(clone(parser.wechatContacts(home).map(x => x.name)), ['小赵', '项目群', '文件传输助手']);
  const page = parser.wechatChatPage(chat, '小赵');
  assert.deepEqual(clone(page.entries.map(x => [x.kind, x.sender, x.text])), [
    ['time', null, '星期一 下午 03:47'], ['message', 'self', '我想要买一个iPhone 17Pro'],
    ['message', '小赵', '需要给妹妹买一些少儿读物']]);
  const now = new Date(2026, 5, 11, 12);
  assert.equal(parser.parseWechatTime('昨天下午 07:39', now), new Date(2026, 5, 10, 19, 39).getTime());
  for (const text of ['6月31号', '13/01 下午 01:00', '上午 25:00', '普通聊天文本'])
    assert.equal(parser.parseWechatTime(text, now), null);
  assert.equal(parser.wechatCutoff(3, now), new Date(2026, 5, 9).getTime());
  assert.throws(() => parser.wechatChatPage(chat, '另一个联系人'), /CHAT_MISMATCH/);
});
test('history fixture overlap, cutoff and stable snapshots', () => {
  const roots = [fixture('history_010.json'), fixture('history_009.json')];
  const pages = roots.map(r => parser.wechatChatPage(r, parser.wechatTitle(r)));
  const now = new Date(2026, 5, 18, 12);
  const result = parser.mergeWechatPages(pages, 90, now);
  assert.ok(result.length > 0);
  const repeated = parser.mergeWechatPages([pages[0], pages[0]], 90, now);
  assert.deepEqual(clone(repeated), clone(parser.mergeWechatPages([pages[0]], 90, now)));
  const old = clone(pages[0]);
  old.entries = [
    { kind: 'time', text: '2026年6月1日 10:00', sender: null, bounds: null, textBounds: null, images: [] },
    { kind: 'message', text: 'old', sender: 'self', bounds: null, textBounds: null, images: [] },
    { kind: 'time', text: '2026年6月18日 10:00', sender: null, bounds: null, textBounds: null, images: [] },
    ...['same', 'same'].map(text => ({ kind: 'message', text, sender: 'self', bounds: null, textBounds: null, images: [] }))
  ];
  const filtered = parser.mergeWechatPages([old], 1, now);
  assert.equal(filtered.filter(x => x.text === 'old').length, 0);
  assert.equal(filtered.filter(x => x.text === 'same').length, 2);
  const golden = parser.mergeWechatPages(['history_009.json', 'history_010.json']
    .map(name => parser.wechatChatPage(fixture(name), '小赵')), 90, new Date(2026, 5, 11, 12));
  assert.deepEqual(clone(golden.map(x => x.text)), ['星期一 下午 02:00', '更早的一条消息',
    '边界重复消息', '星期一 下午 03:47', '我想要买一个iPhone 17Pro', '需要给妹妹买一些少儿读物']);
  const item = text => ({ kind: 'message', text, sender: 'self', bounds: null, textBounds: null, images: [] });
  const older = clone(pages[0]), newer = clone(pages[0]);
  older.entries = [item('same'), item('middle')]; newer.entries = [item('middle'), item('same')];
  assert.deepEqual(clone(parser.mergeWechatPages([newer, older], 90, now).map(x => x.text)),
    ['same', 'middle', 'same']);
});
test('recent mode: direct device sequence, stable stop, business format and no debug dumps', async () => {
  const env = setup([home, chat]);
  const response = await env.client.collect(request);
  assert.equal(response.status, 'ok');
  assert.equal(response.contacts_collected, 1);
  assert.equal(response.conversations[0].coverage_complete, false);
  assert.match(response.conversations[0].collection_stop_reason, /不再变化/);
  const swipes = env.calls.filter(x => x.action === 'swipe_with_coords');
  assert.equal(swipes.filter(x => x.start_y < x.end_y).length, 2);
  assert.equal(swipes.filter(x => x.start_y > x.end_y).length, 2);
  assert.ok(swipes.every(x => x.swipe_speed === 2000));
  assert.ok(env.logs.every(x => !x.includes('小赵') && !x.includes('iPhone')));
  assert.equal(disk.size, 0);
  const entries = storeModule.wechatAutoSummaryDailyEntries(response);
  const daily = storeModule.renderWechatAutoSummaryDailyLog(response.run_id, response.mode, response.days, entries);
  assert.ok(daily.includes('DAILY_LOG_METADATA') && daily.includes('1. ## 微信联系人'));
  assert.ok(daily.includes('不能保证覆盖整个时间范围'));
});
test('refresh list coordinates between contacts rather than reuse stale bounds', async () => {
  const changed = clone(home);
  const items = changed.children[0].children;
  [items[0], items[1]] = [items[1], items[0]];
  items[0].attributes.origBounds = '[0,500][1256,678]';
  items[1].attributes.origBounds = '[0,690][1256,850]';
  const group = withTitle(chat, '项目群');
  const env = setup([home, chat, chat, chat, chat, changed, group, group, group, group]);
  await env.client.collect({ ...request, max_contacts: 2, stable_swipes: 1 });
  const clicks = env.calls.filter(x => x.action === 'click');
  assert.equal(clicks.length, 2);
  assert.deepEqual(clicks.map(x => x.y), [589, 589]);
  assert.ok(env.calls.some(x => x.action === 'keyevent' && x.key === 'BACK'));
});
test('target search: explicit search field, escaped input path, no Enter, exact match', async () => {
  const target = "O'Neil; $(danger)";
  const searchHome = clone(home);
  searchHome.children.push(node('Text', '搜索', '[180,130][1060,220]'));
  const field = node('WindowScene', '', '[0,0][1256,2760]', [
    node('TextInput', '', '[180,130][1060,220]'), node('Text', '取消', '[1100,130][1250,220]')]);
  const results = node('WindowScene', '', '[0,0][1256,2760]', [
    node('List', '', '[0,260][1256,2600]', [node('ListItem', '', '[0,300][1256,520]', [
      node('Text', '最常使用', '[70,305][280,345]'), node('Text', target, '[210,350][900,410]')])])]);
  const resultChat = withTitle(chat, target);
  const env = setup([searchHome, field, results, resultChat]);
  const response = await env.client.collect({ ...request, mode: 'target_contact', target_contact: target });
  assert.equal(response.conversations[0].title, target);
  const input = env.calls.find(x => x.action === 'click_input');
  assert.equal(input.text, target); assert.equal(input.submit_enter, false);
  assert.ok(!env.calls.some(x => x.action === 'keyevent' && x.key === 'ENTER'));
  const actions = new PhoneHdcActions(); actions.setScreen(1256, 2760);
  const plan = actions.plan(input);
  const text = plan.commands.find(x => x.label.startsWith('input-text'));
  assert.ok(text.sensitive && text.command.includes("'\\''"));
  assert.ok(!plan.commands.some(x => x.label === 'submit-enter'));
});
test('ambiguous or missing search match and wrong chat never trigger history swipes', async () => {
  const env = setup([home, withTitle(chat, '错误联系人')]);
  await assert.rejects(env.client.collect(request), /CHAT_MISMATCH/);
  assert.ok(!env.calls.some(x => x.action === 'swipe_with_coords'));
  const missing = setup([home]);
  await assert.rejects(missing.client.collect({ ...request, mode: 'target_contact', target_contact: 'not-visible' }), /SEARCH_ENTRY/);
  assert.ok(!missing.calls.some(x => x.action === 'click_input'));
  const searchHome = clone(home);
  searchHome.children.push(node('Text', '搜索', '[180,130][1060,220]'));
  const field = node('WindowScene', '', '[0,0][1256,2760]', [node('TextInput', '', '[180,130][1060,220]')]);
  const ambiguous = node('WindowScene', '', '[0,0][1256,2760]', [
    node('List', '', '[0,260][1256,2600]', [300, 600].map(y =>
      node('ListItem', '', '[0,' + y + '][1256,' + (y + 200) + ']', [
        node('Text', '同名', '[200,' + y + '][800,' + (y + 100) + ']')])))]);
  const duplicate = setup([searchHome, field, ambiguous]);
  await assert.rejects(duplicate.client.collect({ ...request, mode: 'target_contact', target_contact: '同名' }), /SEARCH_MATCH/);
  assert.equal(duplicate.calls.filter(x => x.action === 'click').length, 1);
  assert.ok(!duplicate.calls.some(x => x.action === 'swipe_with_coords'));
});
test('restored history is moved to latest messages before collecting older pages', async () => {
  const older = fixture('history_010.json');
  const env = setup([home, older, chat, chat, chat, chat, chat]);
  const response = await env.client.collect(request);
  const firstDown = env.calls.findIndex(x => x.action === 'swipe_with_coords' && x.start_y < x.end_y);
  assert.ok(firstDown > 0);
  assert.equal(env.calls.slice(0, firstDown).filter(x => x.action === 'swipe_with_coords' && x.start_y > x.end_y).length, 3);
  assert.ok(!response.conversations[0].messages.some(x => x.text === '更早的一条消息'));
});
test('user stop after reading a page saves partial data and sends no more device actions', async () => {
  const env = setup([home, chat], { onAction(payload) {
    if (payload.action === 'swipe_with_coords' && payload.start_y < payload.end_y) stop = true;
  } });
  await assert.rejects(env.client.collect(request), /CANCELLED/);
  assert.equal(env.checkpoints.at(-1).status, 'partial');
  assert.equal(env.checkpoints.at(-1).contacts_collected, 1);
  assert.equal(env.calls.at(-1).action, 'swipe_with_coords');
});
test('background/network failure preserves partial pages without retrying UI actions', async () => {
  const env = setup([home, chat, chat, chat, new Error('PHONE_HDC_BACKGROUND_EXPIRED')]);
  await assert.rejects(env.client.collect(request), /BACKGROUND_EXPIRED/);
  assert.equal(env.checkpoints.at(-1).contacts_collected, 1);
  assert.equal(env.calls.filter(x => x.action === 'swipe_with_coords' && x.start_y < x.end_y).length, 1);
});
test('privacy revocation aborts without writing new checkpoints', async () => {
  const env = setup([home, chat], { onAction(payload) {
    if (payload.action === 'swipe_with_coords' && payload.start_y < payload.end_y) accepted = false;
  } });
  await assert.rejects(env.client.collect(request), /PRIVACY_REQUIRED/);
  assert.equal(env.checkpoints.length, 0);
});
test('debug switch controls UI dump persistence; malformed arguments do not open WeChat', async () => {
  let env = setup([home, chat]); debug = true;
  await env.client.collect(request);
  assert.ok(disk.size > 0 && [...disk.keys()].every(x => /\/ui_\d+\.json$/.test(x)));
  env = setup([home, chat]);
  await assert.rejects(env.client.collect({ ...request, max_contacts: 1.5 }), /必须为整数/);
  assert.equal(env.calls.length, 0);
  await assert.rejects(env.client.collect({ ...request, target_contact: '\0' }), /名称无效/);
});
test('collection dispatch follows the persisted task mode and never falls back from phone to PC', async () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private async runWechatAutoSummary(');
  const end = source.indexOf('  private saveWechatAutoSummaryResponse(', start);
  assert.ok(start > 0 && end > start);
  const wrapped = 'class Dispatcher {\n' + source.slice(start, end) + '\n} module.exports=Dispatcher;';
  const js = ts.transpileModule(wrapped, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText;
  let pc = 0, phone = 0, setupCalls = 0, ready = true, mode = 'phone';
  const response = { status: 'ok', conversations: [{ title: 'mock', messages: [] }] };
  const module = { exports: {} };
  vm.runInNewContext(js, { module, exports: module.exports,
    WechatAutoSummaryClient: class { async collect() { pc++; return response; } },
    PhoneWechatAutoSummaryClient: class { async collect() { phone++; return response; } },
    WechatPhoneHdcDevice: class {}, WechatAutoSummaryStorage: class {},
    PhoneHdcRunSession: class { async run(_title, run) { return await run({}); } record() {} setResult() {} },
    SelfHdcSetupGuard: { ensure: async () => { setupCalls++; return ready; } },
    SelfHdcTestRunner: { shared: () => ({ snapshot: () => ({ running: false }) }) },
    AgentExecutionController: { isExecutionActive: () => false, isCancelRequested: () => false },
    getContext: () => ({}), showToastSafely() {}, dataManagerError() {}
  });
  const app = new module.exports();
  Object.assign(app, { ensureAiServiceLogin: () => true, ensurePrivacyConsent: async () => true,
    filesDir: '/sandbox', hdcServerIp: '', activePhoneRunSession: null, activeAgentRunner: null,
    selectedAgentDeviceMode: () => mode, ensureHdcServerReadyForTask: async () => true,
    getUIContext: () => ({}), saveWechatAutoSummaryResponse() {} });
  await app.runWechatAutoSummary(request);
  assert.equal(phone, 1); assert.equal(pc, 0); assert.equal(setupCalls, 1);
  assert.equal(app.activePhoneRunSession, null); assert.equal(app.wechatAutoSummaryRunning, false);
  ready = false;
  await app.runWechatAutoSummary(request);
  assert.equal(phone, 1); assert.equal(pc, 0);
  mode = 'pc'; app.hdcServerIp = 'http://mock:9124';
  await app.runWechatAutoSummary(request);
  assert.equal(pc, 1); assert.equal(phone, 1); assert.equal(setupCalls, 2);
});
test('phone action speed is opt-in and validated, existing GUI swipe stays unchanged', () => {
  const actions = new PhoneHdcActions(); actions.setScreen(1256, 2760);
  assert.equal(actions.plan({ action: 'swipe_with_coords', start_x: 500, start_y: 800, end_x: 500, end_y: 1500 })
    .commands[0].command, 'uitest uiInput swipe 500 800 500 1500');
  assert.throws(() => actions.plan({ action: 'swipe_with_coords', start_x: 500, start_y: 800,
    end_x: 500, end_y: 1500, swipe_speed: -1 }), /swipe_speed/);
});
test('strict declaration check for parser, collector, data contract and action planning', () => {
  // Check declarations in memory; this is not an ArkTS/Hvigor build. Platform stubs
  // restrict this check to the production collection modules and their own types.
  const sources = new Map();
  const actual = ['wechat/WechatUiParser', 'wechat/PhoneWechatAutoSummaryClient',
    'wechat/WechatAutoSummaryTypes', 'wechat/WechatAutoSummaryStorage', 'wechat/WechatAutoSummarySettings',
    'selfhdc/PhoneHdcActions', 'selfhdc/SelfHdcPolicy'];
  for (const file of actual) sources.set(path.resolve(root, base + file + '.ts'),
    fs.readFileSync(path.resolve(root, base + file + '.ets'), 'utf8'));
  const stubs = {
    'selfhdc/PhoneHdcWorkflowBridge': "export declare class PhoneHdcWorkflowBridge { startApp(name:string,bundle:string,reset:boolean):Promise<void>; dumpUiLayout():Promise<string>; guiAction(payload:import('../WorkflowTypes').WorkflowJsonMap):Promise<Object>; }",
    'PrivacyConsent': 'export declare class PrivacyConsent { static requireAccepted():void; static isAccepted():boolean; }',
    'DebugSettings': 'export declare class DebugSettings { static isEnabled():boolean; }',
    'WorkflowTypes': 'export type WorkflowJsonMap=Record<string,Object|string|number|boolean|null>;',
    'JsonCompat': 'export declare function stringifyJsonCompat(value:Object,space?:number):string;'
  };
  for (const [file, text] of Object.entries(stubs)) sources.set(path.resolve(root, base + file + '.ts'), text);
  sources.set(path.resolve(root, 'entry/src/main/ets/datamanager/DataManagerStorage.ts'),
    'export declare class DataManagerStorage { join(...parts:string[]):string; writeTextAtomic(path:string,text:string):void; }');
  const kits = path.resolve(root, '.codex-tmp/wechat-kits.d.ts');
  sources.set(kits, [
    "declare module '@kit.ArkTS' { export namespace JSON { function parse(text:string):Object; function stringify(value:Object):string; } }",
    "declare module '@kit.AbilityKit' { export namespace common { interface Context {} } }",
    "declare module '@kit.ArkData' { export namespace preferences { interface Options { name:string; } interface Preferences { getSync(key:string,fallback:string):string|number|boolean; putSync(key:string,value:string):void; flushSync():void; } function getPreferencesSync(context:import('@kit.AbilityKit').common.Context,options:Options):Preferences; } }",
    "declare namespace AppStorage { function get<T>(key:string):T|undefined; }"
  ].join('\n'));
  const options = { noEmit: true, strict: true, skipLibCheck: true, target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.CommonJS, moduleResolution: ts.ModuleResolutionKind.NodeJs };
  const host = ts.createCompilerHost(options);
  const read = host.readFile.bind(host), exists = host.fileExists.bind(host);
  host.readFile = file => sources.get(path.resolve(file)) ?? read(file);
  host.fileExists = file => sources.has(path.resolve(file)) || exists(file);
  host.getSourceFile = (file, language) => {
    const source = host.readFile(file);
    return source === undefined ? undefined : ts.createSourceFile(file, source, language, true);
  };
  host.resolveModuleNames = (names, containing) => names.map(name => {
    const candidate = path.resolve(path.dirname(containing), name + '.ts');
    return sources.has(candidate) ? { resolvedFileName: candidate, extension: ts.Extension.Ts } :
      ts.resolveModuleName(name, containing, options, host).resolvedModule;
  });
  const program = ts.createProgram([...sources.keys()], options, host);
  const errors = ts.getPreEmitDiagnostics(program).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(d =>
    (d.file ? path.basename(d.file.fileName) + ':' + d.file.getLineAndCharacterOfPosition(d.start).line + ': ' : '') +
    ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
});
test('UI dump transfer: chunked UTF-8, coordinate initialization, private output and cleanup', async () => {
  const { PhoneHdcWorkflowBridge } = load(base + 'selfhdc/PhoneHdcWorkflowBridge');
  const large = clone(home); large.attributes.description = '中文'.repeat(22000);
  const bytes = Buffer.from(JSON.stringify(large));
  shellCalls = []; restored = 0; accepted = true; stop = false;
  shellHandler = async command => {
    if (command.startsWith('wc -c')) return { exitCode: 0, output: String(bytes.length) };
    if (command.startsWith('dd ')) {
      const skip = Number(/skip=(\d+)/.exec(command)[1]);
      return { exitCode: 0, output: bytes.subarray(skip * 49152, (skip + 1) * 49152).toString('base64') };
    }
    return { exitCode: 0, output: '' };
  };
  const logs = [];
  const bridge = new PhoneHdcWorkflowBridge({ filesDir: '/sandbox' }, {}, text => logs.push(text));
  // Avoid overlay-settle real time, retaining the production transfer and bounds validation.
  bridge.pause = async () => {};
  assert.equal(await bridge.dumpUiLayout(), bytes.toString('utf8'));
  assert.equal(shellCalls.filter(x => x.startsWith('dd ')).length, Math.ceil(bytes.length / 49152));
  assert.ok(shellCalls.at(-1).startsWith("rm -f '/data/local/tmp/self_hdc_ui_"));
  assert.equal(restored, 1);
  assert.ok(!logs.some(x => x.includes('小赵') || x.includes('中文')));
  shellHandler = async command => ({ exitCode: 0, output: command.startsWith('wc -c') ? '99999999' : '' });
  await assert.rejects(bridge.dumpUiLayout(), /exceeds 4 MiB/);
  assert.equal(restored, 2);
});
async function main() {
  for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  console.log('Passed ' + cases.length + ' phone WeChat checks; no device actions performed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
