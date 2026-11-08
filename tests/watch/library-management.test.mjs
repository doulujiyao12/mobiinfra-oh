// In-memory tests of production deletion and date/selection logic. No device or files are deleted.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { loadSdkTypeScript } from './sdk-paths.mjs';

process.env.TZ = 'Asia/Shanghai';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const base = 'watch_entry/src/main/ets/';
const ts = loadSdkTypeScript();
const clone = value => JSON.parse(JSON.stringify(value));
function compile(source) {
  return ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
}
function harness() {
  const cache = new Map(), protectedNames = new Set(), commands = [];
  const mocks = { './BackgroundTasks': { backgroundTasks: {} },
    './PhoneSyncController': { phoneSyncController: { isFileInUse: name => protectedNames.has(name) } } };
  function load(relative) {
    const file = path.resolve(root, relative);
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, Date, Map, Set, Promise,
      setTimeout, clearTimeout, setInterval, clearInterval, require: id => {
        if (mocks[id]) return mocks[id];
        if (id.startsWith('@kit.')) return {};
        const target = ['.ts', '.ets'].map(ext => path.resolve(path.dirname(file), id + ext)).find(fs.existsSync);
        assert(target, id); return load(path.relative(root, target));
      } }, { filename: file });
    return exports;
  }
  const models = load(base + 'model/RecorderModels.ts');
  const library = load(base + 'core/RecordingLibrary.ts');
  const wav = load(base + 'core/Wav.ts');
  const controller = load(base + 'services/RecorderController.ets').recorderController;
  Object.assign(controller, { captureWorker: { postMessage: command => commands.push(command) }, foreground: true });
  controller.state.status = 'ready';
  const record = (offset, createdAt = '2026-11-08T12:00:00+08:00') => Object.assign(new models.RecordingInfo(), {
    name: wav.triggeredFileName(1793520000000 + offset * 10000, offset, 16000, 'sound'), createdAt: new Date(createdAt).getTime()
  });
  const ack = async (deleted, failed = [], id = commands.at(-1).requestId) => {
    const event = Object.assign(new models.CaptureEvent(), { kind: 'deleted', requestId: id, deletedNames: deleted, failedNames: failed });
    await controller.handleCaptureEvent(event);
  };
  return { load, library, models, wav, controller, commands, protectedNames, record, ack };
}

test('date filtering uses local day boundaries, supports old years and preserves the full library', () => {
  const h = harness(), a = h.record(1, '2026-11-07T15:59:59Z'), b = h.record(2, '2026-11-07T16:00:00Z'),
    old = h.record(3, '2025-12-31T12:00:00+08:00');
  const records = [b, a, old], before = clone(records);
  assert.deepEqual(clone(h.library.recordingLibraryDays(records)), [
    { key: '2026-11-08', count: 1 }, { key: '2026-11-07', count: 1 }, { key: '2025-12-31', count: 1 }
  ]);
  assert.equal(h.library.recordingsForLibraryDate(records, '') , records);
  assert.equal(h.library.recordingsForLibraryDate(records, '2026-11-08')[0], b);
  assert.equal(h.library.recordingsForLibraryDate(records, '2026-11-06').length, 0);
  assert.equal(h.library.recordingLibraryDateLabel('2025-12-31', new Date('2026-11-08')), '2025年12月31日');
  assert.deepEqual(clone(records), before);
});

test('multi-selection and select-all affect only the visible day, skip syncing files and reset on date changes', () => {
  const h = harness(), text = fs.readFileSync(path.join(root, base, 'pages/Index.ets'), 'utf8');
  const tree = ts.createSourceFile('page.ts', text.replace('struct Index', 'class Index'), ts.ScriptTarget.Latest, true);
  const page = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'Index');
  const names = ['busy', 'libraryRecords', 'clearSelection', 'chooseLibraryDate', 'toggleRecording', 'selectableRecords', 'allRecordsSelected', 'toggleAllRecords', 'confirmSelectedDeletion'];
  const methods = page.members.filter(n => ts.isMethodDeclaration(n) && names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n');
  const exports = {}; vm.runInNewContext(compile('exports.Page = class {' + methods + '}'), { exports, ...h.library });
  const p = new exports.Page(), a = h.record(1), syncing = h.record(2), yesterday = h.record(3, '2026-11-07');
  Object.assign(p, { snapshot: { status: 'ready', records: [a, syncing, yesterday] }, libraryDate: '2026-11-08',
    selectionMode: true, selectedNames: [], sync: { currentId: syncing.name }, pageScroller: { scrollTo() {} }, confirmDeletion: rows => { p.confirmed = rows; } });
  p.toggleAllRecords(); assert.deepEqual(clone(p.selectedNames), [a.name]); assert(p.allRecordsSelected());
  p.confirmSelectedDeletion(); assert.deepEqual(clone(p.confirmed.map(r => r.name)), [a.name]);
  p.toggleRecording(syncing); assert.equal(p.selectedNames.length, 1);
  p.chooseLibraryDate('invalid'); assert.equal(p.libraryDate, '2026-11-08');
  p.chooseLibraryDate('2026-11-07'); assert.equal(p.selectedNames.length, 0); assert.equal(p.selectionMode, false);
  assert.equal(p.libraryRecords()[0], yesterday);
  p.chooseLibraryDate(''); assert.equal(p.libraryRecords().length, 3);
});

