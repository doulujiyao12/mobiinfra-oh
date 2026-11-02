import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { stringifyJsonCompat } from '../JsonCompat';
import { dataManagerInfo, dataManagerWarn } from '../../datamanager/DataManagerLog';
import { CalendarMemoryStore } from './CalendarMemoryStore';
import { DataManagerProgress, DataManagerProgressCallback } from '../../datamanager/DataManagerTypes';
import { CalendarMemorySnapshot, CalendarSource, CalendarSeries, CalendarOccurrence,
  calendarWindow, calendarSourceSelected, emptyCalendarSnapshot } from './CalendarMemoryPolicy';

const READ_PERMISSION: Permissions = 'ohos.permission.READ_WHOLE_CALENDAR';
const MAX_OCCURRENCES: number = 10000;
const DEFINITION_BATCH_SIZE: number = 100;
const EVENT_FIELDS: (keyof calendarManager.Event)[] = ['id', 'title', 'description', 'startTime', 'endTime',
  'instanceStartTime', 'instanceEndTime', 'isAllDay', 'timeZone', 'location', 'recurrenceRule', 'isLunar'];
const DEFINITION_FIELDS: (keyof calendarManager.Event)[] = ['id', 'title', 'description', 'startTime', 'endTime',
  'isAllDay', 'timeZone', 'location', 'recurrenceRule', 'isLunar'];

interface CalendarReadStats {
  missingDefinitions: number;
  recoveredDefinitions: number;
  instanceFallbacks: number;
  disappearedEvents: number;
  skippedOccurrences: number;
}

async function calendarReadWithDeadline<T>(operation: Promise<T>, phase: string, calendarId: number = -1): Promise<T> {
  let started = Date.now();
  let timer: number = -1;
  let timeout = new Promise<T>((_resolve, reject): void => {
    timer = setTimeout(() => { reject(new Error('读取系统日历超时，请稍后重试。')); }, 15000);
  });
  try {
    let result = await Promise.race([operation, timeout]);
    dataManagerInfo('CALENDAR_READ phase=' + phase + ' calendarId=' + calendarId + ' elapsedMs=' + (Date.now() - started));
    return result;
  } catch (e) {
    let error = e as Error;
    let code = (e as BusinessError).code;
    dataManagerWarn('CALENDAR_READ_FAILED phase=' + phase + ' calendarId=' + calendarId +
      ' code=' + (code === undefined ? 'none' : String(code)) + ' elapsedMs=' + (Date.now() - started));
    throw error;
  }
  finally { if (timer !== -1) { clearTimeout(timer); } }
}

export class CalendarMemoryService {
  private static running: Promise<CalendarMemorySnapshot> | null = null;

  static async canAutoRefresh(context: common.Context): Promise<boolean> {
    let store = new CalendarMemoryStore(context.filesDir);
    if (!store.settings().enabled) { return false; }
    let granted = false;
    try {
      granted = await abilityAccessCtrl.createAtManager().checkAccessToken(context.applicationInfo.accessTokenId,
        READ_PERMISSION) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) { granted = false; }
    if (!granted) {
      // Permission checks never open a dialog or query the calendar provider.
      // Preserve raw records but stop presenting a previously authorized cache.
      let snapshot = store.snapshot();
      let message = '日历未授权，已跳过自动更新；可到日历分析重新授权。';
      if (snapshot.available || snapshot.error !== message) {
        snapshot.available = false; snapshot.error = message; store.save(snapshot);
      }
    }
    return granted;
  }

