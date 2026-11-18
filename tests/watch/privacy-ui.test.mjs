// Offline lifecycle/consent/deletion checks. No device, real preferences or network.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { loadSdkTypeScript } from './sdk-paths.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const base = path.join(root, 'watch_entry/src/main/ets');
const ts = loadSdkTypeScript();
const compile = source => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture(saved = {}) {
  const values = new Map(Object.entries(saved)), calls = [], listeners = new Map(), modules = new Map();
  const state = { failRead: false, failFlush: false, waitFlush: null, flushCount: 0, preferenceStores: [],
    frames: [], mounted: true, failSchedule: false };
  const context = {
    getApplicationContext: () => ({ setColorMode() {} }),
    eventHub: {
      on: (key, fn) => listeners.set(key, fn),
      off: (key, fn) => { if (listeners.get(key) === fn) listeners.delete(key); },
      emit: key => listeners.get(key)?.()
    },
    async terminateSelf() { calls.push('exit'); }
  };
  const settings = {
    getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
    putSync: (key, value) => values.set(key, value),
    async flush() { state.flushCount++; if (state.waitFlush) await state.waitFlush; if (state.failFlush) throw Error('disk failure'); }
  };
  const recorderController = {
    initialize: () => calls.push('recorder-init'), setForeground: value => calls.push(['foreground', value]),
    async destroy() { calls.push('recorder-destroy'); }, async stopPlayback() {}, subscribe() {}, unsubscribe() {}
  };
  const phoneSyncController = {
    initialize: () => calls.push('sync-init'), async connect() { calls.push('connect'); },
    async destroy() { calls.push('sync-destroy'); }, subscribe() {}, unsubscribe() {}
  };
  const external = {
    '@kit.AbilityKit': { UIAbility: class { context = context; }, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0 } } },
    '@kit.ArkUI': { FrameCallback: class {} },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
    '@kit.ArkData': { preferences: { getPreferencesSync: (_, options) => {
      state.preferenceStores.push(options.name);
      if (state.failRead) throw Error('read failed');
      return settings;
    } } },
    '../services/RecorderController': { recorderController }, '../services/PhoneSyncController': { phoneSyncController },
    '../services/BackgroundTasks': { backgroundTasks: { destroy: () => calls.push('background-destroy') } }
  };
  function load(relative) {
    const file = path.resolve(base, relative);
    if (modules.has(file)) return modules.get(file);
    const exports = {}; modules.set(file, exports);
    vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, Promise, require: name => {
      if (external[name]) return external[name];
      const target = ['.ts', '.ets'].map(ext => path.resolve(path.dirname(file), name + ext)).find(fs.existsSync);
      assert(target, name); return load(target);
    } }, { filename: file });
    return exports;
  }
  const policy = load('config/WatchPrivacyPolicy.ts');
  const consent = load('services/WatchPrivacyConsent.ets').watchPrivacyConsent;
  const { WatchPhoneGuide } = load('services/WatchPhoneGuide.ets');
  const { WatchCrownFocus } = load('services/WatchCrownFocus.ets');
  const Ability = load('entryability/HiWearMainAbility.ets').default;
  function page(names) {
    const text = fs.readFileSync(path.join(base, 'pages/Index.ets'), 'utf8');
    const tree = ts.createSourceFile('page.ts', text.replace('struct Index', 'class Index'), ts.ScriptTarget.Latest, true);
    const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'Index');
    const methods = [...new Set([...names, 'preparePhoneGuide'])].map(name => {
      const method = component.members.find(n => ts.isMethodDeclaration(n) && n.name?.getText(tree) === name);
      assert(method, name); return method.getText(tree);
    });
    const exports = {};
    vm.runInNewContext(compile('exports.Page = class {' + methods.join('\n') + '}'), {
      exports, ...policy, watchPrivacyConsent: consent, recorderController, phoneSyncController, WatchPhoneGuide
    });
    const instance = new exports.Page();
    Object.assign(instance, { pageActive: true, pageVisible: false, crownFocus: new WatchCrownFocus(), privacyAccepted: false, privacyBusy: false,
      privacyError: '', policyVisible: false, deletionTargets: [], phoneGuideVisible: false, hidePhoneGuide: false,
      phoneGuideBusy: false, phoneGuideError: '', getUIContext: () => ({ getHostContext: () => context,
        postFrameCallback: frame => { if (state.failSchedule) throw Error('window closed'); state.frames.push(frame); },
        getFocusController: () => ({ requestFocus: id => {
          if (!state.mounted) throw Object.assign(Error('component does not exist'), { code: 150003 });
          calls.push(['focus', id]);
        } }) }) });
    return instance;
  }
  const render = () => { const frames = state.frames.splice(0); frames.forEach(frame => frame.onIdle(0)); };
  return { values, calls, listeners, state, context, policy, consent, Ability, page, render };
}