test('controller waits for actual worker results, prevents duplicate deletion and preserves syncing recordings', async () => {
  const h = harness(), a = h.record(1), syncing = h.record(2); h.controller.state.records = [a, syncing];
  h.protectedNames.add(syncing.name); let resolved = false;
  const pending = h.controller.deleteRecordings([a, a, syncing]).then(value => { resolved = true; return value; });
  assert.equal(h.controller.state.status, 'deleting'); assert.deepEqual(clone(h.commands[0].names), [a.name]);
  await Promise.resolve(); assert.equal(resolved, false);
  await assert.rejects(h.controller.deleteRecordings([a]), /等待/); assert.equal(h.commands.length, 1);
  await h.ack([a.name], [], 'stale'); assert.equal(resolved, false);
  await h.ack([a.name]); const result = await pending;
  assert.deepEqual(clone(result.deletedNames), [a.name]); assert.deepEqual(clone(result.protectedNames), [syncing.name]);
  assert.equal(h.controller.state.status, 'ready');
});

test('playback is released before deletion and syncing protection is rechecked after release', async () => {
  const h = harness(), a = h.record(1); h.controller.state.records = [a]; h.controller.state.playingName = a.name;
  let release; h.controller.stopPlayback = () => new Promise(resolve => { release = resolve; });
  const pending = h.controller.deleteRecordings([a]); assert.equal(h.commands.length, 0);
  await assert.rejects(h.controller.deleteRecordings([a]), /等待/);
  h.protectedNames.add(a.name); release(); const result = await pending;
  assert.deepEqual(clone(result.protectedNames), [a.name]); assert.equal(h.commands.length, 0);
  assert.equal(h.controller.state.status, 'ready');
});

test('controller reports partial results and releases pending requests on worker error, crash or failed posting', async () => {
  for (const failure of ['partial', 'error', 'crash', 'post']) {
    const h = harness(), a = h.record(1), b = h.record(2); h.controller.state.records = [a, b];
    if (failure === 'post') h.controller.captureWorker.postMessage = () => { throw Error('post failed'); };
    const pending = h.controller.deleteRecordings([a, b]);
    if (failure === 'partial') { await h.ack([a.name], [b.name]); assert.deepEqual(clone((await pending).failedNames), [b.name]); }
    else {
      const rejected = assert.rejects(pending, /failed|error|crash/);
      if (failure === 'error') await h.controller.handleCaptureEvent(Object.assign(new h.models.CaptureEvent(), { kind: 'error', requestId: h.commands[0].requestId, message: 'error' }));
      if (failure === 'crash') h.controller.workerFailed('crash');
      await rejected;
    }
    assert.notEqual(h.controller.state.status, 'deleting'); assert.equal(h.controller.deletion, undefined);
  }
});

test('worker validates the entire batch first, deduplicates names and continues past an individual I/O failure', async () => {
  const h = harness(), filename = path.join(root, base, 'workers/RecorderWorker.ets');
  const source = ts.createSourceFile('worker.ts', fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true);
  const dispatch = source.statements.find(n => ts.isFunctionDeclaration(n) && n.name?.text === 'dispatch').getText(source);
  const removed = [], events = []; let refreshed = 0, bad = '';
  const exports = {};
  vm.runInNewContext(compile(dispatch + '\nexports.dispatch = dispatch;'), { exports, CaptureEvent: h.models.CaptureEvent,
    running: false, starting: false, closing: false, directory: '/recordings', parseRecordingName: h.wav.parseRecordingName,
    fs: { unlinkSync: file => { if (file.endsWith(bad) && bad) throw Error('I/O'); removed.push(file); } },
    publishLibrary: () => { refreshed++; }, port: { postMessage: event => events.push(event) } });
  const a = h.record(1), b = h.record(2), c = h.record(3);
  await assert.rejects(exports.dispatch({ kind: 'delete', requestId: 'unsafe', names: [a.name, '../private'] }), /无效/);
  assert.equal(removed.length, 0); bad = b.name;
  await exports.dispatch({ kind: 'delete', requestId: 'batch', names: [a.name, a.name, b.name, c.name] });
  assert.equal(removed.length, 2); assert.equal(refreshed, 1); assert.equal(events[0].requestId, 'batch');
  assert.deepEqual(clone(events[0].deletedNames), [a.name, c.name]); assert.deepEqual(clone(events[0].failedNames), [b.name]);
  await exports.dispatch({ kind: 'delete', name: a.name }); assert.equal(events.length, 2, 'Legacy single-delete commands stay compatible');
});
