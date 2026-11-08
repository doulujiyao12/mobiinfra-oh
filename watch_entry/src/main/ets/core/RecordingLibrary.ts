import { RecordingInfo } from '../model/RecorderModels';

export interface RecordingLibraryDay { key: string; count: number; }

export function recordingLibraryDate(timestamp: number): string {
  const date: Date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) { return ''; }
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function recordingLibraryDateLabel(key: string, now: Date = new Date()): string {
  if (!key) { return '全部日期'; }
  return (key.slice(0, 4) === String(now.getFullYear()) ? '' : `${key.slice(0, 4)}年`) +
    `${Number(key.slice(5, 7))}月${Number(key.slice(8, 10))}日`;
}

export function recordingLibraryDays(records: RecordingInfo[]): RecordingLibraryDay[] {
  const counts: Map<string, number> = new Map<string, number>();
  for (const record of records) {
    const key: string = recordingLibraryDate(record.createdAt);
    if (key) { counts.set(key, (counts.get(key) || 0) + 1); }
  }
  const days: RecordingLibraryDay[] = [];
  counts.forEach((count: number, key: string): void => { days.push({ key: key, count: count }); });
  return days.sort((left: RecordingLibraryDay, right: RecordingLibraryDay): number => right.key.localeCompare(left.key));
}

export function recordingsForLibraryDate(records: RecordingInfo[], key: string): RecordingInfo[] {
  return key ? records.filter((record: RecordingInfo): boolean => recordingLibraryDate(record.createdAt) === key) : records;
}
