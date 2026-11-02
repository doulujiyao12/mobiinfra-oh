import { AggregatedRecord, CandidateFact, SourceEntry, StringMap } from './DataManagerTypes';
import { indexTerms, isIsoDate, normalizeLookupText, stableUnique } from './DataManagerUtils';

export const CHAT_DEDUP_LOOKBACK_DAYS: number = 2;
export const CHAT_DEDUP_LOCAL_LIMIT: number = 20;
export const CHAT_DEDUP_MODEL_LIMIT: number = 3;

export interface ChatFactDedupSelection {
  exact: AggregatedRecord | null;
  candidates: AggregatedRecord[];
  inspected: number;
}

interface ScoredChatRecord { record: AggregatedRecord; score: number; }

export function isExternalChatEntry(entry: SourceEntry): boolean {
  return entry.workflow_scene_id === 3 && !/^app-chat__(local|cloud)__/.test(entry.file_name);
}

export function isSameChatCollection(record: AggregatedRecord, entry: SourceEntry, batches: StringMap): boolean {
  return record.source_refs.some((ref: string): boolean => ref === entry.source_ref ||
    !!entry.collection_batch_id && batches[ref] === entry.collection_batch_id);
}

function sourceOrder(ref: string): string {
  let index = Number(ref.substring(ref.lastIndexOf('#') + 1));
  return ref.substring(0, 10) + ':' + ('000000000000' + (Number.isFinite(index) ? index : 0)).slice(-12);
}

function latestSource(record: AggregatedRecord): string {
  let latest = '';
  record.source_refs.forEach((ref: string) => { if (!latest || sourceOrder(ref) > sourceOrder(latest)) { latest = ref; } });
  return latest;
}

// Preserve all provenance, while interpretation continues to use one collection.
export function updateChatContextSources(record: AggregatedRecord, batches: StringMap): void {
  let latest = latestSource(record);
  let batch = batches[latest] || '';
  record.chat_context_source_refs = batch ? record.source_refs.filter((ref: string): boolean => batches[ref] === batch) :
    latest ? [latest] : [];
}

function numbersCompatible(left: string, right: string): boolean {
  let a = stableUnique(left.match(/\d+(?:[.:\/-]\d+)*/g) || []);
  let b = stableUnique(right.match(/\d+(?:[.:\/-]\d+)*/g) || []);
  return a.length === 0 || b.length === 0 || a.every((value: string): boolean => b.indexOf(value) >= 0) ||
    b.every((value: string): boolean => a.indexOf(value) >= 0);
}

function similarity(left: string, right: string): number {
  let a = indexTerms(left);
  let b = new Set<string>(indexTerms(right));
  if (a.length < 6 || b.size < 6) { return 0; }
  let shared = a.filter((term: string): boolean => b.has(term)).length;
  let score = 2 * shared / (a.length + b.size);
  return shared >= 5 && score >= 0.72 ? score : 0;
}

// Built once from the already-loaded month/source state. No file reads or raw
// text hashes. Every day retains at most 20 recent facts, regardless of history.
export class ChatFactDedupWindow {
  private days: Map<string, AggregatedRecord[]> = new Map<string, AggregatedRecord[]>();
  private recordDays: Map<number, string> = new Map<number, string>();
  private order: Map<number, string> = new Map<number, string>();

  constructor(records: AggregatedRecord[]) {
    records.forEach((record: AggregatedRecord) => this.remember(record));
  }

  remember(record: AggregatedRecord): void {
    if ((record.workflow_scene_ids || []).indexOf(3) < 0 || !isIsoDate(record.last_seen_date)) { return; }
    let previousDay = this.recordDays.get(record.record_id);
    if (previousDay) {
      this.days.set(previousDay, (this.days.get(previousDay) || []).filter((item: AggregatedRecord): boolean => item.record_id !== record.record_id));
    }
    let day = record.last_seen_date;
    this.recordDays.set(record.record_id, day);
    this.order.set(record.record_id, sourceOrder(latestSource(record)));
    let bucket = (this.days.get(day) || []).concat([record]);
    bucket.sort((a: AggregatedRecord, b: AggregatedRecord): number =>
      (this.order.get(b.record_id) || '').localeCompare(this.order.get(a.record_id) || '') || b.record_id - a.record_id);
    bucket.slice(CHAT_DEDUP_LOCAL_LIMIT).forEach((item: AggregatedRecord) => {
      this.recordDays.delete(item.record_id); this.order.delete(item.record_id);
    });
    this.days.set(day, bucket.slice(0, CHAT_DEDUP_LOCAL_LIMIT));
  }

  select(fact: CandidateFact, entry: SourceEntry, batches: StringMap): ChatFactDedupSelection {
    let result: ChatFactDedupSelection = { exact: null, candidates: [], inspected: 0 };
    if (!isIsoDate(fact.source_date)) { return result; }
    // These are calendar date keys, not instants in the device time zone.
    let dayTime = new Date(fact.source_date + 'T00:00:00Z').getTime();
    if (!Number.isFinite(dayTime)) { return result; }
    let recent: AggregatedRecord[] = [];
    for (let offset = 0; offset <= CHAT_DEDUP_LOOKBACK_DAYS && recent.length < CHAT_DEDUP_LOCAL_LIMIT; offset++) {
      let day = new Date(dayTime - offset * 86400000).toISOString().substring(0, 10);
      recent = recent.concat(this.days.get(day) || []).slice(0, CHAT_DEDUP_LOCAL_LIMIT);
    }
    result.inspected = recent.length;
    let key = normalizeLookupText(fact.normalized_fact);
    let raw = normalizeLookupText(fact.raw_excerpt);
    let scored: ScoredChatRecord[] = [];
    recent.forEach((record: AggregatedRecord) => {
      if (!numbersCompatible(fact.normalized_fact, record.normalized_fact)) { return; }
      let sameCollection = isSameChatCollection(record, entry, batches);
      let existingKey = normalizeLookupText(record.normalized_fact);
      let exactText = key.length > 0 && key === existingKey;
      // Different collection dates alone cannot prove the messages are the
      // same occurrence. Exact long source text can establish a repeated page.
      let repeatedPage = raw.length >= 20 && record.raw_excerpts.some((excerpt: string): boolean => normalizeLookupText(excerpt) === raw);
      let sameOccurrence = sameCollection || (key.length >= 12 && fact.event_date === record.first_seen_date) || repeatedPage;
      if (exactText && sameOccurrence && result.exact === null) { result.exact = record; }
      let score = exactText && key.length >= 12 ? 1 : similarity(fact.normalized_fact, record.normalized_fact);
      if (score > 0) { scored.push({ record: record, score: score }); }
    });
    scored.sort((a: ScoredChatRecord, b: ScoredChatRecord): number => b.score - a.score);
    result.candidates = scored.slice(0, CHAT_DEDUP_MODEL_LIMIT).map((item: ScoredChatRecord): AggregatedRecord => item.record);
    return result;
  }
}
