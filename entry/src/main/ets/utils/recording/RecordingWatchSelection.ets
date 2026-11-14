import { RecordingRecord } from './RecordingTypes';
import { recordingSearchDate } from './RecordingSearch';

export interface RecordingWatchItem {
  id: string;
  createdAt: number;
  durationMs: number;
  bytes: number;
  title: string;
  localState: 'new' | 'saved' | 'audio-deleted';
}
export interface RecordingWatchCatalog { sourceId: string; items: RecordingWatchItem[]; }
export interface RecordingWatchSelection { sourceId: string; recordingIds: string[]; }

export function watchRecordingDay(item: RecordingWatchItem): string {
  const date = new Date(item.createdAt);
  return Number.isFinite(date.getTime()) ? recordingSearchDate(date) : '';
}
export function watchRecordingDateCounts(items: RecordingWatchItem[]): Map<string, number> {
  const counts: Map<string, number> = new Map<string, number>();
  for (const item of items) {
    const day = watchRecordingDay(item);
    if (day) { counts.set(day, (counts.get(day) || 0) + 1); }
  }
  return counts;
}
export function filterWatchRecordings(items: RecordingWatchItem[], day: string): RecordingWatchItem[] {
  return day ? items.filter((item: RecordingWatchItem): boolean => watchRecordingDay(item) === day) : items;
}
// Selection is independent of the visible date: moving through the calendar
// cannot drop choices on other days, or restore audio explicitly removed locally.
export function selectWatchRecordings(items: RecordingWatchItem[], selected: string[], targets: string[], select: boolean): string[] {
  const next: Set<string> = new Set<string>(selected);
  for (const id of targets) { if (select) { next.add(id); } else { next.delete(id); } }
  return items.filter((item: RecordingWatchItem): boolean => item.localState !== 'audio-deleted' && next.has(item.id))
    .map((item: RecordingWatchItem): string => item.id);
}
export function watchRecordingProcessingStage(record: RecordingRecord): string {
  if (record.audioDeleted) { return 'done'; }
  if (record.analysis === null || record.transcriptionComplete === false) { return 'transcribe'; }
  if (record.analysis.segments.some((segment): boolean => segment.text.trim().length > 0) &&
    (record.summary === undefined || record.summary.complete === false)) { return 'summarize'; }
  return 'done';
}
