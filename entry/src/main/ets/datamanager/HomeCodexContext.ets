import { ChatCollectionEntry, IndexedEvent, StringArrayMap } from './DataManagerTypes';
import { buildHomeCodexBrief, HomeCodexPage } from './HomeCodexBrief';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { IndexService } from './IndexService';
import { parseDailyLogDocument, parseNumberedEntries, stableUnique } from './DataManagerUtils';
import { SyncWorkSlice } from './SyncWorkSlice';
import { collectionChatName } from './CollectionChatIdentity';

export interface HomeCodexEvidence {
  label: string;
  summary: string;
  eventId?: string;
  profileDomain?: string;
}

export interface HomeCodexRequest {
  kind: string;
  id: string;
  title: string;
  description: string;
  goal: string;
  eventIds: string[];
  evidence: HomeCodexEvidence[];
  imageRefs?: string[];
  userGoal?: string;
}

export interface HomeCodexContext {
  title: string;
  prompt: string;
  message: string;
  imageRefs: string[];
  suppliedEventIds?: string[];
}

export function isHomeCodexExcludedId(id: string): boolean { return /^(calendar|mail):/.test(id); }

export function homeCodexImageLabel(ref: string): string {
  return ref.startsWith('data:') || ref.length > 512 ? '内嵌图片（通过附件传递）' : ref;
}

function pageConversations(text: string): string[] {
  let names: string[] = [];
  let pattern = /(?:聊天对象|会话名称|会话标题|联系人)\s*[:：]\s*([^｜|\n，。；;]{1,60})/g;
  let match = pattern.exec(text);
  while (match !== null) {
    let name = collectionChatName(match[1]);
    if (name && names.indexOf(name) < 0) { names.push(name); }
    match = pattern.exec(text);
  }
  return names;
}

