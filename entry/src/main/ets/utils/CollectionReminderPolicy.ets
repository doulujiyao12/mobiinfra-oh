// Calendar arithmetic and replay protection are independent of notification/UI APIs.
export const COLLECTION_REMINDER_DETAIL_DAYS: number = 14;
export const COLLECTION_REMINDER_MAX_AGE_MS: number = 48 * 60 * 60 * 1000;

export class CollectionReminderState {
  enabled: boolean = false;
  hour: number = 21;
  minute: number = 0;
  planToken: string = '';
  lastCollectedAt: number = 0;
  handledDays: string[] = [];
  reminderIds: number[] = [];
  registeredStamp: string = '';
  errorText: string = '';
}

export class CollectionReminderIntent {
  planToken: string = '';
  dueAt: number = 0;
}

export function collectionReminderDayKey(time: number): string {
  let date = new Date(time);
  return String(date.getFullYear()) + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' +
    String(date.getDate()).padStart(2, '0');
}

export function collectionReminderTimeText(hour: number, minute: number): string {
  return String(hour).padStart(2, '0') + ':' + String(minute).padStart(2, '0');
}

export function collectionReminderNextTime(hour: number, minute: number, now: number): number {
  let date = new Date(now);
  date.setHours(hour, minute, 0, 0);
  if (date.getTime() <= now) { date.setDate(date.getDate() + 1); }
  return date.getTime();
}

export function collectionReminderPreviousTime(hour: number, minute: number, now: number): number {
  let date = new Date(now);
  date.setHours(hour, minute, 0, 0);
  if (date.getTime() > now) { date.setDate(date.getDate() - 1); }
  return date.getTime();
}

export function collectionReminderAddDays(time: number, days: number): number {
  let date = new Date(time);
  date.setDate(date.getDate() + days);
  return date.getTime();
}

export function collectionReminderMissedDays(lastCollectedAt: number, now: number): number {
  if (lastCollectedAt <= 0 || !Number.isFinite(lastCollectedAt)) { return 0; }
  let last = new Date(lastCollectedAt);
  let today = new Date(now);
  // Local calendar dates, not elapsed 24-hour periods (which fail across DST).
  let lastDay = Date.UTC(last.getFullYear(), last.getMonth(), last.getDate());
  let todayDay = Date.UTC(today.getFullYear(), today.getMonth(), today.getDate());
  return Math.max(0, Math.round((todayDay - lastDay) / 86400000));
}

export function collectionReminderContent(lastCollectedAt: number, dueAt: number, detailed: boolean): string {
  if (lastCollectedAt <= 0) { return '还没有完成首次采集，点此解锁手机，执行已开启的任务。'; }
  let lastDate = collectionReminderDayKey(lastCollectedAt);
  if (!detailed) { return '上次成功采集：' + lastDate + '。点此解锁手机，更新你的足迹。'; }
  let days = collectionReminderMissedDays(lastCollectedAt, dueAt);
  return (days > 0 ? '已连续 ' + days + ' 天没有成功采集。' : '今天已采集过，也可以再更新一次。') +
    '点此解锁手机，执行已开启的任务。';
}

export function collectionReminderCanClaim(state: CollectionReminderState,
  intent: CollectionReminderIntent, now: number): boolean {
  if (!state.enabled || state.planToken.length === 0 || intent.planToken !== state.planToken ||
    !Number.isFinite(intent.dueAt) || intent.dueAt <= 0 || intent.dueAt > now ||
    now - intent.dueAt >= COLLECTION_REMINDER_MAX_AGE_MS) { return false; }
  return state.handledDays.indexOf(collectionReminderDayKey(intent.dueAt)) < 0;
}

export function collectionReminderStamp(state: CollectionReminderState, now: number): string {
  return state.planToken + ':' + collectionReminderTimeText(state.hour, state.minute) + ':' +
    collectionReminderDayKey(now) + ':' + new Date(now).getTimezoneOffset() + ':' + state.lastCollectedAt;
}

export function normalizeCollectionReminderState(saved: CollectionReminderState,
  fallbackToken: string): CollectionReminderState {
  let state = new CollectionReminderState();
  state.enabled = saved.enabled === true;
  state.hour = Number.isInteger(saved.hour) && saved.hour >= 0 && saved.hour <= 23 ? saved.hour : 21;
  state.minute = Number.isInteger(saved.minute) && saved.minute >= 0 && saved.minute <= 59 ? saved.minute : 0;
  state.planToken = typeof saved.planToken === 'string' && saved.planToken.length > 0 ? saved.planToken : fallbackToken;
  state.lastCollectedAt = Number.isFinite(saved.lastCollectedAt) && saved.lastCollectedAt > 0 ? saved.lastCollectedAt : 0;
  if (Array.isArray(saved.handledDays)) {
    state.handledDays = saved.handledDays.filter((day: string): boolean =>
      typeof day === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(day)).slice(-90);
  }
  if (Array.isArray(saved.reminderIds)) {
    state.reminderIds = saved.reminderIds.filter((id: number): boolean => Number.isInteger(id) && id >= 0);
  }
  state.registeredStamp = typeof saved.registeredStamp === 'string' ? saved.registeredStamp : '';
  state.errorText = typeof saved.errorText === 'string' ? saved.errorText : '';
  return state;
}
