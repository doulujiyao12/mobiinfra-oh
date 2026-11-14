// Offline checks of saved settings and production Worker routing; no device or microphone.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { loadSdkTypeScript } from './sdk-paths.mjs';
import { createHarness } from './worker-harness.mjs';
import { detectionProfile, normalizeRecordingSensitivity } from '../../watch_entry/src/main/ets/core/AudioGate.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ts = loadSdkTypeScript();

function settingsFixture(values = new Map()) {
  const commands = [], snapshots = [], cache = new Map(), state = { failFlush: false, flushes: 0 };
  const settings = {
    getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
    putSync: (key, value) => values.set(key, value),
    flush: async () => { state.flushes++; if (state.failFlush) throw Error('disk failure'); }
  };
  const mocks = {
    '@kit.ArkData': { preferences: { getPreferencesSync: () => settings } },
    '@kit.ArkTS': { worker: { ThreadWorker: class { postMessage(command) { commands.push(command); } } } },
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({
      requestPermissionsFromUser: async () => ({ authResults: [0] })
    }) } },
    './BackgroundTasks': { backgroundTasks: { initialize() {}, onCancel() {} } },
    './PhoneSyncController': { phoneSyncController: {} }
  };
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    vm.runInNewContext(code, { exports, canIUse: () => true, setTimeout: () => 1, clearTimeout() {},
      require: id => {
        if (mocks[id]) return mocks[id];
        if (id.startsWith('@kit.')) return {};
        const actual = ['.ts', '.ets'].map(ext => path.resolve(path.dirname(file), id + ext)).find(fs.existsSync);
        assert(actual, id); return load(actual);
      } }, { filename: file });
    return exports;
  }
  const controller = load(path.join(root, 'watch_entry/src/main/ets/services/RecorderController.ets')).recorderController;
  controller.subscribe(value => snapshots.push(value));
  controller.initialize({ filesDir: '/mock/watch/files' });
  controller.captureWorker.onmessage({ data: { kind: 'ready', message: '' } });
  controller.setForeground(true);
  return { controller, values, commands, snapshots, state };
}

test('normal retains all original thresholds; speech uses existing VAD levels 1, 2 and 3', () => {
  assert.deepEqual({ ...detectionProfile('normal') }, { speechAggressiveness: 2,
    openMinDb: -42, openMaxDb: -24, openMarginDb: 10, holdMinDb: -48, holdMaxDb: -30, holdMarginDb: 6 });
  assert.deepEqual(['sensitive', 'normal', 'strict'].map(level => detectionProfile(level).speechAggressiveness), [1, 2, 3]);
  for (const invalid of ['', 'old-value', 'NORMAL']) assert.equal(normalizeRecordingSensitivity(invalid), 'normal');
});

test('existing installs default to normal; both modes retain separate saved choices after reopening', async () => {
  const h = settingsFixture();
  assert.equal(h.controller.state.soundSensitivity, 'normal');
  assert.equal(h.controller.state.speechSensitivity, 'normal');
  await h.controller.selectSensitivity('sound', 'sensitive');
  await h.controller.selectSensitivity('speech', 'strict');
  assert.equal(h.state.flushes, 2);
  assert.equal(h.controller.state.mode, 'sound', 'adjusting the other mode must not switch capture mode');
  const reopened = settingsFixture(h.values);
  assert.equal(reopened.controller.state.soundSensitivity, 'sensitive');
  assert.equal(reopened.controller.state.speechSensitivity, 'strict');
  assert.equal(reopened.snapshots.at(-1).soundSensitivity, 'sensitive');
  assert.equal(reopened.snapshots.at(-1).speechSensitivity, 'strict');
});

test('start sends the chosen mode sensitivity and settings cannot change during capture or transitions', async () => {
  const h = settingsFixture();
  await h.controller.selectSensitivity('sound', 'sensitive');
  await h.controller.selectSensitivity('speech', 'strict');
  await h.controller.selectMode('speech');
  await h.controller.start();
  assert.equal(h.commands.at(-1).kind, 'start');
  assert.equal(h.commands.at(-1).mode, 'speech');
  assert.equal(h.commands.at(-1).sensitivity, 'strict');
  const writes = h.state.flushes;
  for (const status of ['starting', 'recording', 'stopping', 'deleting', 'loading']) {
    h.controller.state.status = status;
    await h.controller.selectSensitivity('speech', 'sensitive');
    assert.equal(h.controller.state.speechSensitivity, 'strict');
  }
  assert.equal(h.state.flushes, writes);
  h.controller.state.status = 'ready';
  await h.controller.selectMode('sound');
  await h.controller.start();
  assert.equal(h.commands.at(-1).sensitivity, 'sensitive');
});

test('invalid saved values fall back safely and a failed save is reported to the user', async () => {
  const h = settingsFixture(new Map([['sound_sensitivity', 7], ['speech_sensitivity', 'old-value']]));
  assert.equal(h.controller.state.soundSensitivity, 'normal');
  assert.equal(h.controller.state.speechSensitivity, 'normal');
  await h.controller.selectSensitivity('sound', 'invalid');
  assert.equal(h.state.flushes, 0);
  h.state.failFlush = true;
  await h.controller.selectSensitivity('sound', 'strict');
  assert.match(h.snapshots.at(-1).error, /未能记住选择/);
  h.state.failFlush = false;
  await h.controller.selectSensitivity('sound', 'strict');
  assert.equal(h.snapshots.at(-1).error, '');
});

function directory(t) {
  const parent = path.join(root, '.codex-tmp/watch-tests'); fs.mkdirSync(parent, { recursive: true });
  const dir = fs.mkdtempSync(path.join(parent, 'sensitivity-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function pcm(rate, amplitude) {
  return Int16Array.from({ length: rate / 5 }, (_, i) => i % 2 ? -amplitude : amplitude).buffer;
}

test('Worker uses each selected VAD strength at both capture rates, with legacy commands retaining normal', async t => {
  for (const rate of [16000, 48000]) {
    for (const [sensitivity, expected] of [['sensitive', 1], ['normal', 2], ['strict', 3], [undefined, 2]]) {
      let calls = 0;
      const h = await createHarness(directory(t), { reject16k: rate === 48000,
        speechClassifier: (_pcm, actualRate, actualMode) => {
          assert.equal(actualRate, rate); assert.equal(actualMode, expected); calls++; return true;
        } });
      t.after(h.dispose);
      await h.post({ kind: 'start', mode: 'speech', sensitivity });
      h.capture(pcm(rate, 100));
      await h.post({ kind: 'stop' });
      assert.equal(calls, 10);
      assert.equal(h.state.detectorCloses, 1);
      assert.equal(h.events.findLast(event => event.kind === 'library').records.length, 1);
      h.dispose();
    }
  }
});

test('Worker passes the selected environment threshold into the gate rather than merely changing UI', async t => {
  for (const sensitivity of ['sensitive', 'normal', 'strict']) {
    const h = await createHarness(directory(t)); t.after(h.dispose);
    await h.post({ kind: 'start', mode: 'sound', sensitivity });
    h.capture(pcm(16000, 400));
    await h.post({ kind: 'stop' });
    assert.equal(h.events.findLast(event => event.kind === 'library').records.length, sensitivity === 'strict' ? 0 : 1);
    assert.equal(h.state.detectorCalls, 0);
    h.dispose();
  }
});
