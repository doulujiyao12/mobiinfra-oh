// Exercise production storage/page methods with local fixtures; no device, network or HAP build.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = path.join(root, 'entry/src/main/ets');
const fixture = fs.mkdtempSync(path.join(root, '.codex-log/task-page-fixture-'));
const calls = { reads: 0, writes: 0, syncLists: [] };
const stat = value => ({ size: value.size, mtime: value.mtimeMs / 1000,
  isDirectory: () => value.isDirectory(), isFile: () => value.isFile() });
const files = {
  OpenMode: { READ_ONLY: 0, CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY, TRUNC: fs.constants.O_TRUNC },
  accessSync: fs.existsSync, mkdirSync: (p, recursive = false) => fs.mkdirSync(p, { recursive }),
  listFileSync: p => { calls.syncLists.push(p); return fs.readdirSync(p); },
  statSync: p => stat(fs.statSync(p)),
  openSync(p, flags) { if (flags & fs.constants.O_TRUNC) calls.writes++; return { fd: fs.openSync(p, flags) }; },
  readSync(fd, bytes) { calls.reads++; return fs.readSync(fd, Buffer.from(bytes), 0, bytes.byteLength, null); },
  writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes)), closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
  unlinkSync: fs.unlinkSync, rmdirSync: fs.rmdirSync,
  access: async p => fs.existsSync(p), listFile: async p => fs.promises.readdir(p),
  lstat: async p => stat(await fs.promises.lstat(p))
};
const noop = () => {};
const mocks = {
  '@ohos.file.fs': { default: files }, '@kit.ArkTS': { util: {} }, '@ohos.resourceManager': {},
  './JsonCompat': { parseJsonCompat: JSON.parse, stringifyJsonCompat: JSON.stringify },
  './TextEncodingCompat': { encodeUtf8Compat: text => new Uint8Array(Buffer.from(text)),
    decodeUtf8Compat: bytes => Buffer.from(bytes).toString('utf8') },
  '../datamanager/DataManagerStorage': { DataManagerStorage: class {} },
  '../datamanager/MemoryChangeJournal': { MemoryChangeJournal: class { static beforeMutation() {} mark() {} } },
  './AppLogger': { AppLogger: { info: noop, warn: noop, warnCause: noop } }
};
const loaded = new Map();
function load(relative) {
  const file = path.join(base, relative.endsWith('.ets') ? relative : relative + '.ets');
  if (loaded.has(file)) return loaded.get(file);
  const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const exports = {}; loaded.set(file, exports);
  vm.runInNewContext(output, { exports, console, require: id => mocks[id] ||
    load(path.relative(base, path.resolve(path.dirname(file), id))) });
  return exports;
}
function probe(relative, name, methods, globals = {}) {
  const text = fs.readFileSync(path.join(base, relative), 'utf8').replace(new RegExp('\\bstruct ' + name + '\\b'), 'class ' + name);
  const tree = ts.createSourceFile('probe.ts', text, ts.ScriptTarget.Latest, true);
  const type = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === name);
  const bodies = methods.map(method => {
    const member = type.members.find(n => ts.isMethodDeclaration(n) && n.name.getText(tree) === method);
    assert.ok(member, method); return member.getText(tree);
  }).join('\n');
  const output = ts.transpileModule('exports.Probe = class { ' + bodies + ' };', {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const exports = {}; vm.runInNewContext(output, { exports, setTimeout, clearTimeout, Date, ...globals });
  return new exports.Probe();
}
const { WorkflowStorage: storage } = load('utils/WorkflowStorage');
const { WorkflowFileCatalog: Catalog } = load('utils/WorkflowFileCatalog');
const tests = [], test = (name, run) => tests.push([name, run]);
test('CRUD and unchanged context saves never enumerate historical files', () => {
  const workflow = { metadata: { name: 'fixture', description: '初始任务', source: 'fixture' },
    context: { contact_name: '测试联系人' }, steps: [{ id: 1, type: 'gui_action', action: 'sleep', seconds: 1 }] };
  let task = storage.createTaskFromJson(fixture, 4, JSON.stringify(workflow), 'task_fixture');
  storage.upsertTask(fixture, task);
  assert.ok(storage.loadTasks(fixture).some(t => t.id === task.id));
  workflow.metadata.description = '修改后的任务';
  task = storage.createTaskFromJson(fixture, 4, JSON.stringify(workflow), task.id);
  storage.upsertTask(fixture, task);
  assert.ok(storage.loadTasks(fixture).find(t => t.id === task.id).title.includes('修改后的任务'));
  storage.updateTaskContextValue(fixture, task.id, 'contact_name', '新的联系人');
  const before = calls.writes;
  storage.updateTaskContextValue(fixture, task.id, 'contact_name', '新的联系人');
  assert.equal(calls.writes, before, 'same context must not rewrite the config or task index');
  const copy = storage.duplicateTask(fixture, task.id);
  assert.notEqual(copy.id, task.id);
  assert.equal(JSON.parse(copy.workflowJson).context.contact_name, '新的联系人');
  storage.updateTaskEnabled(fixture, copy.id, false);
  assert.equal(storage.loadTasks(fixture).find(t => t.id === copy.id).enabled, false);
  storage.deleteTask(fixture, task.id);
  assert.ok(!storage.loadTasks(fixture).some(t => t.id === task.id));
  assert.ok(storage.loadTasks(fixture).some(t => t.id === copy.id));
  assert.ok(calls.syncLists.every(p => !/[\\/](runs|daily-log)([\\/]|$)/.test(p)));
});
test('task reload invalidates statistics without reading history', () => {
  const page = probe('pages/task/TaskPage.ets', 'TaskPage', ['reloadTasks', 'invalidateFileStats'], { WorkflowStorage: storage });
  Object.assign(page, { filesDir: fixture, fileStatsRevision: 0, cardContextDrafts: {},
    flushTaskContextDrafts: noop, refreshCardContextInputs: noop });
  const lists = calls.syncLists.length;
  page.reloadTasks(); page.reloadTasks();
  assert.ok(page.tasks.length > 0); assert.equal(page.fileStatsRevision, 2);
  assert.ok(calls.syncLists.slice(lists).every(p => !/[\\/](runs|daily-log)([\\/]|$)/.test(p)));
});
test('successful draft saves leave no pending draft for later run/navigation', () => {
  let writes = 0, invalidations = 0;
  const page = probe('pages/task/TaskPage.ets', 'TaskPage', ['persistTaskContextDraft', 'flushTaskContextDrafts',
    'removeTaskContextDraft', 'clearTaskContextSaveTimer', 'taskContextSaveTimerId', 'removeTaskContextSaveTimerId'], {
    WorkflowStorage: { updateTaskContextValue: () => { writes++; return []; } }, showToastSafely: noop
  });
  Object.assign(page, { filesDir: fixture, cardContextDrafts: { a: '联系人' }, cardContextSaveTimerIds: {},
    invalidateFileStats: () => invalidations++ });
  page.persistTaskContextDraft('a', '联系人');
  assert.equal(Object.keys(page.cardContextDrafts).length, 0);
  assert.equal(page.flushTaskContextDrafts(), false); assert.equal(writes, 1); assert.equal(invalidations, 1);
});
test('async catalog preserves file counts/order and reads metadata only', async () => {
  const dir = path.join(fixture, 'workflows');
  fs.mkdirSync(path.join(dir, 'runs/a'), { recursive: true }); fs.mkdirSync(path.join(dir, 'runs/b'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'daily-log/2026-11-10'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'runs/a/run_summary.json'), '{}');
  fs.writeFileSync(path.join(dir, 'runs/a/screenshot.jpg'), Buffer.alloc(4096));
  fs.writeFileSync(path.join(dir, 'runs/b/run_summary.json'), '{}');
  fs.utimesSync(path.join(dir, 'runs/b/run_summary.json'), new Date('2026-11-10'), new Date('2026-11-10'));
  fs.utimesSync(path.join(dir, 'runs/a/run_summary.json'), new Date('2026-11-09'), new Date('2026-11-09'));
  fs.writeFileSync(path.join(dir, 'daily-log/2026-11-10/source.md'), 'summary');
  const reads = calls.reads, syncLists = calls.syncLists.length;
  const catalog = new Catalog(); const stats = await catalog.statistics(fixture);
  const runs = await catalog.list(fixture, 'run');
  assert.equal(stats.runCount, 2); assert.equal(stats.runBytes, 4); assert.equal(stats.dailyLogCount, 1);
  assert.ok(stats.totalBytes >= 4107); assert.equal(runs.length, 2); assert.equal(runs[0].name, 'b/run_summary.json');
  assert.equal(calls.reads, reads); assert.equal(calls.syncLists.length, syncLists);
  fs.unlinkSync(path.join(dir, 'runs/b/run_summary.json'));
  assert.equal((await new Catalog().statistics(fixture)).runCount, 1);
});
test('closed file management performs no scan and ignores superseded results', async () => {
  const pending = [];
  class DeferredCatalog { cancel() {} statistics() { return new Promise(resolve => pending.push(resolve)); } }
  const panel = probe('components/WorkflowFileManager.ets', 'WorkflowFileManager',
    ['cancelScan', 'onRevisionChanged', 'onBusyChanged', 'loadStats', 'toggleExpanded'], {
      WorkflowFileCatalog: DeferredCatalog, AppLogger: { warnCause: noop }
    });
  Object.assign(panel, { filesDir: fixture, catalog: null, expanded: false, loading: false, loaded: false, busy: false });
  panel.onRevisionChanged(); assert.equal(pending.length, 0);
  panel.toggleExpanded(); assert.equal(pending.length, 1);
  panel.onRevisionChanged(); assert.equal(pending.length, 2);
  pending[1]({ runCount: 2 }); await Promise.resolve(); await Promise.resolve();
  pending[0]({ runCount: 999 }); await Promise.resolve(); await Promise.resolve();
  assert.equal(panel.stats.runCount, 2); assert.equal(panel.loading, false);
  panel.toggleExpanded(); assert.equal(panel.catalog, null);
});
test('cancelled catalog cannot publish an old snapshot', async () => {
  const catalog = new Catalog(); catalog.cancel();
  await assert.rejects(catalog.statistics(fixture), /WORKFLOW_CATALOG_CANCELLED/);
});
test('preparing state is immediate, locks duplicate taps and passes prepared endpoint to phone runner', async () => {
  let release, executed = 0, settings;
  const gate = new Promise(resolve => { release = resolve; });
  const cancellation = load('utils/WorkflowCancellation').WorkflowCancellation;
  const page = probe('pages/task/TaskPage.ets', 'TaskPage', ['runTask', 'isTaskExecutionBusy', 'runSelectedWorkflow'], {
    WorkflowCancellation: cancellation, AiLoginGuard: { ensure: () => true },
    SelfHdcSetupGuard: { prepare: async () => { await gate; return settings = { ip: '192.0.2.1', port: '33117' }; } },
    WorkflowStorage: { loadTasks: () => [{ id: 'a', enabled: true }], updateTaskRun: () => [] },
    AppLogger: { info: noop, errorCause: noop }, showToastSafely: noop
  });
  Object.assign(page, { taskControlMode: 'phone', preparingTaskId: '', runningTaskId: '', batchRunning: false,
    batchPreparing: false, phoneControlBusy: false, agentExecutionBusy: false, filesDir: fixture,
    flushTaskContextDrafts: noop, invalidateFileStats: noop, getUIContext: () => ({}),
    findTask: () => ({ id: 'a', enabled: true }),
    onRunPhoneWorkflow: async (_task, _cancel, prepared) => { executed++; assert.equal(prepared, settings); }
  });
  const running = page.runTask({ id: 'a' }); assert.equal(page.preparingTaskId, 'a');
  await page.runTask({ id: 'a' }); assert.equal(executed, 0);
  release(); await running; assert.equal(executed, 1); assert.equal(page.isTaskExecutionBusy(), false);
});
test('returning from file management reloads tasks without a historical scan', () => {
  let reloads = 0, reminders = 0;
  const page = probe('pages/task/TaskPage.ets', 'TaskPage', ['onActiveChanged']);
  Object.assign(page, { active: true, filesDir: fixture, isTaskExecutionBusy: () => false,
    reloadTasks: () => reloads++, onCollectionReminderChanged: () => reminders++ });
  page.onActiveChanged(); assert.equal(reloads, 1); assert.equal(reminders, 1);
  page.isTaskExecutionBusy = () => true; page.onActiveChanged(); assert.equal(reloads, 1);
});
test('reminders use first generation time, including after reuse/restart, with stable legacy ordering', () => {
  const source = fs.readFileSync(path.join(base, 'datamanager/HomeRecommendationService.ets'), 'utf8');
  const tree = ts.createSourceFile('service.ts', source, ts.ScriptTarget.Latest, true);
  const sort = tree.statements.find(n => ts.isFunctionDeclaration(n) && n.name?.text === 'newestHomeRecommendations');
  const exports = {};
  vm.runInNewContext(ts.transpileModule(sort.getText(tree), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports });
  const items = [{ id: 'legacy-a' }, { id: 'old', created_at: '2026-11-01T08:00:00+08:00' },
    { id: 'new', created_at: '2026-11-10T08:00:00+08:00' }, { id: 'invalid', created_at: 'invalid' }, { id: 'legacy-b' }];
  const ordered = exports.newestHomeRecommendations(items);
  assert.deepEqual(Array.from(ordered, r => r.id), ['new', 'old', 'legacy-a', 'invalid', 'legacy-b']);
  assert.equal(items[0].id, 'legacy-a');
  assert.deepEqual(Array.from(exports.newestHomeRecommendations(JSON.parse(JSON.stringify(ordered))), r => r.id),
    Array.from(ordered, r => r.id));
  const home = probe('pages/home/HomePage.ets', 'HomePage', ['visibleRecommendations']);
  Object.assign(home, { nonCalendarRecommendations: () => ordered.slice(), profile: { calendarEnabled: true,
    mailReminder: { id: 'mail', completed: false } }, calendarOverview: () => ({ reminder: { id: 'calendar' } }), showAllRecommendations: false });
  assert.deepEqual(Array.from(home.visibleRecommendations(), r => r.id), ['calendar', 'mail', 'new', 'old', 'legacy-a', 'invalid', 'legacy-b']);
});
(async () => {
  try { for (const [name, run] of tests) { await run(); console.log('PASS ' + name); }
    console.log(tests.length + '/' + tests.length + ' task UI/storage checks passed');
  } catch (error) { console.error('Check failed:', error); throw error;
  } finally {
    const target = fs.realpathSync(fixture), parent = fs.realpathSync(path.join(root, '.codex-log'));
    assert.ok(target.startsWith(parent + path.sep + 'task-page-fixture-'));
    try { fs.rmSync(target, { recursive: true, force: true, maxRetries: 3, retryDelay: 20 }); }
    catch (error) { console.warn('Fixture cleanup deferred:', error.code); }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
