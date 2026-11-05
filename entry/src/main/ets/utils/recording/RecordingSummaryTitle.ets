import { RecordingRecord, RecordingSummary } from './RecordingTypes';

// Field instructions describe a title; they are not a title about the audio.
// Match the instruction form rather than any particular recording or person.
export function isRecordingSummaryTitleInstruction(title: string): boolean {
  let text = title.replace(/\s+/g, '').replace(/[。.!！]$/, '');
  const basedOnContent = /^(?:请)?(?:根据|基于|结合|按照).{0,40}(?:生成|拟定|提炼|概括|总结|填写).{0,20}标题$/;
  const directRequest = /^(?:请)?(?:生成|拟定|提炼|填写|(?:不超过|最多|至多)?\d+字(?:内|以内|以下)?).{0,20}标题$/;
  return /^(?:简短|简洁|内容|录音)?标题$/.test(text) ||
    basedOnContent.test(text) || directRequest.test(text);
}

export function recordingSummaryContentTitle(title: string, overview: string): string {
  let text = title.trim();
  if (text && !isRecordingSummaryTitleInstruction(text)) { return text.substring(0, 80); }
  let first = overview.trim().split(/[。！？\r\n]/)[0].trim();
  let end = Math.min(first.length, 20);
  if (end > 0 && first.charCodeAt(end - 1) >= 0xD800 && first.charCodeAt(end - 1) <= 0xDBFF) { end--; }
  return first.substring(0, end);
}

function normalizeSummaryTitle(summary: RecordingSummary): void {
  for (let part of summary.sections || []) {
    part.summary.title = recordingSummaryContentTitle(part.summary.title, part.summary.overview);
  }
  summary.title = recordingSummaryContentTitle(summary.title,
    summary.overview || summary.sections?.[0]?.summary.overview || '');
}

// Read compatibility for already-saved summaries. No model call or file write,
// and no invalidation of completed chunks, transcript, or manually chosen name.
export function normalizeRecordingSummaryTitles(record: RecordingRecord): void {
  if (record.summary) {
    let previous = record.summary.title;
    normalizeSummaryTitle(record.summary);
    if (record.titleEdited !== true && record.title === previous && record.summary.title) {
      record.title = record.summary.title;
    }
  }
  for (let part of record.localSummaryDraft?.sections || []) { normalizeSummaryTitle(part.summary); }
}