function sourceFile(ref: string): string { return ref.replace(/#\d+$/, ''); }

// Read only the selected card's evidence. Never search arbitrary files using
// model-generated prose, and never interpret record-N as a current event index.
export class HomeCodexContextService {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private index: IndexService;
  constructor(paths: DataManagerPaths, storage: DataManagerStorage, index: IndexService) {
    this.paths = paths; this.storage = storage; this.index = index;
  }

  async prepare(request: HomeCodexRequest): Promise<HomeCodexContext> {
    if (isHomeCodexExcludedId(request.id) || (request.kind === 'reminder' && request.eventIds.length > 0 &&
      request.eventIds.every(isHomeCodexExcludedId))) { throw new Error('日历和邮箱提醒暂不支持交给 Codex'); }
    let work = new SyncWorkSlice();
    await work.checkpoint();
    let notes: string[] = [];
    let ids = stableUnique(request.eventIds.concat(request.evidence.map((item: HomeCodexEvidence): string => item.eventId || '')))
      .filter((id: string): boolean => id.length > 0 && !isHomeCodexExcludedId(id));
    // A profile is a synthesized interest, not a request to disclose its whole
    // history. Keep the selected profile excerpt; raw records use exact IDs.
    let map = this.index.loadEventsByIds(ids.slice(0, 24));
    let events: IndexedEvent[] = ids.slice(0, 24).map((id: string): IndexedEvent => map[id])
      .filter((event: IndexedEvent): boolean => !!event && !event.calendar && !isHomeCodexExcludedId(event.event_id));
    if (request.kind === 'reminder' && Object.keys(map).length > 0 && events.length === 0) {
      throw new Error('日历和邮箱提醒暂不支持交给 Codex');
    }
    if (ids.length > 24) { notes.push('关联事件超过 24 条，本次仅附前 24 条。'); }
    if (events.length < Math.min(ids.length, 24)) { notes.push('部分关联事件已删除或不可读取，未猜测补充。'); }
    let originals: HomeCodexPage[] = [];
    let seen = new Set<string>();
    let add = (ref: string, batch: string, text: string, images: string[], distance: number): void => {
      if (seen.has(ref)) { return; }
      seen.add(ref);
      originals.push({ ref: ref, batch: batch, text: text, images: images,
        direct: directRefs.has(ref), distance: distance });
    };
    let directRefs = new Set<string>();
    for (let event of events) { (event.source_refs || []).forEach((ref: string): void => { directRefs.add(ref); }); }
    let batches = this.index.loadChatContextBatches(events);
    let conversations = new Map<string, string[]>();
    let namedFiles = new Set<string>();
    for (let batch of batches) {
      let names: string[] = [];
      for (let entry of batch.entries) {
        if (!directRefs.has(entry.source_ref)) { continue; }
        names = stableUnique(names.concat(pageConversations(entry.text)));
        // Named collection files also identify the conversation when older
        // page text has no header. Generic chat.md alone cannot establish it.
        if (/__(?!wechat_auto_summary__)[^/]+__[^/]+\.md$/.test(sourceFile(entry.source_ref))) {
          namedFiles.add(sourceFile(entry.source_ref));
        }
      }
      conversations.set(batch.batch_id, names);
    }
    // Linked pages first; then later replies from the same collection. This
    // retains answers/cancellations without pulling unrelated conversations.
    for (let direct of [true, false]) {
      for (let batch of batches) {
        await work.checkpoint();
        if (!batch.complete) { notes.push('某次聊天采集不完整，不能据此断定完整对话。'); }
        for (let entryIndex = 0; entryIndex < batch.entries.length; entryIndex++) {
          let entry = batch.entries[entryIndex];
          if (directRefs.has(entry.source_ref) === direct) {
            let distance = 0;
            if (!direct) {
              distance = batch.entries.reduce((closest: number, candidate: ChatCollectionEntry, index: number): number =>
                directRefs.has(candidate.source_ref) ? Math.min(closest, Math.abs(index - entryIndex)) : closest, batch.entries.length);
              // Shared conversation identity is necessary, but does not make
              // an entire collection relevant to this particular task.
              if (distance > 2) { continue; }
              let names = pageConversations(entry.text);
              let allowed = conversations.get(batch.batch_id) || [];
              if (!(names.length > 0 && names.every((name: string): boolean => allowed.indexOf(name) >= 0)) &&
                !(names.length === 0 && namedFiles.has(sourceFile(entry.source_ref)))) {
                notes.push('同批次中无法确认属于当前会话的页面未附带。');
                continue;
              }
            }
            add(entry.source_ref, batch.batch_id, entry.text, entry.image_paths, distance);
          }
        }
      }
    }
    let pending: StringArrayMap = {};
    for (let event of events) {
      await work.checkpoint();
      for (let ref of event.source_refs || []) {
        if (seen.has(ref)) { continue; }
        let match = /^(\d{4}-\d{2}-\d{2}\/[^/\\]+\.md)#(\d+)$/.exec(ref);
        if (!match) { continue; }
        if (!pending[match[1]]) { pending[match[1]] = []; }
        pending[match[1]].push(ref);
      }
    }
    for (let relative of Object.keys(pending)) {
      await work.checkpoint();
      let text = this.storage.readText(this.storage.join(this.paths.dailyLogRoot, relative), '');
      let wanted = new Set<string>(pending[relative]);
      for (let entry of parseNumberedEntries(parseDailyLogDocument(text).body)) {
        let ref = relative + '#' + entry.index;
        if (wanted.has(ref)) { add(ref, '', entry.text, [], 0); }
      }
    }
    if (directRefs.size > 0 && Array.from(directRefs).some((ref: string): boolean => !seen.has(ref))) {
      notes.push('部分原始记录不可用，仅附可核验的索引事实与卡片依据。');
    }
    if (originals.length === 0) { notes.push('未找到可读取的原始页面；以下卡片和画像是整理结果，不冒充原文。'); }
    let brief = buildHomeCodexBrief(request, events, originals, stableUnique(notes));
    return { title: request.title, imageRefs: brief.imageRefs, prompt: brief.prompt, message: brief.message,
      suppliedEventIds: brief.suppliedEventIds };
  }
}