test('first launch and unacknowledged events cannot initialize audio or phone synchronization', async () => {
  const h = fixture(), ability = new h.Ability();
  ability.onCreate(); ability.onForeground(); h.context.eventHub.emit(h.policy.WATCH_PRIVACY_ACCEPTED_EVENT);
  assert.equal(h.consent.isAccepted(), false); assert.deepEqual(h.calls, []);
  let release; h.state.waitFlush = new Promise(resolve => { release = resolve; });
  const accepting = h.consent.accept();
  h.context.eventHub.emit(h.policy.WATCH_PRIVACY_ACCEPTED_EVENT);
  assert.deepEqual(h.calls, [], 'Persisted agreement is required before services can start');
  release(); await accepting; h.context.eventHub.emit(h.policy.WATCH_PRIVACY_ACCEPTED_EVENT);
  ability.onForeground();
  assert.equal(h.calls.filter(x => x === 'recorder-init').length, 1);
  assert.equal(h.calls.filter(x => x === 'sync-init').length, 1);
  await ability.onDestroy(); assert.equal(h.listeners.size, 0);
});

test('the same accepted policy survives reopening, while an obsolete policy requires a new choice', async () => {
  const h = fixture(); h.consent.initialize(h.context); await h.consent.accept();
  h.consent.initialize(h.context); assert.equal(h.consent.isAccepted(), true);
  const ability = new h.Ability(); ability.onCreate(); ability.onForeground();
  assert(h.calls.includes('recorder-init')); await ability.onDestroy();
  const old = fixture({ accepted_policy_version: 'old-policy' }); old.consent.initialize(old.context);
  assert.equal(old.consent.isAccepted(), false);
});

test('read and persistence failures fail closed and a retry can save the explicit choice', async () => {
  const h = fixture(); h.state.failRead = true; h.consent.initialize(h.context);
  assert.equal(h.consent.isAccepted(), false); await assert.rejects(h.consent.accept(), /无法保存/);
  h.state.failRead = false; h.state.failFlush = true;
  await assert.rejects(h.consent.accept(), /无法保存/);
  assert.equal(h.consent.isAccepted(), false); assert.equal(h.values.get('accepted_policy_version'), '');
  h.state.failFlush = false; await h.consent.accept(); assert.equal(h.consent.isAccepted(), true);
});

test('decline exits without consent and Back cannot expose the main UI', async () => {
  const h = fixture(), ability = new h.Ability(); ability.onCreate(); ability.onForeground();
  const page = h.page(['declinePrivacy', 'onBackPress']);
  page.policyVisible = true; assert.equal(page.onBackPress(), true); assert.equal(page.policyVisible, false);
  assert.equal(page.onBackPress(), false, 'Default system Back exits rather than exposing the recorder');
  await page.declinePrivacy(); assert.deepEqual(h.calls, ['exit']); assert.equal(h.consent.isAccepted(), false);
  await ability.onDestroy();
});

