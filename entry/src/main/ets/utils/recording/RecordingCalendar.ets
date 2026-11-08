import { RecordingRecord } from './RecordingTypes';
import { recordingSearchDate } from './RecordingSearch';

export type RecordingCalendarScope = 'all' | 'month' | 'day';
export interface RecordingCalendarDay {
  key: string; day: number; weekday: string; inMonth: boolean; today: boolean; hasRecord: boolean;
}
export interface RecordingCalendarWeek { key: string; days: RecordingCalendarDay[]; }
const WEEKDAYS: string[] = ['日', '一', '二', '三', '四', '五', '六'];

export function recordingCalendarDate(record: RecordingRecord): string {
  let date = new Date(record.createdAt);
  return Number.isFinite(date.getTime()) ? recordingSearchDate(date) : '';
}
export function recordingCalendarMonth(now: Date): string { return recordingSearchDate(now).slice(0, 7); }
function monthDate(month: string): Date {
  if (!/^\d{4}-\d{2}$/.test(month)) { throw new Error('录音月份无效'); }
  let date = new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)) - 1, 1);
  if (recordingCalendarMonth(date) !== month) { throw new Error('录音月份无效'); }
  return date;
}
export function recordingCalendarMonthTitle(month: string): string {
  let date = monthDate(month);
  return date.getFullYear() + '年' + (date.getMonth() + 1) + '月';
}
export function shiftRecordingCalendarMonth(month: string, offset: number): string {
  let date = monthDate(month); date.setMonth(date.getMonth() + offset); return recordingCalendarMonth(date);
}
export function recordingCalendarCounts(records: RecordingRecord[]): Map<string, number> {
  let counts: Map<string, number> = new Map<string, number>();
  for (let record of records) {
    let day = recordingCalendarDate(record);
    if (day) { counts.set(day, (counts.get(day) || 0) + 1); }
  }
  return counts;
}
export function recordingCalendarWeeks(month: string, counts: Map<string, number>, now: Date = new Date()): RecordingCalendarWeek[] {
  let first = monthDate(month), last = new Date(first.getFullYear(), first.getMonth() + 1, 0);
  let start = new Date(first.getTime()); start.setDate(start.getDate() - start.getDay());
  let end = new Date(last.getTime()); end.setDate(end.getDate() + 6 - end.getDay());
  let today = recordingSearchDate(now), weeks: RecordingCalendarWeek[] = [];
  for (let cursor = new Date(start.getTime()); cursor.getTime() <= end.getTime();) {
    let days: RecordingCalendarDay[] = [];
    for (let index = 0; index < 7; index++) {
      let key = recordingSearchDate(cursor);
      days.push({ key: key, day: cursor.getDate(), weekday: WEEKDAYS[cursor.getDay()], inMonth: key.slice(0, 7) === month,
        today: key === today, hasRecord: (counts.get(key) || 0) > 0 });
      cursor.setDate(cursor.getDate() + 1);
    }
    weeks.push({ key: days[0].key, days: days });
  }
  return weeks;
}
export function recordingCalendarWeekIndex(weeks: RecordingCalendarWeek[], day: string): number {
  let index = weeks.findIndex((week: RecordingCalendarWeek): boolean => week.days.some((value: RecordingCalendarDay): boolean => value.key === day));
  return index >= 0 ? index : 0;
}
export function filterRecordingCalendar(records: RecordingRecord[], scope: RecordingCalendarScope, month: string, day: string): RecordingRecord[] {
  if (scope === 'all') { return records; }
  return records.filter((record: RecordingRecord): boolean => {
    let date = recordingCalendarDate(record);
    return scope === 'day' ? date === day : date.slice(0, 7) === month;
  });
}
export function recordingCardClock(record: RecordingRecord, dayOnly: boolean, now: Date = new Date()): string {
  let date = new Date(record.createdAt);
  if (!Number.isFinite(date.getTime())) { return '日期未知'; }
  let time = String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
  if (dayOnly) { return time; }
  return (date.getFullYear() === now.getFullYear() ? '' : date.getFullYear() + '/') + (date.getMonth() + 1) + '/' + date.getDate() + ' ' + time;
}
export function recordingCardPreview(record: RecordingRecord): string {
  let text = record.summary?.overview.trim() || record.summary?.keyPoints.find((value: string): boolean => !!value.trim()) || '';
  if (!text) {
    text = (record.analysis?.segments || []).filter((segment): boolean => !!segment.text.trim()).slice(0, 2)
      .map((segment): string => segment.text).join(' ');
  }
  return text.replace(/\s+/g, ' ').trim().slice(0, 260) || (record.analysis ? '暂无可用文字' : '点开录音，开始转写');
}
