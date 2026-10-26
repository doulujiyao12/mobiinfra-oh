import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { stringifyJsonCompat } from '../JsonCompat';
import { dataManagerInfo, dataManagerWarn } from '../../datamanager/DataManagerLog';
import { CalendarMemoryStore } from './CalendarMemoryStore';
import { DataManagerProgress, DataManagerProgressCallback } from '../../datamanager/DataManagerTypes';
import { CalendarMemorySnapshot, CalendarSource, CalendarSeries, CalendarOccurrence,
  calendarWindow, calendarSourceSelected, emptyCalendarSnapshot } from './CalendarMemoryPolicy';

const READ_PERMISSION: Permissions = 'ohos.permission.READ_WHOLE_CALENDAR';
const MAX_OCCURRENCES: number = 10000;
const EVENT_FIELDS: (keyof calendarManager.Event)[] = ['id', 'title', 'description', 'startTime', 'endTime',
  'instanceStartTime', 'instanceEndTime', 'isAllDay', 'timeZone', 'location', 'recurrenceRule', 'isLunar'];

async function calendarReadWithDeadline<T>(operation: Promise<T>): Promise<T> {
  let timer: number = -1;
  let timeout = new Promise<T>((_resolve, reject): void => {
    timer = setTimeout(() => { reject(new Error('读取系统日历超时，请稍后重试。')); }, 15000);
  });
  try { return await Promise.race([operation, timeout]); }
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
    try {
      let grant = await abilityAccessCtrl.createAtManager().checkAccessToken(context.applicationInfo.accessTokenId, READ_PERMISSION);
      if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        throw new Error('日历读取权限未授予或已撤销，请重新授权。');
      }
      let manager = calendarManager.getCalendarManager(context);
      CalendarMemoryService.report(progress, '读取日历', '正在获取已授权的日历列表', 0, 0, 3);
      let calendars = await calendarReadWithDeadline(manager.getAllCalendars());
      let window = calendarWindow(Date.now(), settings.pastDays);
      let next = emptyCalendarSnapshot();
      next.windowStart = window[0]; next.windowEnd = window[1];
      let completed = 0;
      for (let calendar of calendars) {
        let account = calendar.getAccount();
        let source: CalendarSource = { id: calendar.id, name: account.displayName || '个人日历', type: account.type };
        next.sources.push(source);
        if (calendarSourceSelected(source, settings)) {
          await CalendarMemoryService.readCalendar(calendar, source, next, progress, completed, calendars.length);
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
      CalendarMemoryService.report(progress, '保存日历', '正在保存本次日程', 0, 0, 95);
      store.save(next); // Atomic, complete snapshot; partial reads never replace valid data.
      dataManagerInfo('Calendar sync complete: sources=' + next.sources.length + ', series=' + next.series.length +
        ', occurrences=' + next.occurrences.length + ' elapsedMs=' + (Date.now() - started));
      CalendarMemoryService.report(progress, '日历已读取', '已更新 ' + next.occurrences.length + ' 项日程',
        next.occurrences.length, next.occurrences.length, 100);
      return next;
    } catch (e) {
      let error = e as Error;
      // Preserve raw records on failure; suppress their use until access is restored.
      let current = store.snapshot();
      current.available = false;
      current.error = error.message || '读取日历失败';
      store.save(current);
      dataManagerWarn('Calendar sync failed; cached records preserved (contents omitted)');
      throw new Error(current.error);
    }
  }

  private static async readCalendar(calendar: calendarManager.Calendar, source: CalendarSource,
    snapshot: CalendarMemorySnapshot, progress?: DataManagerProgressCallback,
    sourceIndex: number = 0, sourceTotal: number = 1): Promise<void> {
    let instances: Record<string, calendarManager.Event> = {};
    // Query occurrences rather than original start times: a recurring series may
    // have started years before our window. Small windows bound each provider read.
    for (let start = snapshot.windowStart; start < snapshot.windowEnd; start += 14 * 86400000) {
      let items = await calendarReadWithDeadline(calendar.queryEventInstances(start,
        Math.min(snapshot.windowEnd, start + 14 * 86400000), undefined, EVENT_FIELDS));
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
    for (let offset = 0; offset < ids.length; offset += 100) {
      let definitions = await calendarReadWithDeadline(calendar.getEvents(
        calendarManager.EventFilter.filterById(ids.slice(offset, offset + 100)), EVENT_FIELDS));
      definitions.forEach((item: calendarManager.Event) => {
        if (item.id === undefined) { return; }
        let key = source.id + ':' + item.id;
        let series: CalendarSeries = { key: key, calendarId: source.id, eventId: item.id,
          title: (item.title || '未命名日程').substring(0, 500), description: (item.description || '').substring(0, 3000),
          location: (item.location?.location || '').substring(0, 500), timeZone: item.timeZone || '',
          allDay: item.isAllDay === true, lunar: item.isLunar === true,
          recurrence: item.recurrenceRule ? stringifyJsonCompat(item.recurrenceRule) : '', sourceName: source.name };
        seriesMap[String(item.id)] = series;
      });
      let completed = Math.min(offset + 100, ids.length);
      CalendarMemoryService.report(progress, '读取日程详情', '已读取 ' + completed + '/' + ids.length + ' 项日程详情',
        completed, ids.length, 10 + 75 * (sourceIndex + 0.55 + 0.4 * completed / ids.length) / Math.max(1, sourceTotal));
    }
    Object.keys(instances).forEach((key: string) => {
      let item = instances[key];
      let series = seriesMap[String(item.id)];
      if (!series) { throw new Error('日程读取期间发生变化，请重新同步。'); }
      if (series.recurrence && (item.instanceStartTime === undefined || item.instanceEndTime === undefined)) {
        throw new Error('系统未返回重复日程实例时间，已保留上次记录。');
      }
      let start = item.instanceStartTime ?? item.startTime;
      let end = item.instanceEndTime ?? item.endTime;
      if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) { throw new Error('日程时间无效'); }
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
    });
    Object.keys(seriesMap).forEach((key: string) => snapshot.series.push(seriesMap[key]));
  }
}