test('UI agreement emits only after persistence; a late result cannot start services on a closed page', async () => {
  const h = fixture(), ability = new h.Ability(); ability.onCreate(); ability.onForeground();
  const page = h.page(['agreePrivacy']); await page.agreePrivacy();
  assert.equal(page.privacyAccepted, true); assert(h.calls.includes('recorder-init'));
  assert.equal(page.privacyError, ''); assert.equal(page.phoneGuideVisible, true);
  await ability.onDestroy();
  const other = fixture(), late = new other.Ability(); late.onCreate(); late.onForeground();
  let release; other.state.waitFlush = new Promise(resolve => { release = resolve; });
  const closed = other.page(['agreePrivacy']), saving = closed.agreePrivacy();
  closed.pageActive = false; late.onBackground(); await late.onDestroy(); release(); await saving;
  assert.deepEqual(other.calls, []);
});

test('accepting in the background defers initialization until the next foreground transition', async () => {
  const h = fixture(), ability = new h.Ability(); ability.onCreate(); ability.onForeground(); ability.onBackground();
  await h.consent.accept(); h.context.eventHub.emit(h.policy.WATCH_PRIVACY_ACCEPTED_EVENT);
  assert.deepEqual(h.calls, []); ability.onForeground(); assert(h.calls.includes('recorder-init'));
  await ability.onDestroy();
});

test('deletion confirmation stores a snapshot, cancels with Back and deletes only after one explicit confirmation', async () => {
  const h = fixture(), page = h.page(['confirmDeletion', 'deleteConfirmed', 'onBackPress']), deleted = [];
  Object.assign(page, { privacyAccepted: true, snapshot: { status: 'ready' },
    deleteFromLibrary: async records => { deleted.push(records.map(r => r.name)); } });
  const selected = [{ name: 'a' }, { name: 'b' }]; page.confirmDeletion(selected); selected.pop();
  assert.equal(deleted.length, 0); assert.equal(page.deletionTargets.length, 2);
  assert.equal(page.onBackPress(), true); assert.equal(page.deletionTargets.length, 0); assert.equal(deleted.length, 0);
  page.confirmDeletion(selected); page.deleteConfirmed(); page.deleteConfirmed();
  assert.deepEqual(deleted, [['a']]);
});

test('dialog rectangle fits inside round displays and both policy paths use the submitted URL and identity', () => {
  const h = fixture();
  const dialog = fs.readFileSync(path.join(base, 'components/WatchRoundDialog.ets'), 'utf8');
  const width = Number(dialog.match(/WATCH_DIALOG_WIDTH_PERCENT: number = (\d+)/)[1]);
  const height = Number(dialog.match(/WATCH_DIALOG_HEIGHT_PERCENT: number = (\d+)/)[1]);
  for (const diameter of [240, 280, 320, 466]) {
    assert(Math.hypot(diameter * width / 200, diameter * height / 200) < diameter / 2);
  }
  assert(dialog.includes('Scroll()')); assert(dialog.includes('.layoutWeight(1)'));
  assert.equal(h.policy.WATCH_PRIVACY_APP_NAME, 'clawmate'); assert.equal(h.policy.WATCH_PRIVACY_DEVELOPER, '冯二虎');
  assert.equal(h.policy.WATCH_PRIVACY_POLICY_URL,
    'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2069956295837932224');
  const policy = fs.readFileSync(path.join(base, 'components/WatchPrivacyPolicyView.ets'), 'utf8');
  assert(policy.includes('QRCode(WATCH_PRIVACY_POLICY_URL)')); assert(policy.includes('context.openLink(WATCH_PRIVACY_POLICY_URL)'));
});

