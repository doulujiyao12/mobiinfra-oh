import { JsonMap } from '../../datamanager/DataManagerTypes';
import { RecordingRecord, RecordingSummary, recordingTime } from './RecordingTypes';

export interface RecordingSearchPlan { startDate: string; endDate: string; keywords: string[]; }
export interface RecordingSearchHit { recordId: string; snippet: string; reason: string; start: number; score: number; }
export interface RecordingSearchResult { hits: RecordingSearchHit[]; answer: string; notice: string; range: string; }
export interface RecordingSearchClock {
  today: string; weekday: string; yesterday: string; this_week_start: string; last_week_start: string;
  last_week_end: string; this_month_start: string; last_month_start: string; last_month_end: string;
}
export interface RecordingSearchMetadata {
  id: string; title: string; date: string; speakers: string[]; summary: string;
  summary_truncated: boolean; transcript_available: boolean; transcript_complete: boolean;
}
export interface RecordingSearchEvidence extends RecordingSearchMetadata { number: number; excerpts: string[]; }

export function recordingSearchDate(date: Date): string {
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}
export function recordingSearchClock(now: Date): RecordingSearchClock {
  let today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let monday = new Date(today.getTime()); monday.setDate(monday.getDate() - (monday.getDay() + 6) % 7);
  let previousMonday = new Date(monday.getTime()); previousMonday.setDate(previousMonday.getDate() - 7);
  let previousSunday = new Date(monday.getTime()); previousSunday.setDate(previousSunday.getDate() - 1);
  let yesterday = new Date(today.getTime()); yesterday.setDate(yesterday.getDate() - 1);
  return { today: recordingSearchDate(today), weekday: '星期' + '日一二三四五六'.charAt(today.getDay()),
    yesterday: recordingSearchDate(yesterday), this_week_start: recordingSearchDate(monday),
    last_week_start: recordingSearchDate(previousMonday), last_week_end: recordingSearchDate(previousSunday),
    this_month_start: recordingSearchDate(new Date(now.getFullYear(), now.getMonth(), 1)),
    last_month_start: recordingSearchDate(new Date(now.getFullYear(), now.getMonth() - 1, 1)),
    last_month_end: recordingSearchDate(new Date(now.getFullYear(), now.getMonth(), 0)) };
}
function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) { return false; }
  let date = new Date(Number(value.slice(0, 4)), Number(value.slice(5, 7)) - 1, Number(value.slice(8, 10)));
  return recordingSearchDate(date) === value;
}
export function parseRecordingSearchPlan(value: JsonMap): RecordingSearchPlan {
  if (typeof value['start_date'] !== 'string' || typeof value['end_date'] !== 'string' || !Array.isArray(value['keywords'])) {
    throw new Error('搜索条件格式不完整');
  }
  let start = (value['start_date'] as string).trim(), end = (value['end_date'] as string).trim();
  if ((start && !validDate(start)) || (end && !validDate(end)) || (start && end && start > end)) {
    throw new Error('搜索日期范围无效');
  }
  let words: string[] = [];
  for (let raw of value['keywords'] as string[]) {
    if (typeof raw !== 'string') { throw new Error('搜索关键词格式无效'); }
    let word = raw.trim();
    if (word.length > 0 && word.length <= 40 && !words.includes(word)) { words.push(word); }
  }
  if (words.length > 8) { words = words.slice(0, 8); }
  if (!start && !end && words.length === 0) { throw new Error('未识别到搜索时间或关键词'); }
  return { startDate: start, endDate: end, keywords: words };
}
export function recordingSearchInRange(record: RecordingRecord, plan: RecordingSearchPlan): boolean {
  let created = new Date(record.createdAt);
  if (!Number.isFinite(created.getTime())) { return !plan.startDate && !plan.endDate; }
  let day = recordingSearchDate(created);
  return (!plan.startDate || day >= plan.startDate) && (!plan.endDate || day <= plan.endDate);
}
export function recordingSearchRange(plan: RecordingSearchPlan): string {
  if (plan.startDate && plan.endDate) { return plan.startDate === plan.endDate ? plan.startDate : plan.startDate + ' 至 ' + plan.endDate; }
  return plan.startDate ? plan.startDate + ' 起' : plan.endDate ? '截至 ' + plan.endDate : '全部时间';
}
function summaryParts(summary: RecordingSummary | undefined): string[] {
  if (!summary) { return []; }
  return [summary.title, summary.overview].concat(summary.keyPoints, summary.decisions, summary.actionItems, summary.openQuestions);
}
export function recordingSearchSummary(record: RecordingRecord): string {
  let parts = summaryParts(record.summary);
  for (let section of record.summary?.sections || []) { parts = parts.concat(summaryParts(section.summary)); }
  return parts.filter((part: string): boolean => part.trim().length > 0).join('\n');
}
export function recordingSearchMetadata(record: RecordingRecord, id: string): RecordingSearchMetadata {
  let created = new Date(record.createdAt);
  let summary = recordingSearchSummary(record);
  let available = (record.analysis?.segments || []).some((segment): boolean => segment.text.trim().length > 0);
  return { id: id, title: record.title.slice(0, 100), date: Number.isFinite(created.getTime()) ? recordingSearchDate(created) : '',
    speakers: (record.analysis?.speakers || []).map((speaker): string => speaker.name).slice(0, 12),
    summary: summary.slice(0, 1200), summary_truncated: summary.length > 1200,
    transcript_available: available, transcript_complete: available && record.transcriptionComplete !== false };
}
function snippet(text: string, at: number): string {
  let start = Math.max(0, at - 35), end = Math.min(text.length, at + 180);
  return (start > 0 ? '…' : '') + text.substring(start, end).replace(/\s+/g, ' ').trim() + (end < text.length ? '…' : '');
}
// Literal matching only: no fuzzy expansion, regular expressions or model calls.
// AI callers may explicitly provide several alternative terms; plain search
// passes the user's entire input as a single literal term.
export function searchRecordingKeywords(records: RecordingRecord[], terms: string[], plan?: RecordingSearchPlan): RecordingSearchHit[] {
  let words = terms.map((term: string): string => term.trim().toLowerCase()).filter((term: string): boolean => term.length > 0);
  if (words.length === 0) { return []; }
  let result: RecordingSearchHit[] = [];
  for (let record of records) {
    if (record.capturing || (plan && !recordingSearchInRange(record, plan))) { continue; }
    let score = 0, excerpt = '', start = -1;
    let fields = [record.title, recordingSearchSummary(record)].concat((record.analysis?.speakers || []).map((speaker): string => speaker.name));
    fields.forEach((text: string, index: number) => {
      let lower = text.toLowerCase();
      words.forEach((word: string) => { let at = lower.indexOf(word); if (at >= 0) {
        score += index === 0 ? 4 : 2;
        if (!excerpt) { excerpt = snippet(text, at); }
      } });
    });
    for (let segment of record.analysis?.segments || []) {
      let lower = segment.text.toLowerCase();
      let at = -1;
      words.forEach((word: string) => { let found = lower.indexOf(word); if (found >= 0) { at = at < 0 ? found : Math.min(at, found); } });
      if (at >= 0) {
        score++;
        if (start < 0) { start = segment.start; excerpt = recordingTime(start) + ' · ' + snippet(segment.text, at); }
      }
    }
    if (score > 0) { result.push({ recordId: record.id, snippet: excerpt, reason: '', start: start, score: score }); }
  }
  return result.sort((a: RecordingSearchHit, b: RecordingSearchHit): number => b.score - a.score);
}
export function recordingSearchEvidence(record: RecordingRecord, hit: RecordingSearchHit, id: string, number: number): RecordingSearchEvidence {
  let meta = recordingSearchMetadata(record, id);
  let segments = record.analysis?.segments || [];
  let at = hit.start >= 0 ? segments.findIndex((segment): boolean => segment.start >= hit.start) : 0;
  let excerpts: string[] = [];
  // Preserve the context immediately around a keyword hit. For metadata-only
  // matches use the existing summary plus a bounded start-of-recording excerpt.
  for (let segment of segments.slice(Math.max(0, at - 1), Math.max(0, at - 1) + 4)) {
    if (segment.text.trim()) { excerpts.push(recordingTime(segment.start) + ' ' + segment.text.slice(0, 400)); }
  }
  return { id: meta.id, title: meta.title, date: meta.date, speakers: meta.speakers,
    summary: meta.summary, summary_truncated: meta.summary_truncated, transcript_available: meta.transcript_available,
    transcript_complete: meta.transcript_complete, number: number, excerpts: excerpts };
}
