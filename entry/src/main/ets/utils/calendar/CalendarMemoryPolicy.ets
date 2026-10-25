import { HomeRecommendationViewModel, IndexedEvent } from '../../datamanager/DataManagerTypes';

export interface CalendarSource {
  id: number;
  name: string;
  type: string;
}

export interface CalendarMemorySettings {
  enabled: boolean;
  profileEnabled: boolean;
  pastDays: number;
  excludedCalendarIds: number[];
}

export interface CalendarConsentChoice {
  configured: boolean;
  skipReminder: boolean;
}

export function shouldOfferCalendarConsent(enabled: boolean, choice: CalendarConsentChoice): boolean {
  return !enabled && !choice.configured && !choice.skipReminder;
}

export interface CalendarAgendaGroup {
  date: string;
  label: string;
  items: HomeRecommendationViewModel[];
}

export interface CalendarAgenda {
  tomorrowCount: number;
  weekCount: number;
  groups: CalendarAgendaGroup[];
}

export const CALENDAR_REMINDER_OVERVIEW_ID: string = 'calendar:overview';

export interface CalendarReminderOverview {
  reminder: HomeRecommendationViewModel;
  preview: HomeRecommendationViewModel[];
}

export function calendarReminderOverview(items: HomeRecommendationViewModel[], now: number,
  includeCompleted: boolean, error: string): CalendarReminderOverview {
  let tomorrow = calendarAgenda(items, now, true, includeCompleted);
  let week = calendarAgenda(items, now, false, includeCompleted);
  let preview: HomeRecommendationViewModel[] = [];
  // Prefer tomorrow's events in the thumbnail, while the detail always opens
  // the entire week. Cap animation pages; no events are truncated in details.
  let previewGroups = tomorrow.tomorrowCount > 0 ? tomorrow.groups : week.groups;
  previewGroups.forEach((group: CalendarAgendaGroup) => preview = preview.concat(group.items));
  let title = tomorrow.tomorrowCount > 0 ? '明天有' + tomorrow.tomorrowCount + '项提醒' :
    (week.weekCount > 0 ? '未来7天有' + week.weekCount + '项提醒' : '明天暂无日历提醒');
  let reminder: HomeRecommendationViewModel = {
    id: CALENDAR_REMINDER_OVERVIEW_ID, domain: 'other', tag: '日历安排',
    title: error ? '日历暂未更新' : title,
    desc: error ? '点击查看并重新授权或同步' : '未来7天共' + week.weekCount + '项安排 · 点击查看',
    meta: '', color: '#6372D8', imageRefs: [], thumbnailUri: '', sourceEventIds: [], detail: '',
    agentTask: '', completed: false
  };
  return { reminder: reminder, preview: error ? [] : preview.slice(0, 8) };
}

export function calendarAgenda(items: HomeRecommendationViewModel[], now: number,
  tomorrowOnly: boolean, includeCompleted: boolean): CalendarAgenda {
  let today = new Date(now);
  today.setHours(0, 0, 0, 0);
  let tomorrow = new Date(today.getTime()); tomorrow.setDate(tomorrow.getDate() + 1);
  let afterTomorrow = new Date(tomorrow.getTime()); afterTomorrow.setDate(afterTomorrow.getDate() + 1);
  let weekEnd = new Date(now); weekEnd.setDate(weekEnd.getDate() + 7);
  let week = items.filter((item: HomeRecommendationViewModel): boolean => {
    let start = item.calendarStart;
    let end = item.calendarEnd;
    return item.id.startsWith('calendar:') && start !== undefined && end !== undefined &&
      start < weekEnd.getTime() && end > now && (includeCompleted || !item.completed);
  }).sort((a: HomeRecommendationViewModel, b: HomeRecommendationViewModel): number =>
    (a.calendarStart || 0) - (b.calendarStart || 0) || a.id.localeCompare(b.id));
  let nextDay = week.filter((item: HomeRecommendationViewModel): boolean =>
    (item.calendarStart || 0) < afterTomorrow.getTime() && (item.calendarEnd || 0) > tomorrow.getTime());
  let groups: CalendarAgendaGroup[] = [];
  let map: Record<string, CalendarAgendaGroup> = {};
  (tomorrowOnly ? nextDay : week).forEach((item: HomeRecommendationViewModel) => {
    let at = tomorrowOnly ? tomorrow.getTime() : Math.max(item.calendarStart || now, today.getTime());
    let date = calendarDate(at);
    if (!map[date]) {
      let day = new Date(at);
      let weekday = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][day.getDay()];
      let label = date === calendarDate(today.getTime()) ? '今天' :
        (date === calendarDate(tomorrow.getTime()) ? '明天' : (day.getMonth() + 1) + '月' + day.getDate() + '日');
      let group: CalendarAgendaGroup = { date: date, label: label + ' · ' + weekday, items: [] };
      map[date] = group; groups.push(group);
    }
    map[date].items.push(item);
  });
  return { tomorrowCount: nextDay.length, weekCount: week.length, groups: groups };
}

