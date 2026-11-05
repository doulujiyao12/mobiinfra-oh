import { RecordingRecord, RecordingSummary } from './RecordingTypes';

export const RECORDING_LOCAL_SUMMARY_MAX_ITEMS: number = 3;

export function uniqueRecordingSummaryItems(items: string[], limit: number = 12): string[] {
  let seen: Set<string> = new Set(); let result: string[] = [];
  for (let item of items) {
    let text = item.trim().replace(/^(?:[-*•]\s+|\d+[.)、]\s*)/, '').substring(0, 1000);
    let key = text.replace(/\s+/g, ' ').replace(/[。；;,，.]+$/, '').trim();
    if (key && !seen.has(key)) { seen.add(key); result.push(text); }
  }
  return result.slice(0, limit);
}

// Applied only to newly parsed local output. Old saved summaries are limited
// in the view, so continuing a draft never discards its previously saved items.
export function limitLocalRecordingSummaryItems(summary: RecordingSummary): void {
  summary.keyPoints = uniqueRecordingSummaryItems(summary.keyPoints, RECORDING_LOCAL_SUMMARY_MAX_ITEMS);
  summary.decisions = uniqueRecordingSummaryItems(summary.decisions, RECORDING_LOCAL_SUMMARY_MAX_ITEMS);
  summary.actionItems = uniqueRecordingSummaryItems(summary.actionItems, RECORDING_LOCAL_SUMMARY_MAX_ITEMS);
  summary.openQuestions = uniqueRecordingSummaryItems(summary.openQuestions, RECORDING_LOCAL_SUMMARY_MAX_ITEMS);
}

function normalizeLists(summary: RecordingSummary): void {
  if (Array.isArray(summary.keyPoints)) { summary.keyPoints = uniqueRecordingSummaryItems(summary.keyPoints); }
  if (Array.isArray(summary.decisions)) { summary.decisions = uniqueRecordingSummaryItems(summary.decisions); }
  if (Array.isArray(summary.actionItems)) { summary.actionItems = uniqueRecordingSummaryItems(summary.actionItems); }
  if (Array.isArray(summary.openQuestions)) { summary.openQuestions = uniqueRecordingSummaryItems(summary.openQuestions); }
}

export function normalizeRecordingSummaryLists(record: RecordingRecord): void {
  if (record.summary) {
    normalizeLists(record.summary);
    for (let section of record.summary.sections || []) { normalizeLists(section.summary); }
  }
  for (let section of record.localSummaryDraft?.sections || []) { normalizeLists(section.summary); }
}
