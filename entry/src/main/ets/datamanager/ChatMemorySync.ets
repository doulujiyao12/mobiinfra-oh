import { JSON as ArkJSON } from '@kit.ArkTS';
import { ChatSessionIndex, ChatSessionRecord, CHAT_MODE_LOCAL_INFERENCE } from '../pages/chat/ChatSessionTypes';
import { ChatSessionStorage } from '../utils/ChatSessionStorage';
import { memorySceneLabel } from '../utils/WorkflowSceneConfig';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { DataPipelineModelClient } from './DataPipelineModelClient';
import {
  DataManagerModelConfig, DataManagerProgressCallback, JsonMap, createDataManagerProgress, createJsonMap
} from './DataManagerTypes';
import {
  ChatMemoryFact, ChatMemoryInput, ChatMemoryResult, CHAT_MEMORY_WINDOW_MS,
  chatMemoryBatches, pendingChatMemoryInputs
} from './ChatMemoryExtraction';

interface ChatMemoryReceipt {
  source_ref: string;
  source_date: string;
  mode: string;
  facts: ChatMemoryFact[];
}

interface ChatMemoryState {
  version: number;
  receipts: ChatMemoryReceipt[];
}

interface ChatMemoryExport {
  relativePath: string;
  sceneId: number;
  entries: string[];
}

export interface ChatMemorySyncSummary {
  processedParts: number;
  factCount: number;
}

