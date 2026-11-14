// Offline checks of selection, transfer and post-transfer processing. No device,
// Wear Engine, models, network or HAP build is used.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript'), root = path.resolve(__dirname, '..');
process.env.TZ = 'Asia/Shanghai';
const base = 'entry/src/main/ets/utils/recording/';
const cases = []; const test = (name, run) => cases.push([name, run]);
const clone = value => JSON.parse(JSON.stringify(value));
let sourceId, pages, downloads, connections, closed, unlinked, downloadHook, listHook;
class WatchClient {
  static async devices() { return [{ randomId: 'watch-device', name: 'Watch' }]; }
  async connect(device) { connections.push(device); }
  identity() { return sourceId; }
  async list(cursor) { if (listHook) await listHook(cursor); return pages.get(cursor); }
  async download(id, existing) {
    downloads.push([id, existing]); if (downloadHook) await downloadHook(id);
    return { sourceId, recording: { id, createdAt: Date.now() }, sha256: 'abc', path: '/received/' + id };
  }
  async close() { closed++; }
}
function reset() {
  sourceId = 'watch-source'; pages = new Map(); downloads = []; connections = []; closed = 0; unlinked = [];
  downloadHook = null; listHook = null;
}
function load(relative, cache = new Map()) {
  const file = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(code, { exports, Date, Map, Set, require: name => {
    if (name === '@kit.CoreFileKit') return { fileIo: { accessSync: () => true, unlinkSync: value => unlinked.push(value) } };
    if (name === './WatchRecordingClient') return { WatchRecordingClient: WatchClient, watchConnectionMessage: error => error.message };
    if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(file), name)), cache);
    throw Error('Unexpected dependency: ' + name);
  } }, { filename: file });
  return exports;
}
const selection = load(base + 'RecordingWatchSelection');
const { RecordingWatchSync } = load(base + 'RecordingWatchSync');
function remote(id, day = '2026-11-13T01:00:00Z') { return { id, createdAt: new Date(day).getTime(), durationMs: 10000, bytes: 320044 }; }
function item(id, day, localState = 'new') { return { ...remote(id, day), title: '', localState }; }
function record(id, state = 'new') {
  const value = { id, title: id, analysis: null };
  if (state !== 'new') { value.analysis = { segments: [{ text: 'Transcript' }] }; value.transcriptionComplete = state !== 'partial'; }
  if (state === 'done') value.summary = { overview: 'Saved summary', complete: true };
  if (state === 'draft') value.summary = { overview: 'Saved partial summary', complete: false };
  return value;
}
function store(existing = []) {
  let scans = 0; const saved = [];
  return { saved, scans: () => scans, list() { scans++; return existing; }, audioPath: id => '/library/' + id + '/audio.wav',
    async importWatch(value) { const entry = existing.find(r => r.watch?.recordingId === value.recording.id) || record(value.recording.id);
      saved.push(entry); return entry; } };
}
function pageMethods(names) {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/recording/RecordingPage.ets'), 'utf8');
  const tree = ts.createSourceFile('Page.ts', source.replace('struct RecordingPage', 'class RecordingPage'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === 'RecordingPage');
  const method = name => { const found = component.members.find(node => ts.isMethodDeclaration(node) && node.name?.getText(tree) === name);
    assert(found, name); return found.getText(tree).replace(/\bprivate\s+/g, ''); };
  const exports = {};
  vm.runInNewContext(ts.transpileModule('exports.Page = class {' + names.map(method).join('\n') + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText,
  { exports, ...selection, AppLogger: { info() {}, warn() {} }, AppTheme: { dialogText: text => text },
    promptAction: { showDialog: async () => ({ index: 1 }) } });
  return { Page: exports.Page, method };
}

test('dates use local midnight; selections span days and ignore removed or obsolete entries', () => {
  const items = [item('before', '2026-11-12T15:59:59Z'), item('today', '2026-11-12T16:00:00Z'),
    item('removed', '2026-11-13T02:00:00Z', 'audio-deleted')];
  assert.equal(selection.watchRecordingDay(items[0]), '2026-11-12');
  assert.equal(selection.watchRecordingDay(items[1]), '2026-11-13');
  assert.equal(selection.watchRecordingDateCounts(items).get('2026-11-13'), 2);
  const selected = selection.selectWatchRecordings(items, ['before', 'obsolete'], ['today', 'today', 'removed'], true);
  assert.deepEqual(clone(selected), ['before', 'today']);
  assert.deepEqual(clone(selection.selectWatchRecordings(items, selected, ['today'], false)), ['before']);
  assert.equal(selection.filterWatchRecordings(items, '2026-11-12').length, 1);
});

test('catalog reads only metadata, deduplicates pages and joins the local library once', async () => {
  reset(); pages.set('', { recordings: [remote('a')], nextCursor: 'next' });
  pages.set('next', { recordings: [remote('a'), remote('b', '2026-11-12T00:00:00Z')], nextCursor: '' });
  const local = store([{ ...record('local'), audioDeleted: true, watch: { sourceId, recordingId: 'b' } }]);
  const catalog = await new RecordingWatchSync().catalog({}, 'watch-device', local, () => {});
  assert.equal(catalog.sourceId, sourceId); assert.deepEqual(clone(catalog.items.map(r => r.id)), ['a', 'b']);
  assert.equal(catalog.items[1].localState, 'audio-deleted'); assert.equal(downloads.length, 0); assert.equal(local.scans(), 1); assert.equal(closed, 1);
});

test('catalog stops repeated pagination and cannot publish results after cancellation', async () => {
  reset(); pages.set('', { recordings: [], nextCursor: 'a' }); pages.set('a', { recordings: [], nextCursor: 'b' });
  pages.set('b', { recordings: [], nextCursor: 'a' });
  await assert.rejects(new RecordingWatchSync().catalog({}, 'watch-device', store(), () => {}), /列表未能继续/);
  reset(); let release; const wait = new Promise(resolve => { release = resolve; }); listHook = () => wait;
  pages.set('', { recordings: [remote('a')], nextCursor: '' });
  const sync = new RecordingWatchSync(), job = sync.catalog({}, 'watch-device', store(), () => {});
  await Promise.resolve(); await sync.cancel(); release(); await assert.rejects(job, /已停止/); assert.equal(downloads.length, 0);
});

test('sync transfers only selected IDs once, reuses existing paths and respects audio deletion', async () => {
  reset(); const local = store([{ ...record('local-a', 'done'), watch: { sourceId, recordingId: 'a' } },
    { ...record('local-b', 'done'), audioDeleted: true, watch: { sourceId, recordingId: 'b' } }]);
  const received = [], sync = new RecordingWatchSync();
  assert.equal(await sync.sync({}, 'watch-device', local, () => {}, value => received.push(value),
    { sourceId, recordingIds: ['a', 'a', 'b', 'c'] }), 2);
  assert.deepEqual(downloads, [['a', '/library/local-a/audio.wav'], ['c', '']]);
  assert.equal(local.scans(), 1); assert.equal(received.length, 2); assert.equal(local.saved[0].summary.overview, 'Saved summary');
  assert.equal(closed, 1);
});

test('changed watch identity and empty selections never request audio; partial successes stay saved', async () => {
  reset(); const sync = new RecordingWatchSync();
  await assert.rejects(sync.sync({}, 'device', store(), () => {}, () => {}, { sourceId: 'old-source', recordingIds: ['a'] }), /目录已变化/);
  assert.equal(downloads.length, 0);
  await assert.rejects(sync.sync({}, 'device', store(), () => {}, () => {}, { sourceId, recordingIds: [] }), /请先选择/);
  downloadHook = async id => { if (id === 'b') throw Error('transfer interrupted'); };
  const local = store(), received = [];
  await assert.rejects(sync.sync({}, 'device', local, () => {}, value => received.push(value),
    { sourceId, recordingIds: ['a', 'b', 'c'] }), /interrupted/);
  assert.equal(local.saved.length, 1); assert.equal(received.length, 1); assert.equal(downloads.at(-1)[0], 'b');
});

test('processing resumes incomplete transcription or summary and never regenerates complete results', () => {
  for (const [state, expected] of [['new', 'transcribe'], ['partial', 'transcribe'], ['text', 'summarize'], ['draft', 'summarize'], ['done', 'done']]) {
    assert.equal(selection.watchRecordingProcessingStage(record(state, state)), expected);
  }
  assert.equal(selection.watchRecordingProcessingStage({ ...record('deleted'), audioDeleted: true }), 'done');
  assert.equal(selection.watchRecordingProcessingStage({ ...record('silence', 'text'), analysis: { segments: [] } }), 'done');
});

test('watch auto-processing performs both stages serially, independently of general auto-summary, and continues after one failure', async () => {
  const { Page } = pageMethods(['processWatchRecordings']), page = new Page(), calls = [];
  Object.assign(page, { alive: true, queueEpoch: 1, autoSummary: false, showModels: false, recordTitle: value => value.title,
    analyze: async (restart, auto) => { calls.push(['transcribe', page.selected.id, auto]);
      if (page.selected.id === 'bad') { page.error = 'ASR failed'; return; }
      page.selected.analysis = { segments: [{ text: 'Transcript' }] }; page.selected.transcriptionComplete = true; },
    summarize: async () => { calls.push(['summary', page.selected.id]); page.selected.summary = { complete: true }; } });
  const failures = await page.processWatchRecordings([record('bad'), record('new'), record('text', 'text'), record('ready', 'done')], 1);
  assert.equal(failures.length, 1); assert.match(failures[0], /bad/);
  assert.deepEqual(calls, [['transcribe', 'bad', false], ['transcribe', 'new', false], ['summary', 'new'], ['summary', 'text']]);
  assert.equal(page.watchQueueRunning, false); assert.equal(page.queueRemaining, 0);
});

test('stopping a queue prevents subsequent summaries and recordings', async () => {
  const { Page } = pageMethods(['processWatchRecordings']), page = new Page(); let summaries = 0, transcriptions = 0;
  Object.assign(page, { alive: true, queueEpoch: 1, recordTitle: value => value.title,
    analyze: async () => { transcriptions++; page.queueEpoch++; page.watchQueueRunning = false; },
    summarize: async () => { summaries++; } });
  await page.processWatchRecordings([record('a'), record('b')], 1);
  assert.equal(transcriptions, 1); assert.equal(summaries, 0);
});

test('cancelling while playback is stopping cannot start a late transcription request', async () => {
  const { Page } = pageMethods(['analyze']), page = new Page(); let release, requests = 0;
  const stopped = new Promise(resolve => { release = resolve; });
  Object.assign(page, { busy: false, alive: true, epoch: 0, selected: record('pending'), autoSummary: false,
    store: { hasAudio: () => true }, models: { readyForTranscription: () => true }, useSystemAsr: () => false,
    playback: { stop: () => stopped }, analyzer: { async run() { requests++; throw Error('Late ASR request'); } } });
  const job = page.analyze(false, false); assert.equal(page.busy, true);
  page.epoch++; page.busy = false; release(); await job; assert.equal(requests, 0);
});

test('partial transfer removes completed selections, retains retry choices and still analyzes received audio', async () => {
  const { Page } = pageMethods(['syncWatchDevice']), page = new Page(); let processed = [];
  Object.assign(page, { busy: false, alive: true, watchQueueRunning: false, epoch: 0, queueEpoch: 0, store: {},
    watchDevice: { id: 'watch-device' }, watchSourceId: 'watch-source', watchItems: [item('a', '2026-11-13'), item('b', '2026-11-13')],
    watchSelectedIds: ['a', 'b'], watchAutoAnalyze: true, context: () => ({}), reload() {},
    watchSync: { async sync(context, deviceId, store, progress, saved, selected) {
      assert.deepEqual(clone(selected.recordingIds), ['a', 'b']);
      saved({ ...record('local-a'), watch: { recordingId: 'a' } }); throw Error('Connection interrupted');
    } }, processWatchRecordings: async records => { processed = records.map(value => value.id); return []; } });
  await page.syncWatchDevice();
  assert.deepEqual(clone(page.watchSelectedIds), ['b']); assert.equal(page.watchItems[0].localState, 'saved');
  assert.deepEqual(clone(processed), ['local-a']); assert.match(page.error, /1\/2/); assert.match(page.error, /interrupted/);
  assert.equal(page.busy, false); assert.equal(page.showWatch, false);
});

test('audio-only swipe action targets its own row without changing the open record or deleting text', async () => {
  const { Page, method } = pageMethods(['removeAudio']), page = new Page(), target = record('swiped', 'done'), opened = record('open', 'done');
  const before = JSON.stringify([target.analysis, target.summary]); let removed = '', reloaded = 0;
  Object.assign(page, { busy: false, alive: true, watchQueueRunning: false, epoch: 0, selected: opened,
    recordingListScroller: { closeAllSwipeActions() {} }, playback: { async stop() {} },
    store: { hasAudio: () => true, list: () => [target, opened], removeAudio: value => { removed = value.id; value.audioDeleted = true; } },
    reload: () => reloaded++, refreshSelected: () => { throw Error('Another row must not replace the open recording'); } });
  await page.removeAudio(target); assert.equal(removed, 'swiped'); assert.equal(page.selected.id, 'open'); assert.equal(reloaded, 1);
  assert.equal(JSON.stringify([target.analysis, target.summary]), before);
  assert(method('RecordActions').includes('this.removeAudio(record)')); assert(!method('Detail').includes("Button('设置')"));
  assert(method('PageHeader').includes("'更多'"));
});

(async () => { for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  console.log(cases.length + ' watch recording checks passed; no devices, downloads or model calls');
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
