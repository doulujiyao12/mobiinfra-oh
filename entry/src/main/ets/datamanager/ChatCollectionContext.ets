import { JSON as ArkJSON } from '@kit.ArkTS';
import { ChatCollectionBatch, ChatCollectionEntry, ChatEventAttribution, ChatEventContext, IndexedEvent, JsonMap } from './DataManagerTypes';
import { memorySceneLabel } from '../utils/WorkflowSceneConfig';

export const CHAT_CONTEXT_POLICY: string = 'chat-collection-context-v1';
const CHAT_BATCH_TEXT_LIMIT: number = 48000;
const CHAT_BATCH_ENTRY_LIMIT: number = 160;

export function isChatCollectionEvent(event: IndexedEvent): boolean {
  return !/(^|\/)app-chat__(local|cloud)__/.test(event.source_state_file) &&
    (event.workflow_scene_ids || []).some((id: number): boolean => memorySceneLabel(id) === '聊天');
}

// Batch IDs are collection identities, never dates or contact display names.
// Separate persisted documents avoid duplicating an entire conversation in every event.
export class ChatCollectionContextIndex {
  private batches: Record<string, ChatCollectionBatch> = {};
  private references: Record<string, string[]> = {};
  private prepared: Record<string, ChatCollectionBatch | undefined> = {};
  private fingerprints: Record<string, string> = {};

  add(batchId: string, sourceRef: string, text: string, images: string[], order: number): void {
    if (!batchId || !sourceRef) { return; }
    if (!this.batches[batchId]) { this.batches[batchId] = { batch_id: batchId, entries: [], complete: true }; }
    let batch = this.batches[batchId];
    if (!batch.entries.some((entry: ChatCollectionEntry): boolean => entry.source_ref === sourceRef)) {
      batch.entries.push({ source_ref: sourceRef, text: text, image_paths: images.slice(), order: order });
      this.prepared[batchId] = undefined;
      this.fingerprints[batchId] = '';
    }
    if (!this.references[sourceRef]) { this.references[sourceRef] = []; }
    if (this.references[sourceRef].indexOf(batchId) < 0) { this.references[sourceRef].push(batchId); }
  }

  all(): ChatCollectionBatch[] {
    return Object.keys(this.batches).sort().map((id: string): ChatCollectionBatch => this.prepare(id));
  }

  private prepare(id: string): ChatCollectionBatch {
      let cached = this.prepared[id];
      if (cached) { return cached; }
      let batch = this.batches[id];
      let entries = batch.entries.slice().sort((a: ChatCollectionEntry, b: ChatCollectionEntry): number => a.order - b.order);
      let total = entries.reduce((count: number, item: ChatCollectionEntry): number => count + item.text.length, 0);
      let complete = total <= CHAT_BATCH_TEXT_LIMIT && entries.length <= CHAT_BATCH_ENTRY_LIMIT;
      if (entries.length > CHAT_BATCH_ENTRY_LIMIT) {
        entries = entries.slice(0, CHAT_BATCH_ENTRY_LIMIT / 2).concat(entries.slice(-CHAT_BATCH_ENTRY_LIMIT / 2));
      }
      // Preserve both ends of each page when a large batch exceeds the budget.
      // Incomplete context is explicit and cannot establish a pending reminder.
      let perEntry = Math.max(0, Math.floor(CHAT_BATCH_TEXT_LIMIT / Math.max(1, entries.length)));
      let result: ChatCollectionBatch = { batch_id: id, complete: complete, entries: entries.map((entry: ChatCollectionEntry): ChatCollectionEntry => {
        let text = entry.text;
        if (!complete && text.length > perEntry) {
          let half = Math.max(0, Math.floor((perEntry - 12) / 2));
          text = text.substring(0, half) + '\n[中间内容省略]\n' + text.substring(text.length - half);
        }
        return { source_ref: entry.source_ref, text: text, image_paths: entry.image_paths.slice(), order: entry.order };
      }) };
      this.prepared[id] = result;
      return result;
  }

  forRefs(refs: string[], hash: (text: string) => string): ChatEventContext {
    let ids: string[] = [];
    refs.forEach((ref: string) => (this.references[ref] || []).forEach((id: string) => {
      if (ids.indexOf(id) < 0) { ids.push(id); }
    }));
    ids.sort();
    let batches = ids.map((id: string): ChatCollectionBatch => this.prepare(id));
    let hashes = ids.map((id: string): string => {
      if (!this.fingerprints[id]) { this.fingerprints[id] = hash(ArkJSON.stringify(this.prepare(id))); }
      return this.fingerprints[id];
    });
    return { policy: CHAT_CONTEXT_POLICY, batch_ids: ids,
      input_hash: hash(CHAT_CONTEXT_POLICY + ':' + ids.join('|') + ':' + hashes.join('|')),
      complete: ids.length === 1 && refs.length > 0 && refs.every((ref: string): boolean => (this.references[ref] || []).length === 1) &&
        batches.length > 0 && batches.every((batch: ChatCollectionBatch): boolean => batch.complete) };
  }
}