export function calendarAgendaTime(item: HomeRecommendationViewModel, groupDate: string, now: number): string {
  if (item.calendarAllDay) { return '全天'; }
  let start = item.calendarStart || 0;
  if (calendarDate(start) < groupDate) { return '跨天'; }
  if (start <= now && (item.calendarEnd || 0) > now) { return '进行中'; }
  return calendarTime(start, false).substring(11);
}

export interface CalendarSeries {
  key: string;
  calendarId: number;
  eventId: number;
  title: string;
  description: string;
  location: string;
  timeZone: string;
  allDay: boolean;
  lunar: boolean;
  recurrence: string;
  sourceName: string;
}

export interface CalendarOccurrence {
  key: string;
  seriesKey: string;
  start: number;
  end: number;
  title?: string;
  description?: string;
  location?: string;
}

function calendarOccurrenceSeries(series: CalendarSeries, item: CalendarOccurrence): CalendarSeries {
  let result: CalendarSeries = {
    key: series.key, calendarId: series.calendarId, eventId: series.eventId,
    title: item.title ?? series.title, description: item.description ?? series.description,
    location: item.location ?? series.location, timeZone: series.timeZone, allDay: series.allDay,
    lunar: series.lunar, recurrence: series.recurrence, sourceName: series.sourceName
  };
  return result;
}

export interface CalendarMemorySnapshot {
  syncedAt: string;
  available: boolean;
  error: string;
  windowStart: number;
  windowEnd: number;
  sources: CalendarSource[];
  series: CalendarSeries[];
  occurrences: CalendarOccurrence[];
  completedKeys: string[];
}

export function defaultCalendarSettings(): CalendarMemorySettings {
  return { enabled: false, profileEnabled: true, pastDays: 90, excludedCalendarIds: [] };
}

export function emptyCalendarSnapshot(): CalendarMemorySnapshot {
  return { syncedAt: '', available: false, error: '', windowStart: 0, windowEnd: 0,
    sources: [], series: [], occurrences: [], completedKeys: [] };
}

export function calendarDate(value: number): string {
  let date = new Date(value);
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' +
    String(date.getDate()).padStart(2, '0');
}

export function calendarTime(value: number, allDay: boolean): string {
  if (allDay) { return calendarDate(value) + ' 全天'; }
  let date = new Date(value);
  return calendarDate(value) + ' ' + String(date.getHours()).padStart(2, '0') + ':' +
    String(date.getMinutes()).padStart(2, '0');
}

export function calendarWindow(now: number, pastDays: number): number[] {
  let start = new Date(now);
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - pastDays);
  let end = new Date(now);
  end.setDate(end.getDate() + 30);
  return [start.getTime(), end.getTime()];
}

export function calendarSourceSelected(source: CalendarSource, settings: CalendarMemorySettings): boolean {
  // Public subscription calendars are not evidence about the user.
  return source.type !== 'subscribed' && settings.excludedCalendarIds.indexOf(source.id) < 0;
}