  static async requestAccess(context: common.UIAbilityContext): Promise<void> {
    new CalendarMemoryStore(context.filesDir).markConfigured();
    let result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [READ_PERMISSION]);
    if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
      throw new Error('未获得日历读取授权。请在系统应用权限中允许读取日历；若无法授权，请核对ACL和签名Profile。');
    }
  }

  static async refresh(context: common.Context, progress?: DataManagerProgressCallback): Promise<CalendarMemorySnapshot> {
    if (CalendarMemoryService.running !== null) { return CalendarMemoryService.running; }
    let work = CalendarMemoryService.read(context, progress);
    CalendarMemoryService.running = work;
    try { return await work; } finally { CalendarMemoryService.running = null; }
  }

  private static report(progress: DataManagerProgressCallback | undefined, stage: string, message: string,
    current: number, total: number, percent: number): void {
    if (progress) {
      let value: DataManagerProgress = { stage: stage, message: message, current: current, total: total, percent: percent };
      progress(value);
    }
  }

  private static async read(context: common.Context, progress?: DataManagerProgressCallback): Promise<CalendarMemorySnapshot> {
    let store = new CalendarMemoryStore(context.filesDir);
    let settings = store.settings();
    if (!settings.enabled) { return store.snapshot(); }
    let settingsVersion = stringifyJsonCompat(settings);
    let previous = store.snapshot();
    let started = Date.now();
    let stats: CalendarReadStats = { missingDefinitions: 0, recoveredDefinitions: 0, instanceFallbacks: 0,
      disappearedEvents: 0, skippedOccurrences: 0 };
    try {
      let grant = await abilityAccessCtrl.createAtManager().checkAccessToken(context.applicationInfo.accessTokenId, READ_PERMISSION);
      if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        throw new Error('日历读取权限未授予或已撤销，请重新授权。');
      }
      let manager = calendarManager.getCalendarManager(context);
      CalendarMemoryService.report(progress, '读取日历', '正在获取已授权的日历列表', 0, 0, 3);
      let calendars = await calendarReadWithDeadline(manager.getAllCalendars(), 'calendars');
      let window = calendarWindow(Date.now(), settings.pastDays);
      let next = emptyCalendarSnapshot();
      next.windowStart = window[0]; next.windowEnd = window[1];
      let completed = 0;
      for (let calendar of calendars) {
        let account = calendar.getAccount();
        let source: CalendarSource = { id: calendar.id, name: account.displayName || '个人日历', type: account.type };
        next.sources.push(source);
        if (calendarSourceSelected(source, settings)) {
          await CalendarMemoryService.readCalendar(calendar, source, next, stats, progress, completed, calendars.length);
        }
        completed++;
        CalendarMemoryService.report(progress, '读取日历', '已检查 ' + completed + '/' + calendars.length + ' 个日历',
          completed, calendars.length, 10 + 75 * completed / calendars.length);
      }
      if (stringifyJsonCompat(store.settings()) !== settingsVersion) {
        throw new Error('读取期间日历配置已变化，请重新同步。');
      }
      next.series.sort((a: CalendarSeries, b: CalendarSeries): number => a.key.localeCompare(b.key));
      next.occurrences.sort((a: CalendarOccurrence, b: CalendarOccurrence): number => a.key.localeCompare(b.key));
      next.completedKeys = previous.completedKeys.filter((key: string): boolean =>
        next.occurrences.some((item: CalendarOccurrence): boolean => item.key === key));
      next.syncedAt = new Date().toISOString(); next.available = true;
      if (stats.skippedOccurrences > 0) {
        next.readWarning = '有 ' + stats.skippedOccurrences + ' 项异常日程暂未读取，其余日程已更新，可稍后重新同步。';
      }
      CalendarMemoryService.report(progress, '保存日历', '正在保存本次日程', 0, 0, 95);
      // Publish only after every selected source and its recheck succeeded.
      // Unreadable rows are explicit warnings; provider failures retain the old snapshot.
      store.save(next);
      dataManagerInfo('Calendar sync complete: sources=' + next.sources.length + ', series=' + next.series.length +
        ', occurrences=' + next.occurrences.length + ' missingDefinitions=' + stats.missingDefinitions +
        ' recoveredDefinitions=' + stats.recoveredDefinitions + ' instanceFallbacks=' + stats.instanceFallbacks +
        ' noLongerInWindow=' + stats.disappearedEvents + ' skippedOccurrences=' + stats.skippedOccurrences +
        ' elapsedMs=' + (Date.now() - started));
      CalendarMemoryService.report(progress, '日历已读取', '已更新 ' + next.occurrences.length + ' 项日程' +
        (next.readWarning ? '；' + next.readWarning : ''),
        next.occurrences.length, next.occurrences.length, 100);
      return next;
    } catch (e) {
      let error = e as Error;
      // Preserve raw records on failure; suppress their use until access is restored.
      let current = store.snapshot();
      current.available = false;
      current.error = error.message || '读取日历失败';
      store.save(current);
      let code = (e as BusinessError).code;
      dataManagerWarn('CALENDAR_SYNC_FAILED code=' + (code === undefined ? 'none' : String(code)) +
        ' elapsedMs=' + (Date.now() - started) + '; cached records preserved (contents omitted)');
      throw new Error(current.error);
    }
  }

  private static async readCalendar(calendar: calendarManager.Calendar, source: CalendarSource,
    snapshot: CalendarMemorySnapshot, stats: CalendarReadStats, progress?: DataManagerProgressCallback,
    sourceIndex: number = 0, sourceTotal: number = 1): Promise<void> {
    let instances: Record<string, calendarManager.Event> = {};
    // Query occurrences rather than original start times: a recurring series may
    // have started years before our window. Small windows bound each provider read.
    for (let start = snapshot.windowStart; start < snapshot.windowEnd; start += 14 * 86400000) {
      let items = await calendarReadWithDeadline(calendar.queryEventInstances(start,
        Math.min(snapshot.windowEnd, start + 14 * 86400000), undefined, EVENT_FIELDS), 'instances', source.id);
      items.forEach((item: calendarManager.Event) => {
        let at = item.instanceStartTime ?? item.startTime;
        if (item.id === undefined || !Number.isFinite(at)) { throw new Error('日历返回的日程缺少ID或时间'); }
        instances[String(item.id) + ':' + at] = item;
      });
      if (Object.keys(instances).length + snapshot.occurrences.length > MAX_OCCURRENCES) {
        throw new Error('日程数量过多，请缩小读取天数或减少选择的日历后重试。');
      }
      let chunk = Math.floor((start - snapshot.windowStart) / (14 * 86400000)) + 1;
      let chunks = Math.ceil((snapshot.windowEnd - snapshot.windowStart) / (14 * 86400000));
      CalendarMemoryService.report(progress, '读取日历日程', '日历 ' + (sourceIndex + 1) + '/' + sourceTotal +
        '：已读取 ' + chunk + '/' + chunks + ' 个日期分段', chunk, chunks,
        10 + 75 * (sourceIndex + 0.55 * chunk / chunks) / Math.max(1, sourceTotal));
    }
    let ids: number[] = [];
    Object.keys(instances).forEach((key: string) => {
      let id = instances[key].id;
      if (id !== undefined && ids.indexOf(id) < 0) { ids.push(id); }
    });
    let seriesMap: Record<string, CalendarSeries> = {};
    for (let offset = 0; offset < ids.length; offset += DEFINITION_BATCH_SIZE) {
      let requested = ids.slice(offset, offset + DEFINITION_BATCH_SIZE);
      let definitions = await calendarReadWithDeadline(calendar.getEvents(
        calendarManager.EventFilter.filterById(requested), DEFINITION_FIELDS), 'definitions', source.id);
      definitions.forEach((item: calendarManager.Event) => {
        if (item.id === undefined || requested.indexOf(item.id) < 0) { return; }
        seriesMap[String(item.id)] = CalendarMemoryService.seriesFromEvent(item, source, item.id);
      });
      let completed = Math.min(offset + DEFINITION_BATCH_SIZE, ids.length);
      CalendarMemoryService.report(progress, '读取日程详情', '已读取 ' + completed + '/' + ids.length + ' 项日程详情',
        completed, ids.length, 10 + 75 * (sourceIndex + 0.55 + 0.4 * completed / ids.length) / Math.max(1, sourceTotal));
    }
    let missing = ids.filter((id: number): boolean => !seriesMap[String(id)]);
    if (missing.length > 0) {
      instances = await CalendarMemoryService.recheckMissing(calendar, source, snapshot, instances, seriesMap, missing,
        stats, progress, sourceIndex, sourceTotal);
    }
    let missingIds = new Set<number>(missing);
    let usedSeries: Record<string, boolean> = {};
    Object.keys(instances).forEach((key: string) => {
      let item = instances[key];
      let series = seriesMap[String(item.id)];
      let problem = series ? CalendarMemoryService.occurrenceProblem(item, series) : 'missing_details';
      if (!series && item.id !== undefined) {
        problem = CalendarMemoryService.occurrenceProblem(item,
          CalendarMemoryService.seriesFromEvent(item, source, item.id)) || problem;
      }
      if (problem && item.id !== undefined && missingIds.has(item.id)) {
        stats.skippedOccurrences++;
        dataManagerWarn('CALENDAR_OCCURRENCE_SKIPPED calendarId=' + source.id + ' eventId=' + item.id + ' reason=' + problem);
        return;
      }
      if (!series) { throw new Error('日历日程详情无法对应，已保留上次记录。'); }
      if (problem === 'missing_repeat_time') { throw new Error('系统未返回重复日程实例时间，已保留上次记录。'); }
      if (problem) { throw new Error('日程时间无效'); }
      let start = item.instanceStartTime ?? item.startTime;
      let end = item.instanceEndTime ?? item.endTime;
      if (end <= snapshot.windowStart || start >= snapshot.windowEnd) { return; }
      let occurrence: CalendarOccurrence = { key: source.id + ':' + key, seriesKey: series.key, start: start, end: end };
      // Providers may return an exception's edited content on the occurrence
      // while getEvents returns the original recurring definition.
      if (item.title !== undefined && item.title !== series.title) { occurrence.title = item.title.substring(0, 500); }
      if (item.description !== undefined && item.description !== series.description) {
        occurrence.description = item.description.substring(0, 3000);
      }
      if (item.location?.location !== undefined && item.location.location !== series.location) {
        occurrence.location = item.location.location.substring(0, 500);
      }
      snapshot.occurrences.push(occurrence);
      usedSeries[String(item.id)] = true;
    });
    Object.keys(usedSeries).forEach((key: string) => snapshot.series.push(seriesMap[key]));
  }

  private static seriesFromEvent(item: calendarManager.Event, source: CalendarSource, id: number): CalendarSeries {
    let series: CalendarSeries = { key: source.id + ':' + id, calendarId: source.id, eventId: id,
      title: (item.title || '未命名日程').substring(0, 500), description: (item.description || '').substring(0, 3000),
      location: (item.location?.location || '').substring(0, 500), timeZone: item.timeZone || '',
      allDay: item.isAllDay === true, lunar: item.isLunar === true,
      recurrence: item.recurrenceRule ? stringifyJsonCompat(item.recurrenceRule) : '', sourceName: source.name };
    return series;
  }

  private static occurrenceProblem(item: calendarManager.Event, series: CalendarSeries): string {
    if (series.recurrence && (item.instanceStartTime === undefined || item.instanceEndTime === undefined)) {
      return 'missing_repeat_time';
    }
    let start = item.instanceStartTime ?? item.startTime;
    let end = item.instanceEndTime ?? item.endTime;
    return !Number.isFinite(start) || !Number.isFinite(end) || end < start ? 'invalid_time' : '';
  }

  private static async recheckMissing(calendar: calendarManager.Calendar, source: CalendarSource,
    snapshot: CalendarMemorySnapshot, original: Record<string, calendarManager.Event>,
    seriesMap: Record<string, CalendarSeries>, missing: number[], stats: CalendarReadStats,
    progress: DataManagerProgressCallback | undefined, sourceIndex: number, sourceTotal: number): Promise<Record<string, calendarManager.Event>> {
    stats.missingDefinitions += missing.length;
    dataManagerWarn('CALENDAR_RECHECK_BEGIN calendarId=' + source.id + ' missing=' + missing.length +
      ' eventIds=' + missing.slice(0, 20).join(','));
    let result: Record<string, calendarManager.Event> = {};
    let missingIds = new Set<number>(missing);
    Object.keys(original).forEach((key: string) => {
      let item = original[key];
      if (item.id !== undefined && !missingIds.has(item.id)) { result[key] = item; }
    });
    // Exactly one recheck per missing ID, in bounded groups. A targeted instance
    // query covers the same window so moved/deleted instances cannot survive from
    // the first read. Never classify a rejected query as an empty/deleted result.
    for (let offset = 0; offset < missing.length; offset += DEFINITION_BATCH_SIZE) {
      let requested = missing.slice(offset, offset + DEFINITION_BATCH_SIZE);
      CalendarMemoryService.report(progress, '复查日程', '正在复查 ' + requested.length + ' 项日程详情',
        offset, missing.length, 10 + 75 * (sourceIndex + 0.95) / Math.max(1, sourceTotal));
      let definitions = await calendarReadWithDeadline(calendar.getEvents(
        calendarManager.EventFilter.filterById(requested), DEFINITION_FIELDS), 'recheck-definitions', source.id);
      let recovered = 0;
      definitions.forEach((item: calendarManager.Event) => {
        if (item.id === undefined || requested.indexOf(item.id) < 0 || seriesMap[String(item.id)]) { return; }
        seriesMap[String(item.id)] = CalendarMemoryService.seriesFromEvent(item, source, item.id);
        recovered++;
      });
      let current = await calendarReadWithDeadline(calendar.queryEventInstances(snapshot.windowStart, snapshot.windowEnd,
        requested, EVENT_FIELDS), 'recheck-instances', source.id);
      let present: Record<string, boolean> = {};
      let fallback = 0;
      current.forEach((item: calendarManager.Event) => {
        if (item.id === undefined) { throw new Error('复查日历时系统未返回日程ID，已保留上次记录。'); }
        if (requested.indexOf(item.id) < 0) { return; }
        present[String(item.id)] = true;
        let candidate = CalendarMemoryService.seriesFromEvent(item, source, item.id);
        if (!seriesMap[String(item.id)] && !CalendarMemoryService.occurrenceProblem(item, candidate)) {
          // Both queries succeeded, but only the instance API exposes this event.
          // Use freshly queried content, never a stale cached/initial instance.
          seriesMap[String(item.id)] = candidate; fallback++;
        }
        result[String(item.id) + ':' + (item.instanceStartTime ?? item.startTime)] = item;
      });
      if (Object.keys(result).length + snapshot.occurrences.length > MAX_OCCURRENCES) {
        throw new Error('日程数量过多，请缩小读取天数或减少选择的日历后重试。');
      }
      let disappeared = requested.filter((id: number): boolean => !present[String(id)]);
      stats.recoveredDefinitions += recovered; stats.instanceFallbacks += fallback;
      stats.disappearedEvents += disappeared.length;
      // Absence means deleted OR moved outside our window; do not claim deletion
      // without evidence or retain old occurrences that would create ghost alerts.
      dataManagerInfo('CALENDAR_RECHECK_RESULT calendarId=' + source.id + ' requested=' + requested.length +
        ' recoveredDefinitions=' + recovered + ' instanceFallbacks=' + fallback + ' noLongerInWindow=' + disappeared.length +
        ' absentEventIds=' + disappeared.slice(0, 20).join(','));
    }
    return result;
  }
}
