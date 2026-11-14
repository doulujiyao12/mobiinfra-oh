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
  const state = { failRead: false, failFlush: false, waitFlush: null };
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
    async flush() { if (state.waitFlush) await state.waitFlush; if (state.failFlush) throw Error('disk failure'); }
  };
  const recorderController = {
    initialize: () => calls.push('recorder-init'), setForeground: value => calls.push(['foreground', value]),
    async destroy() { calls.push('recorder-destroy'); }, async stopPlayback() {}
  };
  const phoneSyncController = {
    initialize: () => calls.push('sync-init'), async connect() { calls.push('connect'); },
    async destroy() { calls.push('sync-destroy'); }
  };
  const external = {
    '@kit.AbilityKit': { UIAbility: class { context = context; }, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0 } } },
    '@kit.ArkUI': {},
    '@kit.ArkData': { preferences: { getPreferencesSync: () => { if (state.failRead) throw Error('read failed'); return settings; } } },
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
  const Ability = load('entryability/HiWearMainAbility.ets').default;
  function page(names) {
    const text = fs.readFileSync(path.join(base, 'pages/Index.ets'), 'utf8');
    const tree = ts.createSourceFile('page.ts', text.replace('struct Index', 'class Index'), ts.ScriptTarget.Latest, true);
    const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'Index');
    const methods = names.map(name => {
      const method = component.members.find(n => ts.isMethodDeclaration(n) && n.name?.getText(tree) === name);
      assert(method, name); return method.getText(tree);
    });
    const exports = {};
    vm.runInNewContext(compile('exports.Page = class {' + methods.join('\n') + '}'), {
      exports, ...policy, watchPrivacyConsent: consent, recorderController
    });
    const instance = new exports.Page();
    Object.assign(instance, { pageActive: true, privacyAccepted: false, privacyBusy: false,
      privacyError: '', policyVisible: false, deletionTargets: [], getUIContext: () => ({ getHostContext: () => context }) });
    return instance;
  }
  return { values, calls, listeners, state, context, policy, consent, Ability, page };
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
  assert.equal(page.privacyAccepted, true); assert(h.calls.includes('recorder-init')); await ability.onDestroy();
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