export function calendarIndexedEvents(snapshot: CalendarMemorySnapshot, settings: CalendarMemorySettings): IndexedEvent[] {
  if (!settings.enabled || !snapshot.available) { return []; }
  let seriesMap: Record<string, CalendarSeries> = {};
  snapshot.series.forEach((series: CalendarSeries) => seriesMap[series.key] = series);
  let result: IndexedEvent[] = [];
  snapshot.occurrences.forEach((item: CalendarOccurrence) => {
    let series = seriesMap[item.seriesKey];
    if (!series || settings.excludedCalendarIds.indexOf(series.calendarId) >= 0) { return; }
    series = calendarOccurrenceSeries(series, item);
    let fact = '日历安排（未确认实际参加或完成）：' + series.title + '；时间：' +
      calendarTime(item.start, series.allDay) + ' 至 ' + calendarTime(item.end, series.allDay) +
      (series.location ? '；地点：' + series.location : '') +
      (series.description ? '；备注：' + series.description : '') +
      (series.recurrence ? '；属于同一重复日程的实例，不是独立行为证据' : '');
    let event: IndexedEvent = {
      event_id: 'calendar:' + item.key, source_state_file: 'calendar-memory', record_id: series.eventId,
      event_date: calendarDate(item.start), last_seen_date: snapshot.syncedAt.substring(0, 10),
      summary: fact, normalized_fact: fact, tags: ['日历', '日程安排', series.title],
      source_refs: ['calendar-series:' + series.key], sources: ['系统日历'], workflow_scene_ids: [],
      image_paths: [], todo: { type: '', deadline: '', text: '', agent_task: '' },
      keywords: ['日历', '日程', series.title], domains: ['other'], entity_mentions: [],
      enrichment_method: 'calendar-structured-v1', entities: [], profile_domains: [],
      calendar: { seriesKey: series.key, start: item.start, end: item.end, profileEnabled: settings.profileEnabled }
    };
    result.push(event);
  });
  return result;
}

// One repeat definition contributes at most one profile evidence item. Future
// plans remain searchable and visible as reminders, but do not form habits.
export function calendarProfileEvents(events: IndexedEvent[], now: number): IndexedEvent[] {
  let result: IndexedEvent[] = [];
  let latest: Record<string, IndexedEvent> = {};
  events.forEach((event: IndexedEvent) => {
    let calendar = event.calendar;
    if (!calendar) { result.push(event); return; }
    if (!calendar.profileEnabled || calendar.end > now) { return; }
    let previous = latest[calendar.seriesKey];
    if (!previous || (previous.calendar && previous.calendar.start < calendar.start)) {
      latest[calendar.seriesKey] = event;
    }
  });
  Object.keys(latest).sort().forEach((key: string) => result.push(latest[key]));
  return result;
}

export function calendarReminders(snapshot: CalendarMemorySnapshot, settings: CalendarMemorySettings,
  now: number): HomeRecommendationViewModel[] {
  if (!settings.enabled || !snapshot.available) { return []; }
  let end = new Date(now);
  end.setDate(end.getDate() + 7);
  let seriesMap: Record<string, CalendarSeries> = {};
  snapshot.series.forEach((series: CalendarSeries) => seriesMap[series.key] = series);
  return snapshot.occurrences.filter((item: CalendarOccurrence): boolean =>
    item.start < end.getTime() && item.end > now).sort((a: CalendarOccurrence, b: CalendarOccurrence): number =>
    a.start - b.start).filter((item: CalendarOccurrence): boolean => {
      let series = seriesMap[item.seriesKey];
      return series !== undefined && settings.excludedCalendarIds.indexOf(series.calendarId) < 0;
    }).map((item: CalendarOccurrence): HomeRecommendationViewModel => {
      let series = calendarOccurrenceSeries(seriesMap[item.seriesKey], item);
      return {
        id: 'calendar:' + item.key, domain: 'other', tag: '日历安排', title: series.title,
        calendarStart: item.start, calendarEnd: item.end, calendarAllDay: series.allDay,
        calendarLocation: series.location,
        desc: (item.start <= now ? '进行中 · ' : '') + calendarTime(item.start, series.allDay) +
          (series.location ? ' · ' + series.location : ''),
        meta: '未来7天', color: '#5E6AD2', imageRefs: [], thumbnailUri: '',
        sourceEventIds: ['calendar:' + item.key],
        detail: '日程：' + series.title + '\n来自：' + series.sourceName + '\n开始：' + calendarTime(item.start, series.allDay) +
          '\n结束：' + calendarTime(item.end, series.allDay) + (series.timeZone ? '\n时区：' + series.timeZone : '') +
          (series.location ? '\n地点：' + series.location : '') + (series.description ? '\n备注：' + series.description : '') +
          (series.recurrence ? '\n重复日程：仅展示未来7天内的安排。' : '') +
          '\n日程安排不代表已经完成；这里标记已处理只影响本App，不修改系统日历。',
        agentTask: '', completed: snapshot.completedKeys.indexOf(item.key) >= 0
      };
    });
}
