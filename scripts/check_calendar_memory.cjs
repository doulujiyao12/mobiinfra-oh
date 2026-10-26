// Tests execute production ArkTS business logic with a fake CalendarKit provider.
// No device data, notifications, network, HAP build, or installation is involved.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
process.env.TZ = 'Asia/Shanghai';
const root = path.resolve(__dirname, '..');
const cache = new Map(), disk = new Map();
const clone = v => JSON.parse(JSON.stringify(v));
const now = new Date('2026-10-23T12:00:00+08:00').getTime();
let clockNow = now;
class Clock extends Date {
  constructor(...args) { super(...(args.length ? args : [clockNow])); }
  static now() { return clockNow; }
}
class Storage {
  join(...items) { return items.join('/'); }
  readJson(file, fallback) { return clone(disk.has(file) ? disk.get(file) : fallback); }
  writeJsonAtomic(file, value) { disk.set(file, clone(value)); }
  sha256Text(text) { return crypto.createHash('sha256').update(text).digest('hex'); }
  exists(file) { return disk.has(file); }
  listDir(dir) { return [...disk.keys()].filter(p => p.startsWith(dir + '/')).map(p => p.slice(dir.length + 1)).filter(p => !p.includes('/')); }
}
let granted = true, calendars = [], failRead = false, mutateSettings = null, reads = 0;
let accessRequests = 0, fetchedFields = [], providerDefinitions = [], providerInstances = [];
const kit = { calendarManager: {
  getCalendarManager: () => ({ getAllCalendars: async () => calendars }),
  EventFilter: { filterById: ids => ids }
} };
const external = {
  '@kit.ArkTS': { JSON },
  '@kit.AbilityKit': { abilityAccessCtrl: {
    GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      checkAccessToken: async () => granted ? 0 : -1,
      requestPermissionsFromUser: async () => { accessRequests++; return { authResults: [granted ? 0 : -1] }; }
    })
  } },
  '@kit.CalendarKit': kit
};
const mocks = {
  'DataManagerStorage.ets': { DataManagerStorage: Storage },
  'DataManagerLog.ets': { dataManagerInfo() {}, dataManagerWarn() {} },
  'GalleryMemorySync.ets': { GalleryMemorySync: {} },
  'DataPipelineModelClient.ets': { DataPipelineModelClient: class {} }
};
function load(relative) {
  const file = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
  const name = path.basename(file);
  if (mocks[name]) return mocks[name];
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} }; cache.set(file, module);
  const source = fs.readFileSync(file, 'utf8');
  const result = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } });
  const errors = (result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, name + ': ' + errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const requireMock = request => {
    if (external[request]) return external[request];
    if (!request.startsWith('.')) throw Error('Unexpected dependency: ' + request);
    return load(path.resolve(path.dirname(file), request));
  };
  vm.runInNewContext(result.outputText, { require: requireMock, module, exports: module.exports, Date: Clock,
    setTimeout, clearTimeout, console }, { filename: file });
  return module.exports;
}
const base = 'entry/src/main/ets/';
const policy = load(base + 'utils/calendar/CalendarMemoryPolicy');
const { CalendarMemoryStore } = load(base + 'utils/calendar/CalendarMemoryStore');
const { CalendarMemoryService } = load(base + 'utils/calendar/CalendarMemoryService');
const { IndexService } = load(base + 'datamanager/IndexService');
const ctx = { filesDir: '/app', applicationInfo: { accessTokenId: 7 } };
const store = new CalendarMemoryStore(ctx.filesDir);
function definition(id, extra = {}) {
  return { id, title: '学术会议' + id, startTime: now - 86400000 * 1000, endTime: now - 86400000 * 1000 + 3600000,
    timeZone: 'Asia/Shanghai', description: '讨论端侧模型研究', ...extra };
}
function instance(def, offset, duration = 3600000) {
  return { ...def, instanceStartTime: now + offset, instanceEndTime: now + offset + duration };
}
function provider(id = 1, type = 'local') {
  return { id, getAccount: () => ({ displayName: '我的日历', name: 'private@example.com', type }),
    async queryEventInstances(start, end, ids, fields) {
      reads++; fetchedFields = fields;
      if (failRead) throw Error('provider unavailable');
      if (mutateSettings) { const run = mutateSettings; mutateSettings = null; run(); }
      return clone(providerInstances.filter(i => i.instanceStartTime < end && i.instanceEndTime > start));
    },
    async getEvents(ids, fields) { fetchedFields = fields; return clone(providerDefinitions.filter(d => ids.includes(d.id))); }
  };
}
const cases = [];
function test(name, fn) { cases.push([name, fn]); }
test('disabled by default and no implicit permission requests', async () => {
  assert.equal(store.settings().enabled, false);
  await CalendarMemoryService.refresh(ctx);
  assert.equal(reads, 0); assert.equal(accessRequests, 0);
});
test('startup consent: later, permanent suppression, manual enable and explicit disable persist', () => {
  const preference = new CalendarMemoryStore('/onboarding');
  assert.equal(preference.shouldOfferConsent(), true);
  preference.saveConsentChoice({ configured: false, skipReminder: false });
  assert.equal(new CalendarMemoryStore('/onboarding').shouldOfferConsent(), true, 'Later can remind next launch');
  preference.saveConsentChoice({ configured: false, skipReminder: true });
  assert.equal(new CalendarMemoryStore('/onboarding').shouldOfferConsent(), false);
  const s = preference.settings(); s.enabled = true; preference.saveSettings(s); preference.markConfigured();
  assert.equal(preference.shouldOfferConsent(), false);
  s.enabled = false; preference.saveSettings(s);
  assert.equal(new CalendarMemoryStore('/onboarding').shouldOfferConsent(), false, 'Explicitly configured users are not nagged');
  assert.equal(accessRequests, 0, 'The guide eligibility check never requests a system permission');
});
test('bounded recurring-instance reads include a series that started years ago', async () => {
  const settings = store.settings(); settings.enabled = true; store.saveSettings(settings);
  const d = definition(1, { recurrenceRule: { recurrenceFrequency: 1 }, reminderTime: [15] });
  providerDefinitions = [d];
  providerInstances = [instance(d, -86400000), instance(d, 86400000), instance(d, 8 * 86400000)];
  calendars = [provider()];
  const result = await CalendarMemoryService.refresh(ctx);
  assert.equal(result.series.length, 1); assert.equal(result.occurrences.length, 3);
  assert.ok(result.series[0].recurrence.includes('recurrenceFrequency'));
  assert.ok(fetchedFields.includes('recurrenceRule') && fetchedFields.includes('instanceEndTime'));
  assert.ok(!JSON.stringify(result).includes('private@example.com'));
  assert.equal(store.reminders(now).length, 1);
});
test('elapsed time preserves cached profile identity; manual index fingerprint tracks newly elapsed plans', () => {
  const before = store.fingerprint(), indexBefore = store.indexFingerprint(), readCount = reads;
  try {
    clockNow = now + 2 * 86400000;
    assert.equal(store.fingerprint(), before);
    assert.notEqual(store.indexFingerprint(), indexBefore);
    const storage = new Storage(), paths = { filesDir: '/app', indexesRoot: '/cached-index' };
    disk.set('/cached-index/profile/state.json', { calendar_input_hash: before, claim_count: 1,
      domains: { work: { summary: '已保存的画像', claims: [{ event_ids: [store.events()[0].event_id] }] } } });
    const cached = new IndexService(paths, storage, {}).loadProfileState();
    assert.equal(cached.domains.work.summary, '已保存的画像');
    assert.equal(cached.claim_count, 1);
    assert.equal(reads, readCount, 'Cached display does not contact CalendarKit');
  } finally { clockNow = now; }
});
test('7-day boundary, in-progress events, ended and all-day events', () => {
  const snapshot = store.snapshot(), d = snapshot.series[0];
  snapshot.occurrences = [-3600000, 0, 6 * 86400000, 7 * 86400000].map((offset, i) =>
    ({ key: 'a' + i, seriesKey: d.key, start: now + offset, end: now + offset + 7200000 }));
  snapshot.occurrences.push({ key: 'ended', seriesKey: d.key, start: now - 8000000, end: now });
  assert.equal(policy.calendarReminders(snapshot, store.settings(), now).length, 3);
  snapshot.series[0].allDay = true;
  assert.ok(policy.calendarReminders(snapshot, store.settings(), now)[0].desc.includes('全天'));
});
test('calendar agenda: tomorrow uses local day boundaries; week excludes ended and out-of-range events', () => {
  const template = clone(store.reminders(now)[0]);
  function event(id, start, end, extra = {}) {
    return { ...template, id: 'calendar:' + id, calendarStart: new Date(start).getTime(),
      calendarEnd: new Date(end).getTime(), completed: false, ...extra };
  }
  const items = [
    event('today', '2026-10-23T18:00:00+08:00', '2026-10-23T19:00:00+08:00'),
    event('night', '2026-10-23T23:00:00+08:00', '2026-10-24T01:00:00+08:00'),
    event('tomorrow', '2026-10-24T08:00:00+08:00', '2026-10-24T09:00:00+08:00'),
    event('done', '2026-10-24T10:00:00+08:00', '2026-10-24T11:00:00+08:00', { completed: true }),
    event('nextday', '2026-10-25T00:00:00+08:00', '2026-10-25T01:00:00+08:00'),
    event('late', '2026-10-30T12:00:00+08:00', '2026-10-30T13:00:00+08:00'),
    event('past', '2026-10-23T10:00:00+08:00', '2026-10-23T11:00:00+08:00'),
    { ...template, id: 'non-calendar' }
  ];
  const tomorrow = policy.calendarAgenda(items, now, true, false);
  assert.equal(tomorrow.tomorrowCount, 2); assert.equal(tomorrow.weekCount, 4);
  assert.equal(tomorrow.groups.length, 1); assert.equal(tomorrow.groups[0].label, '明天 · 周六');
  assert.equal(policy.calendarAgendaTime(items[1], tomorrow.groups[0].date, now), '跨天');
  const week = policy.calendarAgenda(items, now, false, false);
  assert.equal(week.groups.length, 3); assert.equal(week.groups[0].label, '今天 · 周五');
  assert.equal(policy.calendarAgenda(items, now, true, true).tomorrowCount, 3);
  assert.equal(policy.calendarAgenda([], now, true, false).weekCount, 0);
});
test('large agenda lists retain all entries for scrolling with accurate counts', () => {
  const template = clone(store.reminders(now)[0]);
  const items = Array.from({ length: 120 }, (_, i) => ({ ...template, id: 'calendar:many-' + i,
    calendarStart: now + 86400000 + i * 60000, calendarEnd: now + 86400000 + i * 60000 + 3600000 }));
  const result = policy.calendarAgenda(items, now, true, false);
  assert.equal(result.tomorrowCount, 120);
  assert.equal(result.groups.reduce((sum, group) => sum + group.items.length, 0), 120);
  const overview = policy.calendarReminderOverview(items, now, false, '');
  assert.equal(overview.reminder.title, '明天有120项提醒');
  assert.ok(overview.reminder.desc.includes('120项'));
  assert.equal(overview.preview.length, 8, 'Only thumbnail animation is capped; the week list is complete');
  assert.equal(overview.reminder.id, policy.CALENDAR_REMINDER_OVERVIEW_ID);
});
test('one overview handles empty tomorrow, completed filters and read errors without individual homepage rows', () => {
  const template = clone(store.reminders(now)[0]);
  const items = [{ ...template, completed: false, calendarStart: now + 3 * 86400000, calendarEnd: now + 3 * 86400000 + 3600000 }];
  assert.equal(policy.calendarReminderOverview(items, now, false, '').reminder.title, '未来7天有1项提醒');
  items[0].completed = true;
  assert.equal(policy.calendarReminderOverview(items, now, false, '').preview.length, 0);
  assert.equal(policy.calendarReminderOverview(items, now, true, '').preview.length, 1);
  const error = policy.calendarReminderOverview(items, now, true, 'provider unavailable');
  assert.equal(error.reminder.title, '日历暂未更新'); assert.equal(error.preview.length, 0);
  assert.equal(policy.calendarReminderOverview([], now, false, '').reminder.title, '明天暂无日历提醒');
});
test('startup lifecycle delegates to the guarded coordinator instead of directly starting a full sync', () => {
  const file = path.join(root, base, 'pages/Index.ets');
  const source = fs.readFileSync(file, 'utf8').replace(/\bstruct Index\b/, 'class Index');
  const tree = ts.createSourceFile(file.replace(/\.ets$/, '.ts'), source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declaration = tree.statements.find(s => ts.isClassDeclaration(s) && s.name?.text === 'Index');
  assert.ok(declaration, 'Root component declaration is available for lifecycle inspection');
  for (const name of ['onPageShow', 'initializePrivacyConsent']) {
    const method = declaration.members.find(m => ts.isMethodDeclaration(m) && m.name.getText(tree) === name);
    assert.ok(method?.body);
    const body = method.body.getText(tree);
    assert.ok(!/refreshDataManager\s*\(|CalendarMemoryService\.refresh\s*\(|refreshCalendarOnForeground/.test(body), name);
  }
  assert.ok(!source.includes('refreshCalendarOnForeground'));
  const coordinator=declaration.members.find(m=>ts.isMethodDeclaration(m)&&m.name.getText(tree)==='syncDailyStartupSources');
  assert.ok(coordinator.body.getText(tree).includes('scheduler.hasDue(selection)'));
  assert.ok(coordinator.body.getText(tree).includes('refreshAutomaticSources'));
  assert.ok(!coordinator.body.getText(tree).includes('refreshDataManager('));
});

test('a denied calendar permission request is remembered, with manual authorization still available', async () => {
  const context={filesDir:'/denied-startup',applicationInfo:{accessTokenId:1}},store=new CalendarMemoryStore('/denied-startup');
  assert.equal(store.shouldOfferConsent(),true);granted=false;
  try {await assert.rejects(CalendarMemoryService.requestAccess(context),/未获得/);assert.equal(store.shouldOfferConsent(),false);}
  finally {granted=true;}
  await CalendarMemoryService.requestAccess(context);assert.equal(store.shouldOfferConsent(),false);
});
test('repeat exceptions preserve edited content and query-window overlap does not duplicate', async () => {
  const old = clone(providerInstances);
  const def = providerDefinitions[0];
  providerInstances.push({ ...instance(def, -6 * 86400000, 3 * 86400000), title: '临时改为线上交流',
    description: '该次会议已改期', location: { location: '线上' } });
  await CalendarMemoryService.refresh(ctx);
  assert.equal(store.snapshot().occurrences.length, 4);
  const exception = store.events().find(e => e.summary.includes('临时改为线上交流'));
  assert.ok(exception && exception.summary.includes('线上'));
  providerInstances = old;
  await CalendarMemoryService.refresh(ctx);
});
test('repeat instances are one profile evidence; future schedules are not past behavior', () => {
  const events = store.events();
  assert.ok(events.every(e => e.summary.includes('未确认实际参加或完成')));
  const profiled = policy.calendarProfileEvents(events, now);
  assert.equal(profiled.length, 1); assert.ok(profiled[0].calendar.end <= now);
  assert.equal(events.filter(e => e.calendar.start > now).length, 2);
  const off = store.settings(); off.profileEnabled = false;
  assert.equal(policy.calendarProfileEvents(policy.calendarIndexedEvents(store.snapshot(), off), now).length, 0);
});
test('completion survives rereads, is local, and does not affect other occurrences', async () => {
  const reminder = store.reminders(now)[0];
  assert.equal(store.setCompleted(reminder.id, true), true);
  await CalendarMemoryService.refresh(ctx);
  assert.equal(store.reminders(now)[0].completed, true);
  assert.equal(store.events().length, 3);
});
test('rescheduling and deletion replace old occurrences without duplicate reminders', async () => {
  const d = providerDefinitions[0];
  providerInstances = [instance(d, 2 * 86400000)];
  await CalendarMemoryService.refresh(ctx);
  assert.equal(store.snapshot().occurrences.length, 1);
  assert.equal(store.reminders(now)[0].completed, false);
  providerInstances = [];
  await CalendarMemoryService.refresh(ctx);
  assert.equal(store.events().length, 0); assert.equal(store.reminders(now).length, 0);
});
test('excluded calendars and subscriptions are not read', async () => {
  reads = 0; calendars = [provider(9, 'subscribed'), provider(2)];
  const s = store.settings(); s.excludedCalendarIds = [2]; store.saveSettings(s);
  await CalendarMemoryService.refresh(ctx);
  assert.equal(reads, 0); assert.equal(store.snapshot().sources.length, 2);
});
test('permission denial preserves raw records but suppresses use; no foreground authorization popup', async () => {
  const requestsBefore = accessRequests;
  calendars = [provider()];
  const d = definition(2); providerDefinitions = [d]; providerInstances = [instance(d, 86400000)];
  await CalendarMemoryService.refresh(ctx);
  granted = false;
  await assert.rejects(CalendarMemoryService.refresh(ctx), /权限/);
  assert.equal(store.snapshot().occurrences.length, 1); assert.equal(store.events().length, 0);
  assert.equal(store.reminders(now).length, 0); assert.equal(accessRequests, requestsBefore);
  granted = true;
});
test('provider failure never replaces valid data with a partial snapshot', async () => {
  await CalendarMemoryService.refresh(ctx);
  const old = JSON.stringify(store.snapshot().occurrences);
  failRead = true;
  await assert.rejects(CalendarMemoryService.refresh(ctx), /provider/);
  assert.equal(JSON.stringify(store.snapshot().occurrences), old);
  failRead = false; await CalendarMemoryService.refresh(ctx);
});
test('concurrent refreshes share one provider read and config changes cannot revive cleared data', async () => {
  reads = 0;
  await Promise.all([CalendarMemoryService.refresh(ctx), CalendarMemoryService.refresh(ctx)]);
  assert.ok(reads < 15);
  mutateSettings = () => store.clear();
  await assert.rejects(CalendarMemoryService.refresh(ctx), /配置已变化/);
  assert.equal(store.settings().enabled, false); assert.equal(store.snapshot().occurrences.length, 0);
});
test('invalid recurring instance timestamps fail safely', async () => {
  const s = store.settings(); s.enabled = true; store.saveSettings(s);
  const d = definition(3, { recurrenceRule: { recurrenceFrequency: 1 } });
  providerDefinitions = [d]; providerInstances = [instance(d, 86400000)];
  const source = provider();
  source.queryEventInstances = async () => [clone(d)];
  calendars = [source];
  await assert.rejects(CalendarMemoryService.refresh(ctx), /实例时间/);
  calendars = [provider()];
});
test('production index enrichment cannot fabricate completion, dates, or GUI actions', async () => {
  const a = definition(4), b = definition(5);
  providerDefinitions = [a, b];
  providerInstances = [instance(a, -2 * 86400000), instance(a, -86400000), instance(b, -86400000), instance(a, 86400000)];
  await CalendarMemoryService.refresh(ctx);
  const storage = new Storage(), paths = { filesDir: '/app', indexesRoot: '/indexes', consolidationRoot: '/consolidation' };
  let classified = 0;
  const model = { async enrichEvents(events) { classified += events.length; return events.map(e => ({ ...e, event_date: '1900-01-01',
    summary: '用户已经完成所有会议', domains: ['work'], enrichment_method: 'model',
    todo: { deadline: '1900-01-01', text: 'buy', type: 'buy', agent_task: 'pay' } })); } };
  const service = new IndexService(paths, storage, model), events = {};
  await service.buildCalendarEvents(events, {}, { enabled: true });
  assert.equal(Object.keys(events).length, 4);
  assert.equal(classified, 2, 'Only one classification per repeat definition');
  assert.ok(Object.values(events).every(e => e.calendar && e.summary.includes('未确认实际参加或完成') && !e.todo.agent_task && e.event_date !== '1900-01-01'));
  assert.ok(service.copyEvent(Object.values(events)[0]).calendar);
  let profileInputs = [];
  model.profileCacheIdentity = () => 'calendar-test';
  model.summarizeProfileBlock = async (domain, entries) => {
    profileInputs = entries;
    return { claims: [], summary: '', short_summary: '', generation: 'model_block' };
  };
  model.combineProfileBlocks = async () => ({ claims: [], summary: '', short_summary: '', generation: 'model_empty' });
  const profile = await service.buildProfileDocument(events, { enabled: true }, false);
  assert.equal(profileInputs.length, 2); assert.equal(profile.calendar_input_hash, store.fingerprint());
  const ids = profileInputs.map(e => e.event_id);
  const habit = { statement: '经常进行端侧模型研究', kind: 'habit', confidence: 'high', event_ids: ids };
  assert.equal(service.normalizeProfileClaims([habit], profileInputs, 'work').length, 0);
  const topic = { ...habit, statement: '近期安排聚焦端侧模型研究', kind: 'topic' };
  assert.equal(service.normalizeProfileClaims([topic], profileInputs, 'work')[0].confidence, 'medium');
  const first = Object.values(events)[0];
  assert.equal(Object.keys(service.filterCurrentCalendarEvents({ [first.event_id]: first })).length, 1);
  disk.set('/indexes/profile/state.json', { ...profile, domains: { work: { claims: [{ statement: 'stale', event_ids: [first.event_id] }],
    summary: 'stale summary', short_summary: '陈旧画像', input_hash: 'old' } }, claim_count: 1 });
  store.clear();
  assert.equal(Object.keys(service.filterCurrentCalendarEvents({ [first.event_id]: first })).length, 0);
  const clean = service.loadProfileState();
  assert.equal(clean.claim_count, 0); assert.equal(clean.domains.work.summary, '');
});
test('automatic calendar checks skip unavailable access without a provider read or permission popup',async()=>{
  const localContext={filesDir:'/auto-skip',applicationInfo:{accessTokenId:1}},local=new CalendarMemoryStore('/auto-skip');
  const beforeReads=reads,beforeRequests=accessRequests;assert.equal(await CalendarMemoryService.canAutoRefresh(localContext),false);
  const settings=local.settings();settings.enabled=true;local.saveSettings(settings);
  const snapshot=policy.emptyCalendarSnapshot();snapshot.available=true;
  snapshot.occurrences=[{key:'preserved',seriesKey:'preserved',start:now,end:now+1000}];local.save(snapshot);granted=false;
  try {
    assert.equal(await CalendarMemoryService.canAutoRefresh(localContext),false);
    assert.equal(local.snapshot().available,false);assert.equal(local.snapshot().occurrences.length,1);
    assert.equal(reads,beforeReads);assert.equal(accessRequests,beforeRequests);
  } finally {granted=true;}
  assert.equal(await CalendarMemoryService.canAutoRefresh(localContext),true);
  assert.equal(reads,beforeReads);assert.equal(accessRequests,beforeRequests);
});
test('calendar progress reports provider chunks, definition counts and durable snapshot completion',async()=>{
  calendars=[provider()];failRead=false;granted=true;const settings=store.settings();settings.enabled=true;settings.excludedCalendarIds=[];store.saveSettings(settings);
  const value=definition(90);providerDefinitions=[value];providerInstances=[instance(value,86400000)];
  const steps=[];await CalendarMemoryService.refresh(ctx,progress=>steps.push(clone(progress)));
  assert.ok(steps.some(step=>step.stage==='读取日历日程'&&step.total>0));
  assert.ok(steps.some(step=>step.stage==='读取日程详情'&&step.current===1));
  assert.equal(steps.at(-1).percent,100);assert.equal(store.snapshot().available,true);
  assert.ok(steps.every((step,index)=>step.percent>=0&&step.percent<=100&&(!index||step.percent>=steps[index-1].percent)));
});
(async () => {
  for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/module.json5'), 'utf8'));
  assert.ok(manifest.module.requestPermissions.some(p => p.name === 'ohos.permission.READ_WHOLE_CALENDAR'));
  assert.ok(!manifest.module.requestPermissions.some(p => p.name === 'ohos.permission.WRITE_WHOLE_CALENDAR'));
  console.log('PASS read-only permission declaration');
  console.log(`Calendar memory: ${cases.length + 1} checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