test('dialog permits child touch and keeps the policy entry outside the clipped scroll body', () => {
  const dialog = fs.readFileSync(path.join(base, 'components/WatchRoundDialog.ets'), 'utf8');
  assert(dialog.includes('.hitTestBehavior(HitTestMode.Default)'), 'Overlay must allow child touch');
  assert(!dialog.includes('HitTestMode.Block'), 'Block prevents the Scroll and buttons receiving touch');
  const scrollStart = dialog.indexOf('Scroll()');
  const scrollEnd = dialog.indexOf('.clip(true)', scrollStart);
  const scrollBody = dialog.slice(scrollStart, scrollEnd);
  assert(scrollBody.includes('this.contentBuilder()'));
  assert(scrollBody.includes('.enableScrollInteraction(true)'));
  assert(!scrollBody.includes('this.contentActionBuilder()'), 'Policy link must not scroll out of view');
  assert(dialog.indexOf('this.contentActionBuilder()') > scrollEnd);

  const page = fs.readFileSync(path.join(base, 'pages/Index.ets'), 'utf8');
  const message = page.slice(page.indexOf('@Builder private PrivacyMessage()'), page.indexOf('@Builder private PrivacyPolicyAction()'));
  assert(!message.includes('Button('));
  assert(page.includes('showContentAction: true, contentActionBuilder: (): void => { this.PrivacyPolicyAction(); }'));

  const height = Number(dialog.match(/WATCH_DIALOG_HEIGHT_PERCENT: number = (\d+)/)[1]);
  // Default text sizes: padding 24, title 20, link 32, footer 34 and three gaps of 8 vp.
  assert(240 * height / 100 - 24 - 20 - 32 - 34 - 24 >= 32, 'Reserve a usable body viewport on small watches');
});

test('phone guide waits for privacy consent; ordinary dismissal appears again on the next launch', async () => {
  const h = fixture(); h.consent.initialize(h.context);
  const fresh = h.page(['aboutToAppear']); fresh.aboutToAppear();
  assert.equal(fresh.phoneGuideVisible, false);
  assert(!h.state.preferenceStores.includes('watch_onboarding'));
  await h.consent.accept();
  const page = h.page(['aboutToAppear', 'dismissPhoneGuide']); page.aboutToAppear();
  assert.equal(page.phoneGuideVisible, true);
  const flushes = h.state.flushCount;
  await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideVisible, false); assert.equal(h.state.flushCount, flushes);
  const reopened = h.page(['aboutToAppear']); reopened.aboutToAppear();
  assert.equal(reopened.phoneGuideVisible, true);
});

test('explicit opt-out persists after dismissal, without changing privacy consent', async () => {
  const h = fixture(); h.consent.initialize(h.context); await h.consent.accept();
  const page = h.page(['dismissPhoneGuide']); page.preparePhoneGuide(); page.hidePhoneGuide = true;
  await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideVisible, false); assert.equal(page.phoneGuideBusy, false);
  assert.equal(h.values.get('phone_guide_hidden'), true); assert.equal(h.consent.isAccepted(), true);
  const reopened = h.page([]); reopened.preparePhoneGuide();
  assert.equal(reopened.phoneGuideVisible, false);
});

test('failed opt-out remains visible, restores its preference and supports a successful retry', async () => {
  const h = fixture(), page = h.page(['dismissPhoneGuide']);
  page.preparePhoneGuide(); page.hidePhoneGuide = true; h.state.failFlush = true;
  await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideVisible, true); assert.equal(page.phoneGuideBusy, false);
  assert.notEqual(page.phoneGuideError, ''); assert.equal(h.values.get('phone_guide_hidden'), false);
  const reopened = h.page([]); reopened.preparePhoneGuide(); assert.equal(reopened.phoneGuideVisible, true);
  h.state.failFlush = false; await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideError, ''); assert.equal(page.phoneGuideVisible, false);
});

test('preference read failure still allows dismissing the phone guide without opting out', async () => {
  const h = fixture(), page = h.page(['dismissPhoneGuide']); h.state.failRead = true;
  page.preparePhoneGuide(); assert.equal(page.phoneGuideVisible, true);
  await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideVisible, false); assert.equal(h.state.flushCount, 0);
});