export class ChatMemorySync {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private modelClient: DataPipelineModelClient;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage, modelClient: DataPipelineModelClient) {
    this.paths = paths;
    this.storage = storage;
    this.modelClient = modelClient;
  }

  private static statePath(dailyLogRoot: string, storage: DataManagerStorage): string {
    return storage.join(storage.dirname(dailyLogRoot), 'chat-memory', 'state.json');
  }

  private static readState(dailyLogRoot: string, storage: DataManagerStorage): ChatMemoryState {
    let path = ChatMemorySync.statePath(dailyLogRoot, storage);
    if (!storage.exists(path)) {
      return { version: 1, receipts: [] };
    }
    // Do not fall back to an empty checkpoint on corruption: that would re-import the same messages.
    let state = ArkJSON.parse(storage.readText(path)) as ChatMemoryState;
    if (!state || state.version !== 1 || !Array.isArray(state.receipts)) {
      throw new Error('聊天同步记录无法读取');
    }
    return state;
  }

  private loadSessions(now: number): ChatSessionRecord[] {
    let emptyIndex: ChatSessionIndex = { sessions: [] };
    let index = this.storage.readJson<ChatSessionIndex>(ChatSessionStorage.indexPath(this.paths.filesDir), emptyIndex);
    let ids = new Set<string>();
    let oldIds = new Set<string>();
    let summaries = index && Array.isArray(index.sessions) ? index.sessions : [];
    for (let summary of summaries) {
      if (summary.updatedAt < now - CHAT_MEMORY_WINDOW_MS) {
        oldIds.add(summary.id);
      } else {
        ids.add(summary.id);
      }
    }
    // Also recover sessions missing from the index, without mutating chat history during a sync.
    this.storage.listDir(ChatSessionStorage.sessionsDir(this.paths.filesDir)).forEach((name: string) => {
      if (name.endsWith('.json') && !oldIds.has(name.substring(0, name.length - 5))) {
        ids.add(name.substring(0, name.length - 5));
      }
    });
    let sessions: ChatSessionRecord[] = [];
    ids.forEach((id: string) => {
      let session = this.storage.readJson<ChatSessionRecord | null>(
        ChatSessionStorage.sessionPath(this.paths.filesDir, id), null);
      if (session && session.id === id && Array.isArray(session.messages)) {
        sessions.push(session);
      }
    });
    return sessions;
  }

  hasDataToSync(now: number = Date.now()): boolean {
    let state = ChatMemorySync.readState(this.paths.dailyLogRoot, this.storage);
    return state.receipts.some((receipt: ChatMemoryReceipt): boolean => receipt.facts.length > 0) ||
      this.pendingInputs(state, now).length > 0;
  }

  private pendingInputs(state: ChatMemoryState, now: number): ChatMemoryInput[] {
    return pendingChatMemoryInputs(this.loadSessions(now),
      state.receipts.map((receipt: ChatMemoryReceipt): string => receipt.source_ref), now);
  }

  async sync(config: DataManagerModelConfig, progress?: DataManagerProgressCallback,
    now: number = Date.now()): Promise<ChatMemorySyncSummary> {
    let state = ChatMemorySync.readState(this.paths.dailyLogRoot, this.storage);
    // Export committed results first, including when a previous run failed after checkpointing or has aged out.
    this.exportLogs(state);
    let pending = this.pendingInputs(state, now);
    let processedParts = 0;
    let factCount = 0;
    for (let batch of chatMemoryBatches(pending)) {
      if (progress) {
        progress(createDataManagerProgress('聊天同步', `正在提取近 7 天聊天信息 ${processedParts}/${pending.length}`,
          processedParts, pending.length, 3));
      }
      let results: ChatMemoryResult[] = await this.modelClient.extractChatMemory(batch, config);
      for (let input of batch) {
        let result = results.find((item: ChatMemoryResult): boolean => item.source_ref === input.source_ref);
        if (!result) {
          throw new Error('聊天信息提取结果遗漏消息');
        }
        state.receipts.push({
          source_ref: input.source_ref, source_date: input.source_date, mode: input.mode, facts: result.facts
        });
        factCount += result.facts.length;
      }
      // Facts and processing receipts commit together. Empty facts are successful checks too.
      this.storage.writeJsonAtomic(ChatMemorySync.statePath(this.paths.dailyLogRoot, this.storage), state as Object);
      processedParts += batch.length;
    }
    this.exportLogs(state);
    return { processedParts: processedParts, factCount: factCount };
  }

  static dailyLogRelativePaths(dailyLogRoot: string, storage: DataManagerStorage): string[] {
    return ChatMemorySync.exports(ChatMemorySync.readState(dailyLogRoot, storage))
      .map((item: ChatMemoryExport): string => item.relativePath);
  }

  private static exports(state: ChatMemoryState): ChatMemoryExport[] {
    let groups = new Map<string, ChatMemoryExport>();
    for (let receipt of state.receipts) {
      let mode = receipt.mode === CHAT_MODE_LOCAL_INFERENCE ? 'local' : 'cloud';
      for (let fact of receipt.facts) {
        let path = receipt.source_date + '/app-chat__' + mode + '__' + String(fact.scene_id) + '.md';
        let group = groups.get(path);
        if (!group) {
          group = { relativePath: path, sceneId: fact.scene_id, entries: [] };
          groups.set(path, group);
        }
        // Append order is persisted, so adding older messages cannot renumber existing source_refs.
        group.entries.push(fact.text.replace(/\s+/g, ' ').trim());
      }
    }
    let exports: ChatMemoryExport[] = [];
    groups.forEach((group: ChatMemoryExport) => exports.push(group));
    return exports;
  }

  private exportLogs(state: ChatMemoryState): void {
    for (let group of ChatMemorySync.exports(state)) {
      let workflowMetadata: JsonMap = createJsonMap();
      workflowMetadata['task_scene_id'] = group.sceneId;
      workflowMetadata['source_kind'] = 'app_chat';
      let metadata: JsonMap = createJsonMap();
      metadata['workflow_metadata'] = workflowMetadata;
      metadata['latest_entry_index'] = group.entries.length;
      let lines: string[] = ['<!-- DAILY_LOG_METADATA', ArkJSON.stringify(metadata), '-->', '',
        '# 聊天足迹 / ' + memorySceneLabel(group.sceneId), ''];
      group.entries.forEach((entry: string, index: number) => {
        lines.push(String(index + 1) + '. ' + entry, '');
      });
      let path = this.storage.join(this.paths.dailyLogRoot, group.relativePath);
      let content = lines.join('\n');
      if (this.storage.readText(path) !== content) {
        this.storage.writeTextAtomic(path, content);
      }
    }
  }
}
