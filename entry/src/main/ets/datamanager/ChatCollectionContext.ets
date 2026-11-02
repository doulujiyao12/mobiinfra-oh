import { JSON as ArkJSON } from '@kit.ArkTS';
import { ChatCollectionBatch, ChatCollectionEntry, ChatEventAttribution, ChatEventContext, ChatPersonRef, IndexedEvent, JsonMap, createJsonMap } from './DataManagerTypes';
import { memorySceneLabel } from '../utils/WorkflowSceneConfig';

export const CHAT_CONTEXT_POLICY: string = 'chat-collection-context-v2';
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
  private incompleteRestored: Set<string> = new Set<string>();

  add(batchId: string, sourceRef: string, text: string, images: string[], order: number): void {
    if (!batchId || !sourceRef) { return; }
    if (!this.batches[batchId]) { this.batches[batchId] = { batch_id: batchId, entries: [], complete: true }; }
    let batch = this.batches[batchId];
    if (!batch.entries.some((entry: ChatCollectionEntry): boolean => entry.source_ref === sourceRef)) {
      batch.entries.push({ source_ref: sourceRef, text: text, image_paths: images.slice(), order: order });
      this.prepared[batchId] = undefined;
    }
    if (!this.references[sourceRef]) { this.references[sourceRef] = []; }
    if (this.references[sourceRef].indexOf(batchId) < 0) { this.references[sourceRef].push(batchId); }
  }

  all(): ChatCollectionBatch[] {
    return Object.keys(this.batches).sort().map((id: string): ChatCollectionBatch => this.prepare(id));
  }

  // Fill pages belonging to other source files without replacing freshly read
  // evidence. A truncated persisted batch must never become complete on restore.
  restore(batch: ChatCollectionBatch, excludedSources: string[] = []): void {
    let added = false;
    batch.entries.forEach((entry: ChatCollectionEntry) => {
      let source = entry.source_ref.substring(0, entry.source_ref.lastIndexOf('#'));
      if (excludedSources.indexOf(source) >= 0) { return; }
      if ((this.references[entry.source_ref] || []).indexOf(batch.batch_id) >= 0) { return; }
      this.add(batch.batch_id, entry.source_ref, entry.text, entry.image_paths, entry.order);
      added = true;
    });
    if (added && !batch.complete) {
      this.incompleteRestored.add(batch.batch_id);
      this.prepared[batch.batch_id] = undefined;
    }
  }

  private prepare(id: string): ChatCollectionBatch {
      let cached = this.prepared[id];
      if (cached) { return cached; }
      let batch = this.batches[id];
      let entries = batch.entries.slice().sort((a: ChatCollectionEntry, b: ChatCollectionEntry): number => a.order - b.order);
      let total = entries.reduce((count: number, item: ChatCollectionEntry): number => count + item.text.length, 0);
      let complete = !this.incompleteRestored.has(id) && total <= CHAT_BATCH_TEXT_LIMIT && entries.length <= CHAT_BATCH_ENTRY_LIMIT;
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

  forRefs(refs: string[]): ChatEventContext {
    let ids: string[] = [];
    refs.forEach((ref: string) => (this.references[ref] || []).forEach((id: string) => {
      if (ids.indexOf(id) < 0) { ids.push(id); }
    }));
    ids.sort();
    let batches = ids.map((id: string): ChatCollectionBatch => this.prepare(id));
    // Collection logs are append-only and sealed before normal synchronization.
    // Run identity plus entry count detects additional pages without hashing text.
    return { policy: CHAT_CONTEXT_POLICY, batch_ids: ids,
      revision: CHAT_CONTEXT_POLICY + ':' + ids.map((id: string): string =>
        id + ':' + this.batches[id].entries.length).join('|'),
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
  if (!name || name.length > 40 || /^(我|你|用户|本人|未知.*|不明.*|对方|他|她|某人|群友|当前会话|当前群聊|私聊联系人.*|左侧成员\d*.*)$/.test(name)) { return ''; }
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
  return { subjects: [], action_owners: [], user_involved: false, subject: 'unknown', subject_name: '', action_owner: 'unknown', action_owner_name: '',
    status: 'unknown', evidence_source_refs: [] };
}

export function chatSubjects(value: ChatEventAttribution | undefined): ChatPersonRef[] {
  if (!value) { return []; }
  let legacy: ChatPersonRef = { kind: value.subject || 'unknown', name: value.subject_name || '' };
  return value.subjects !== undefined ? value.subjects : [legacy];
}

export function chatActionOwners(value: ChatEventAttribution | undefined): ChatPersonRef[] {
  if (!value) { return []; }
  let legacy: ChatPersonRef = { kind: value.action_owner || 'unknown', name: value.action_owner_name || '' };
  return value.action_owners !== undefined ? value.action_owners : [legacy];
}

export function chatSubjectKinds(value: ChatEventAttribution | undefined): string[] {
  return chatSubjects(value).map((person: ChatPersonRef): string => person.kind);
}

export function chatOtherSubjectNames(value: ChatEventAttribution | undefined): string[] {
  return chatSubjects(value).filter((person: ChatPersonRef): boolean => person.kind === 'other' && person.name.length > 0)
    .map((person: ChatPersonRef): string => person.name);
}

export function chatOtherOwnerNames(value: ChatEventAttribution | undefined): string[] {
  return chatActionOwners(value).filter((person: ChatPersonRef): boolean => person.kind === 'other' && person.name.length > 0)
    .map((person: ChatPersonRef): string => person.name);
}

export function chatHasKnownActionOwners(value: ChatEventAttribution | undefined): boolean {
  let owners = chatActionOwners(value);
  return owners.length > 0 && owners.every((person: ChatPersonRef): boolean =>
    person.kind === 'self' || (person.kind === 'other' && person.name.length > 0));
}

export function chatOnlySelfActionOwners(value: ChatEventAttribution | undefined): boolean {
  let owners = chatActionOwners(value);
  return owners.length > 0 && owners.every((person: ChatPersonRef): boolean => person.kind === 'self');
}

export function chatAttributionFingerprint(value: ChatEventAttribution): string {
  if (value.subjects === undefined && value.action_owners === undefined) {
    return [value.subject, value.subject_name, value.action_owner, value.action_owner_name, value.status].join(':');
  }
  return ArkJSON.stringify([chatSubjects(value), chatActionOwners(value), value.status, value.user_involved]);
}

function normalizeChatPeople(raw: JsonMap, key: string, legacyKind: string, legacyName: string, evidence: string): ChatPersonRef[] {
  let values = raw[key];
  let candidates: JsonMap[] = [];
  if (Array.isArray(values)) {
    if (values.length > 16) { return []; }
    candidates = values as JsonMap[];
  } else {
    let legacy: JsonMap = createJsonMap();
    legacy['kind'] = legacyKind;
    legacy['name'] = legacyName;
    candidates.push(legacy);
  }
  if (candidates.some((person: JsonMap): boolean => !person || typeof person !== 'object' || Array.isArray(person))) { return []; }
  let result: ChatPersonRef[] = [];
  candidates.forEach((person: JsonMap) => {
    let kind = person['kind'];
    let name = typeof person['name'] === 'string' ? person['name'] as string : '';
    name = kind === 'other' ? verifiedChatPersonName(name, evidence) : '';
    let normalizedKind = kind === 'self' ? 'self' : name ? 'other' : 'unknown';
    if (!result.some((item: ChatPersonRef): boolean => item.kind === normalizedKind && item.name === name)) {
      result.push({ kind: normalizedKind, name: name });
    }
  });
  return result;
}

// A genuine unknown judgment is valid. Missing/malformed fields or unverifiable
// citations are response errors, not successful all-unknown classifications.
export function chatAttributionValidationError(raw: JsonMap, event: IndexedEvent, batches: ChatCollectionBatch[]): string {
  let status = raw['status'];
  if (status !== 'pending' && status !== 'resolved' && status !== 'unknown') { return 'status_missing_or_invalid'; }
  if (typeof raw['user_involved'] !== 'boolean') { return 'user_involved_missing'; }
  let refs = raw['evidence_source_refs'];
  if (!Array.isArray(refs) || refs.length === 0) { return 'evidence_refs_missing'; }
  let relevant = chatBatchesForEvents([event], batches);
  let allowed = relevant.reduce((all: string[], batch: ChatCollectionBatch): string[] =>
    all.concat(batch.entries.map((entry: ChatCollectionEntry): string => entry.source_ref)),
    (event.chat_context?.source_refs || event.source_refs).slice());
  if ((refs as string[]).some((ref: string): boolean => typeof ref !== 'string' || allowed.indexOf(ref) < 0)) {
    return 'evidence_ref_outside_collection';
  }
  let attribution = normalizeChatAttribution(raw, event, batches);
  let keys: string[] = ['subjects', 'action_owners'];
  for (let key of keys) {
    let legacyKey = key === 'subjects' ? 'subject' : 'action_owner';
    let people: JsonMap[] = [];
    let values = raw[key];
    if (Array.isArray(values)) {
      if (values.length > 16) { return key + '_too_many'; }
      people = values as JsonMap[];
    } else {
      if (values !== undefined || typeof raw[legacyKey] !== 'string') { return key + '_missing_or_invalid'; }
      let person: JsonMap = createJsonMap();
      person['kind'] = raw[legacyKey]; person['name'] = raw[legacyKey + '_name'] || '';
      people.push(person);
    }
    if (people.some((person: JsonMap): boolean => !person || typeof person !== 'object' || Array.isArray(person) ||
      (person['kind'] !== 'self' && person['kind'] !== 'other' && person['kind'] !== 'unknown') ||
      (person['kind'] === 'other' && (typeof person['name'] !== 'string' || !(person['name'] as string).trim())))) {
      return key + '_invalid_person';
    }
    let normalized = key === 'subjects' ? chatSubjects(attribution) : chatActionOwners(attribution);
    if (people.some((person: JsonMap): boolean => person['kind'] === 'other' &&
      !normalized.some((item: ChatPersonRef): boolean => item.kind === 'other' && item.name === (person['name'] as string).trim()))) {
      return key + '_name_not_in_evidence';
    }
  }
  if (status === 'pending' && (!chatHasKnownActionOwners(attribution) || chatSubjects(attribution).length === 0)) {
    return 'pending_people_unidentified';
  }
  return '';
}

export function normalizeChatAttribution(raw: JsonMap, event: IndexedEvent, batches: ChatCollectionBatch[]): ChatEventAttribution {
  let result = emptyChatAttribution();
  let relevant = chatBatchesForEvents([event], batches);
  let refs = relevant.reduce((all: string[], batch: ChatCollectionBatch): string[] =>
    all.concat(batch.entries.map((entry: ChatCollectionEntry): string => entry.source_ref)),
    (event.chat_context?.source_refs || event.source_refs).slice());
  if (!Array.isArray(raw['evidence_source_refs'])) { return result; }
  if ((raw['evidence_source_refs'] as string[]).some((ref: string): boolean =>
    typeof ref !== 'string' || refs.indexOf(ref) < 0)) { return result; }
  result.evidence_source_refs = (raw['evidence_source_refs'] as string[])
    .filter((ref: string): boolean => typeof ref === 'string' && refs.indexOf(ref) >= 0);
  if (result.evidence_source_refs.length === 0) { return result; }
  let evidence = event.summary + '\n' + event.normalized_fact + '\n' + relevant.map((batch: ChatCollectionBatch): string =>
    batch.entries.filter((entry: ChatCollectionEntry): boolean => result.evidence_source_refs.indexOf(entry.source_ref) >= 0)
      .map((entry: ChatCollectionEntry): string => entry.text).join('\n')).join('\n');
  let subject = typeof raw['subject'] === 'string' ? raw['subject'] as string : 'unknown';
  let owner = typeof raw['action_owner'] === 'string' ? raw['action_owner'] as string : 'unknown';
  let subjectName = typeof raw['subject_name'] === 'string' ? raw['subject_name'] as string : '';
  let ownerName = typeof raw['action_owner_name'] === 'string' ? raw['action_owner_name'] as string : '';
  let subjects = normalizeChatPeople(raw, 'subjects', subject, subjectName, evidence);
  let owners = normalizeChatPeople(raw, 'action_owners', owner, ownerName, evidence);
  result.subjects = subjects;
  result.action_owners = owners;
  result.subject = subjects.length === 1 ? subjects[0].kind : 'unknown';
  result.subject_name = subjects.length === 1 ? subjects[0].name : '';
  result.action_owner = owners.length === 1 ? owners[0].kind : 'unknown';
  result.action_owner_name = owners.length === 1 ? owners[0].name : '';
  result.user_involved = owners.some((person: ChatPersonRef): boolean => person.kind === 'self') || raw['user_involved'] === true;
  let status = raw['status'];
  result.status = status === 'resolved' ? 'resolved' : status === 'pending' && result.user_involved && chatHasKnownActionOwners(result) && event.chat_context?.complete === true &&
    relevant.length === 1 && relevant.every((batch: ChatCollectionBatch): boolean => batch.complete) ? 'pending' : 'unknown';
  return result;
}