test('Back closes the phone guide; duplicate opt-out taps cannot start multiple saves', async () => {
  const h = fixture(), page = h.page(['dismissPhoneGuide', 'onBackPress']);
  page.privacyAccepted = true; page.preparePhoneGuide();
  assert.equal(page.onBackPress(), true); assert.equal(page.phoneGuideVisible, false);
  page.preparePhoneGuide(); page.hidePhoneGuide = true;
  let release; h.state.waitFlush = new Promise(resolve => { release = resolve; });
  const pending = page.dismissPhoneGuide(); await page.dismissPhoneGuide();
  assert.equal(page.phoneGuideBusy, true); assert.equal(h.state.flushCount, 1);
  release(); await pending;
  assert.equal(page.phoneGuideVisible, false); assert.equal(page.phoneGuideBusy, false);
});

test('crown focus follows visible content and returns to the page after overlays close', () => {
  const h = fixture(), page = h.page(['restoreCrownFocus', 'mainContentEnabled', 'onPageShow']);
  const target = () => { page.onPageShow(); h.render(); return h.calls.at(-1)[1]; };
  assert.equal(target(), 'watch-dialog-scroll', 'Initial privacy dialog');
  page.policyVisible = true; assert.equal(target(), 'watch-policy-scroll');
  page.policyVisible = false; page.privacyAccepted = true; page.preparePhoneGuide();
  assert.equal(target(), 'watch-dialog-scroll'); assert.equal(page.mainContentEnabled(), false);
  page.phoneGuideVisible = false; assert.equal(target(), 'watch-page-scroll');
  assert.equal(page.mainContentEnabled(), true);
  page.deletionTargets = [{ name: 'recording.wav' }];
  assert.equal(target(), 'watch-dialog-scroll'); assert.equal(page.mainContentEnabled(), false);
  page.deletionTargets = []; assert.equal(target(), 'watch-page-scroll');
  const count = h.calls.length; page.pageActive = false; page.restoreCrownFocus();
  assert.equal(h.calls.length, count, 'Do not request focus on an unmounted page');
});

test('startup observer does not focus unmounted content; focus waits until frame end', () => {
  const h = fixture(), page = h.page(['restoreCrownFocus', 'onPageShow']);
  h.state.mounted = false;
  page.privacyAccepted = true; page.restoreCrownFocus();
  assert.equal(h.state.frames.length, 0, 'aboutToAppear precedes page visibility');
  page.onPageShow(); assert.equal(h.calls.length, 0);
  h.state.mounted = true; h.render();
  assert.deepEqual(h.calls, [['focus', 'watch-page-scroll']]);
});

test('multiple UI changes coalesce and resolve the latest visible target after layout', () => {
  const h = fixture(), page = h.page(['restoreCrownFocus', 'onPageShow']);
  page.onPageShow(); page.privacyAccepted = true; page.restoreCrownFocus();
  page.phoneGuideVisible = true; page.restoreCrownFocus();
  page.phoneGuideVisible = false; page.policyVisible = true; page.restoreCrownFocus();
  assert.equal(h.state.frames.length, 1); h.render();
  assert.deepEqual(h.calls, [['focus', 'watch-policy-scroll']]);
});

test('hide and destroy invalidate old callbacks even if the page is shown again before they run', () => {
  const h = fixture(), page = h.page(['restoreCrownFocus', 'onPageShow', 'onPageHide', 'aboutToDisappear']);
  page.onPageShow(); page.onPageHide(); page.privacyAccepted = true; page.onPageShow();
  h.render(); assert.deepEqual(h.calls, [['focus', 'watch-page-scroll']]);
  page.restoreCrownFocus(); page.aboutToDisappear(); h.render();
  assert.equal(h.calls.length, 1);
});

test('unavailable focus target and destroyed UI context cannot crash or block future focus', () => {
  const h = fixture(), page = h.page(['restoreCrownFocus', 'onPageShow']);
  h.state.failSchedule = true; assert.doesNotThrow(() => page.onPageShow());
  h.state.failSchedule = false; h.state.mounted = false;
  page.restoreCrownFocus(); assert.doesNotThrow(() => h.render());
  h.state.mounted = true; page.restoreCrownFocus(); h.render();
  assert.deepEqual(h.calls, [['focus', 'watch-dialog-scroll']]);
});