export function chatBatchesForEvents(events: IndexedEvent[], batches: ChatCollectionBatch[]): ChatCollectionBatch[] {
  let ids: string[] = [];
  events.forEach((event: IndexedEvent) => {
    if (event.chat_context) { ids = ids.concat(event.chat_context.batch_ids); }
  });
  return batches.filter((batch: ChatCollectionBatch): boolean => ids.indexOf(batch.batch_id) >= 0);
}

export function chatEvidenceText(event: IndexedEvent, batches: ChatCollectionBatch[]): string {
  return event.summary + '\n' + event.normalized_fact + '\n' +
    chatBatchesForEvents([event], batches).map((batch: ChatCollectionBatch): string =>
      batch.entries.map((entry: ChatCollectionEntry): string => entry.text).join('\n')).join('\n');
}

export function verifiedChatPersonName(value: string, evidence: string): string {
  let name = value.trim().replace(/[\r\n\t]/g, '');
  if (!name || name.length > 40 || /^(我|你|用户|本人|未知.*|不明.*|对方|他|她|某人|群友)$/.test(name)) { return ''; }
  return evidence.indexOf(name) >= 0 ? name : '';
}

export function chatPersonTitle(title: string, names: string[]): string {
  let unique: string[] = [];
  names.forEach((name: string) => { if (name && unique.indexOf(name) < 0) { unique.push(name); } });
  if (unique.length === 0) { return title; }
  let prefix = unique.join('、');
  return title.startsWith(prefix + '：') ? title : prefix + '：' + title;
}

export function emptyChatAttribution(): ChatEventAttribution {
  return { user_involved: false, subject: 'unknown', subject_name: '', action_owner: 'unknown', action_owner_name: '',
    status: 'unknown', evidence_source_refs: [] };
}

export function normalizeChatAttribution(raw: JsonMap, event: IndexedEvent, batches: ChatCollectionBatch[]): ChatEventAttribution {
  let result = emptyChatAttribution();
  let relevant = chatBatchesForEvents([event], batches);
  let refs = relevant.reduce((all: string[], batch: ChatCollectionBatch): string[] =>
    all.concat(batch.entries.map((entry: ChatCollectionEntry): string => entry.source_ref)), event.source_refs.slice());
  if (!Array.isArray(raw['evidence_source_refs'])) { return result; }
  if ((raw['evidence_source_refs'] as string[]).some((ref: string): boolean =>
    typeof ref !== 'string' || refs.indexOf(ref) < 0)) { return result; }
  result.evidence_source_refs = (raw['evidence_source_refs'] as string[])
    .filter((ref: string): boolean => typeof ref === 'string' && refs.indexOf(ref) >= 0);
  if (result.evidence_source_refs.length === 0) { return result; }
  let evidence = chatEvidenceText(event, relevant);
  let subject = typeof raw['subject'] === 'string' ? raw['subject'] as string : 'unknown';
  let owner = typeof raw['action_owner'] === 'string' ? raw['action_owner'] as string : 'unknown';
  let subjectName = typeof raw['subject_name'] === 'string' ? raw['subject_name'] as string : '';
  let ownerName = typeof raw['action_owner_name'] === 'string' ? raw['action_owner_name'] as string : '';
  result.subject_name = subject === 'other' ? verifiedChatPersonName(subjectName, evidence) : '';
  result.subject = subject === 'self' ? 'self' : result.subject_name ? 'other' : 'unknown';
  result.action_owner_name = owner === 'other' ? verifiedChatPersonName(ownerName, evidence) : '';
  result.action_owner = owner === 'self' ? 'self' : result.action_owner_name ? 'other' : 'unknown';
  result.user_involved = result.action_owner === 'self' || raw['user_involved'] === true;
  let status = raw['status'];
  result.status = status === 'resolved' ? 'resolved' : status === 'pending' && result.user_involved && event.chat_context?.complete === true &&
    relevant.length === 1 && relevant.every((batch: ChatCollectionBatch): boolean => batch.complete) ? 'pending' : 'unknown';
  return result;
}
