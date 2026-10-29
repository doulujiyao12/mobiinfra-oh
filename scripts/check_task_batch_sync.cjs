// Execute real TaskPage/Index orchestration with synthetic tasks and memory services.
// No HAP build, model requests, phone control, accounts or network access.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = 'entry/src/main/ets/';
const clone = value => JSON.parse(JSON.stringify(value));
function probe(file, name, methods, globals) {
  const source = fs.readFileSync(path.join(root, base, file), 'utf8').replace(new RegExp('\\bstruct ' + name + '\\b'), 'class ' + name);
  const tree = ts.createSourceFile(name + '.ts', source, ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === name);
  assert.ok(component, name);
  const bodies = methods.map(method => {
    const node = component.members.find(item => ts.isMethodDeclaration(item) && item.name.getText(tree) === method);
    assert.ok(node, method); return node.getText(tree);
  }).join('\n');
  const output = ts.transpileModule('exports.Probe=class Probe {' + bodies + '}', {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
  });
  const exports = {}; vm.runInNewContext(output.outputText, { exports, setTimeout, setInterval, clearInterval, ...globals });
  return new exports.Probe();
}
const cancelExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, base, 'utils/WorkflowCancellation.ets'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: cancelExports });
const { WorkflowCancellation } = cancelExports;
function batch(mode = 'phone', count = 3) {
  let saved = Array.from({ length: count }, (_, i) => ({ id: 'task-' + i, title: '任务' + i, enabled: true, lastStatus: '' }));
  const state = { events: [], toasts: [], syncs: 0, history: 0, login: true, accepted: true, ready: true, claimed: 0, storage: {} };
  const storage = {
    loadTasks: () => clone(saved),
    updateTaskRun(_dir, id, status, message) {
      saved = saved.map(item => item.id === id ? { ...item, lastStatus: status, lastMessage: message } : item);
      return clone(saved);
    }
  };
  const page = probe('pages/task/TaskPage.ets', 'TaskPage', [
    'runEnabledTasks', 'executeEnabledTasks', 'runSelectedWorkflow', 'isTaskCancelled', 'isWorkflowCancelledStatus',
    'isTaskExecutionBusy', 'batchRunButtonText', 'batchRunButtonEnabled', 'stopEnabledTasks'
  ], {
    WorkflowCancellation, WorkflowStorage: storage,
    AiLoginGuard: { ensure: () => state.login }, HuaweiPrivacyAccess: { ensure: async () => state.accepted },
    SelfHdcSetupGuard: { ensure: async () => state.ready },
    CollectionReminderService: { pendingIntent: () => ({}), claim: () => { state.claimed++; return true; }, clearRequest() {},
      recordSuccessfulCollection: async () => { state.history++; } },
    AppStorage: { setOrCreate: (key, value) => { state.storage[key] = value; } },
    SelfHdcTestRunner: { shared: () => ({ recordExternal() {} }) },
    AppLogger: { info() {}, warnCause() {}, errorCause() {} }, showToastSafely: text => state.toasts.push(text)
  });
  Object.assign(page, { filesDir: '/app', taskControlMode: mode, tasks: storage.loadTasks(), batchRunning: false,
    batchPreparing: false, batchSyncing: false, batchStopRequested: false, runningTaskId: '', active: true,
    reminderWindowReady: true, phoneControlBusy: false, agentExecutionBusy: false, batchCancellation: null,
    getUIContext: () => ({}), flushTaskContextDrafts: () => false, refreshCardContextInputs() {}, refreshStatsText() {},
    onEnsureDesktopCompanion: async () => true,
    enabledTasks: () => page.tasks.filter(item => item.enabled), enabledTaskCount: () => page.tasks.filter(item => item.enabled).length,
    findTask: id => page.tasks.find(item => item.id === id) || null,
    onSyncCollectedTasks: async () => { state.syncs++; state.events.push('sync'); }
  });
  const run = async task => {
    state.events.push('run:' + task.id);
    await Promise.resolve(); // Represents deferred summaries already flushed by WorkflowRunner.
    storage.updateTaskRun('/app', task.id, 'success', 'saved'); state.events.push('saved:' + task.id);
  };
  page.onRunPhoneWorkflow = run; page.onRunWorkflow = run;
  return { page, state, storage, saved: () => clone(saved) };
}
function index() {
  const state = { accepted: true, login: true, memory: 0, calendar: 0, mail: 0, marks: [], failure: false, hasData: true,
    checked: 0, calendarFailure: false };
  const page = probe('pages/Index.ets', 'Index', ['syncCollectedWorkflowTasks', 'refreshDataManager', 'updateDataManagerProgress',
    'beginMemoryOperation','endMemoryOperation','startMemoryProgressTimer','stopMemoryProgressTimer'], {
    PrivacyConsent: { isAccepted: () => state.accepted },
    CalendarMemoryStore: class { settings() { return { enabled: true }; } snapshot() { return { error: '', syncedAt: '' }; } },
    MailStore: class { settings() { return { enabled: true }; } },
    CalendarMemoryService: { refresh: async () => { state.calendar++; if (state.calendarFailure) throw Error('fixture calendar failure'); } },
    MailService: { refresh: async () => { state.mail++; } },
    StartupSourceSync: class { markSynced(key) { state.marks.push(key); } markAttempted() {} markFailed() {} },
    SyncMetrics: class { mark() {} finish() {} }, dataManagerInfo() {}, dataManagerWarn() {}, dataManagerError() {},
    getContext: () => ({}), showToastSafely() {}
  });
  Object.assign(page, { filesDir: '/app', dataManagerRefreshing: false, dataManagerSyncFailed: false,
    ensurePrivacyConsent: async () => state.accepted, ensureAiServiceLogin: () => state.login,
    appendCloudLog() {}, reloadDataManagerViewModels() {}, maybeShowCalendarConsent() {},
    getDataManagerModelConfig: () => ({ enabled: true, baseUrl: 'https://model.invalid', model: 'fixture' }),
    dataManagerFacade: { hasDataToSync: () => state.hasData, recordSuccessfulMemoryCheck: () => { state.checked++; }, refresh: async (_config, progress) => {
      state.memory++; if (state.failure) throw Error('fixture model unavailable');
      progress({ stage: '生成画像', message: 'fixture progress', percent: 80, current: 4, total: 5 });
      return { message: 'fixture completed', skipped: false };
    } }
  });
  return { page, state };
}
const tests = [], test = (name, run) => tests.push([name, run]);
test('phone and PC batches sync once after every task has saved its summaries', async () => {
  for (const mode of ['phone', 'pc']) {
    const { page, state, saved } = batch(mode);
    await page.runEnabledTasks();
    assert.deepEqual(state.events, ['run:task-0', 'saved:task-0', 'run:task-1', 'saved:task-1', 'run:task-2', 'saved:task-2', 'sync']);
    assert.equal(state.syncs, 1); assert.equal(state.history, 3); assert.ok(saved().every(item => item.lastStatus === 'success'));
    assert.equal(page.batchRunning, false); assert.equal(page.batchPreparing, false);
  }
});
test('reminder-launched batches use the same one-time follow-up sync', async () => {
  const { page, state } = batch(); await page.runEnabledTasks('fixture-reminder', true);
  assert.equal(state.claimed, 1); assert.equal(state.syncs, 1); assert.equal(state.storage.collectionReminderActiveBatch, false);
});
test('sync keeps the batch locked and exposes a clear disabled syncing button', async () => {
  const { page, state } = batch(); let release, started;
  const gate = new Promise(resolve => { release = resolve; }), ready = new Promise(resolve => { started = resolve; });
  page.onSyncCollectedTasks = async () => { state.syncs++; started(); await gate; };
  const running = page.runEnabledTasks(); await ready;
  assert.equal(page.batchRunButtonText(), '正在同步分析…'); assert.equal(page.batchRunButtonEnabled(), false);
  assert.equal(page.isTaskExecutionBusy(), true);
  await page.runEnabledTasks(); assert.equal(state.syncs, 1);
  page.stopEnabledTasks(); assert.equal(page.batchCancellation.isCancelled(), false);
  release(); await running; assert.equal(page.batchSyncing, false); assert.equal(page.batchRunButtonEnabled(), true);
});
test('stopping collection drops the remaining queue and does not launch new analysis', async () => {
  const { page, state, storage } = batch();
  page.onRunPhoneWorkflow = async (task, cancellation) => {
    state.events.push(task.id); page.stopEnabledTasks(); assert.equal(cancellation.isCancelled(), true);
    storage.updateTaskRun('/app', task.id, 'cancelled', '用户取消');
  };
  await page.runEnabledTasks(); assert.deepEqual(state.events, ['task-0']); assert.equal(state.syncs, 0);
  assert.equal(page.batchCancellation, null); assert.equal(page.batchStopRequested, false);
});
test('failed phone or PC tasks stop dispatch but still sync already collected results', async () => {
  for (const mode of ['phone', 'pc']) {
    const { page, state, storage, saved } = batch(mode), normal = page.onRunWorkflow;
    const run = async task => {
      if (task.id === 'task-1') { storage.updateTaskRun('/app', task.id, 'failed', 'fixture task failed'); }
      else { await normal(task); }
    };
    page.onRunWorkflow = run; page.onRunPhoneWorkflow = run;
    await page.runEnabledTasks(); assert.equal(state.syncs, 1);
    assert.equal(saved()[1].lastStatus, 'failed'); assert.equal(saved()[2].lastStatus, '');
    assert.ok(state.toasts.some(text => text.includes('部分任务未完成')));
  }
});
test('analysis failure preserves successful task status, unlocks the batch and allows another run', async () => {
  const { page, state, saved } = batch('phone', 1);
  page.onSyncCollectedTasks = async () => { throw Error('fixture sync failed'); };
  await page.runEnabledTasks(); assert.equal(saved()[0].lastStatus, 'success');
  assert.ok(state.toasts.some(text => text.includes('采集结果已保留'))); assert.equal(page.batchRunning, false);
  page.onSyncCollectedTasks = async () => { state.syncs++; };
  await page.runEnabledTasks(); assert.equal(state.syncs, 1);
});
test('empty queues, missing HDC configuration and lost login never start sync', async () => {
  const fixtures = [batch('phone', 0), batch(), batch()]; fixtures[1].state.ready = false; fixtures[2].state.login = false;
  for (const { page, state } of fixtures) {
    await page.runEnabledTasks(); assert.equal(state.syncs, 0); assert.equal(state.events.length, 0); assert.equal(page.batchPreparing, false);
  }
});
test('an explicitly started batch does not consult an app-wide privacy status',async()=>{
  const {page,state}=batch();state.accepted=false;await page.runEnabledTasks();assert.equal(state.syncs,1);
  assert.ok(state.events.includes('run:task-0'));assert.equal(page.batchRunning,false);
});
test('post-task sync reuses the full memory pipeline and progress without rereading mail/calendar', async () => {
  const { page, state } = index(); await page.syncCollectedWorkflowTasks();
  assert.equal(state.memory, 1); assert.equal(state.calendar, 0); assert.equal(state.mail, 0);
  assert.deepEqual(state.marks, ['chat']); assert.equal(page.dataManagerProgressPercent, 100); assert.equal(page.dataManagerRefreshing, false);
  await page.refreshDataManager(); assert.equal(state.memory, 2); assert.equal(state.calendar, 1); assert.equal(state.mail, 1);
});
test('a sync already in progress is awaited and followed by a fresh snapshot of collected files', async () => {
  const { page, state } = index(); page.dataManagerRefreshing = true;
  const waiting = page.syncCollectedWorkflowTasks(); await Promise.resolve(); assert.equal(state.memory, 0);
  page.dataManagerRefreshing = false; await waiting; assert.equal(state.memory, 1);
  // Two callers each need a fresh snapshot; the second waits for the first lock.
  await Promise.all([page.syncCollectedWorkflowTasks(),page.syncCollectedWorkflowTasks()]);assert.equal(state.memory,3);
});
test('sync keeps model/login failure handling without depending on a duplicate privacy status', async () => {
  const failed = index(); failed.state.failure = true;
  await assert.rejects(failed.page.syncCollectedWorkflowTasks(), /fixture model unavailable/);
  assert.equal(failed.page.dataManagerSyncFailed, true); assert.equal(failed.page.dataManagerRefreshing, false);
  const denied = index(); denied.state.accepted = false;
  await denied.page.syncCollectedWorkflowTasks(); assert.equal(denied.state.memory, 1); assert.equal(denied.state.accepted, false);
  const loggedOut = index(); loggedOut.state.login = false;
  await assert.rejects(loggedOut.page.syncCollectedWorkflowTasks(), /登录/); assert.equal(loggedOut.state.memory, 0);
  const empty = index(); empty.state.hasData = false;
  await empty.page.syncCollectedWorkflowTasks(); assert.equal(empty.state.memory, 0); assert.equal(empty.page.dataManagerProgressPercent, 100);
  assert.equal(empty.state.checked,1,'a successful no-change sync still records completion');
  const partial=index();partial.state.hasData=false;partial.state.calendarFailure=true;
  assert.equal(await partial.page.refreshDataManager(),false);assert.equal(partial.state.checked,0,'an incomplete source check must not count as a complete memory check');
});
(async () => {
  for (const [name, run] of tests) { await run(); console.log('PASS ' + name); }
  console.log(tests.length + '/' + tests.length + ' task batch sync checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
