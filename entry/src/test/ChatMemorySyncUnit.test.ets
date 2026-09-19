import { describe, it, expect } from '@ohos/hypium';
import {
  CHAT_MEMORY_PART_CHARS, CHAT_MEMORY_WINDOW_MS, ChatMemoryInput, ChatMemoryResult,
  buildChatMemoryPrompt, chatMemoryBatches, parseChatMemoryResults, pendingChatMemoryInputs
} from '../main/ets/datamanager/ChatMemoryExtraction';
import { ChatMemorySync } from '../main/ets/datamanager/ChatMemorySync';
import { DataManagerFacade } from '../main/ets/datamanager/DataManagerFacade';
import { collectionTabSpecByIndex } from '../main/ets/datamanager/CollectionGroupingService';
import { DataManagerPaths } from '../main/ets/datamanager/DataManagerPaths';
import { DataManagerStorage } from '../main/ets/datamanager/DataManagerStorage';
import { DataPipelineModelClient } from '../main/ets/datamanager/DataPipelineModelClient';
import { DataManagerModelConfig, JsonMap } from '../main/ets/datamanager/DataManagerTypes';
import {
  parseDailyLogDocument, parseNumberedEntries, sourceAppDisplayName, sourceDisplayName
} from '../main/ets/datamanager/DataManagerUtils';
import { ChatSessionStorage } from '../main/ets/utils/ChatSessionStorage';
import {
  CHAT_MODE_CLOUD_AGENT, CHAT_MODE_LOCAL_INFERENCE, ChatSessionRecord, createChatMessage, createEmptyChatSession
} from '../main/ets/pages/chat/ChatSessionTypes';

const NOW: number = new Date(2026, 8, 17, 12).getTime();
const CONFIG: DataManagerModelConfig = { enabled: false, baseUrl: '', apiKey: '' };

class ChatMemoryTestStorage extends DataManagerStorage {
  files: Record<string, string> = {};
  failExport: boolean = false;

  exists(path: string): boolean {
    return this.files[path] !== undefined;
  }

  readText(path: string, fallback: string = ''): string {
    return this.files[path] === undefined ? fallback : this.files[path];
  }

  writeTextAtomic(path: string, content: string): void {
    if (this.failExport && path.indexOf('/daily-log/') >= 0) {
      throw new Error('simulated export failure');
    }
    this.files[path] = content;
  }

  listDir(path: string): string[] {
    let names = new Set<string>();
    Object.keys(this.files).forEach((name: string) => {
      if (name.startsWith(path + '/')) {
        names.add(name.substring(path.length + 1).split('/')[0]);
      }
    });
    let result: string[] = [];
    names.forEach((name: string) => result.push(name));
    return result.sort();
  }
}

class ChatMemoryTestModel extends DataPipelineModelClient {
  calls: ChatMemoryInput[][] = [];
  failCall: number = 0;

  async extractChatMemory(inputs: ChatMemoryInput[], config: DataManagerModelConfig): Promise<ChatMemoryResult[]> {
    this.calls.push(inputs);
    if (this.calls.length === this.failCall) {
      throw new Error('simulated extraction failure');
    }
    return inputs.map((input: ChatMemoryInput): ChatMemoryResult => {
      return {
        source_ref: input.source_ref,
        facts: input.user_text === '你好' ? [] : [{
          scene_id: input.mode === CHAT_MODE_LOCAL_INFERENCE ? 9 : 6,
          text: input.user_text
        }]
      };
    });
  }
}

function session(id: string, mode: string = CHAT_MODE_CLOUD_AGENT, now: number = NOW): ChatSessionRecord {
  let result = createEmptyChatSession(id, mode, now);
  result.messages = [createChatMessage('u1', 'user', 'chat', '我计划明天坐高铁去北京', now)];
  return result;
}

function saveSession(storage: DataManagerStorage, root: string, record: ChatSessionRecord): void {
  storage.writeJsonAtomic(ChatSessionStorage.sessionPath(root, record.id), record as Object);
}

function responseRejected(payload: JsonMap, inputs: ChatMemoryInput[]): boolean {
  try {
    parseChatMemoryResults(payload, inputs);
    return false;
  } catch (e) {
    return true;
  }
}

export default function chatMemorySyncUnitTest() {
  describe('chatMemorySyncUnitTest', () => {
    it('selectsBothModesByMessageTimestampAndExcludesNonUserFacts', 0, () => {
      let cloud = session('cloud');
      cloud.messages = [
        createChatMessage('old', 'user', 'chat', '旧消息', NOW - CHAT_MEMORY_WINDOW_MS - 1),
        createChatMessage('edge', 'user', 'chat', '七天边界', NOW - CHAT_MEMORY_WINDOW_MS),
        createChatMessage('future', 'user', 'chat', '未来消息', NOW + 1),
        createChatMessage('assistant', 'assistant', 'chat', '建议去上海', NOW),
        createChatMessage('system', 'system', 'context_notice', '压缩摘要', NOW),
        createChatMessage('task', 'task', 'task_result', '执行结果', NOW),
        createChatMessage('empty', 'user', 'chat', '  ', NOW)
      ];
      let local = session('local', CHAT_MODE_LOCAL_INFERENCE);
      let inputs = pendingChatMemoryInputs([cloud, local], [], NOW);
      expect(inputs.length).assertEqual(2);
      expect(inputs[0].user_text).assertEqual('七天边界');
      expect(inputs[1].mode).assertEqual(CHAT_MODE_LOCAL_INFERENCE);
      expect(inputs[1].source_date).assertEqual('2026-09-17');
      expect(pendingChatMemoryInputs([cloud, local], [inputs[0].source_ref], NOW).length).assertEqual(1);
    });

    it('keepsSmallRoleLabelledContextWithoutThinkingOrOtherSessions', 0, () => {
      let record = session('context');
      record.messages = [
        createChatMessage('a1', 'assistant', 'chat', '<think>内部推理</think>建议去北京', NOW),
        createChatMessage('u1', 'user', 'chat', '我决定去那里', NOW)
      ];
      // Old session files may still carry inline thinking tags rather than normalized thinkingContent.
      record.messages[0].content = '<think>内部推理</think>建议去北京';
      let inputs = pendingChatMemoryInputs([record, session('separate')], [], NOW);
      expect(inputs[0].context[0].role).assertEqual('assistant');
      expect(inputs[0].context[0].content).assertEqual('建议去北京');
      expect(inputs[1].context.length).assertEqual(0);
      expect(inputs[0].source_ref === inputs[1].source_ref).assertFalse();
      let prompt = buildChatMemoryPrompt(inputs);
      expect(prompt.systemPrompt.indexOf('不得再次提取前文独有的事实') >= 0).assertTrue();
      expect(prompt.systemPrompt.indexOf('AI 的回答') >= 0).assertTrue();
    });

    it('splitsLongMessagesWithoutDroppingTailAndResumesRemainingParts', 0, () => {
      let record = session('long');
      record.messages[0].content = '文'.repeat(CHAT_MEMORY_PART_CHARS * 3) + '最后的购买记录';
      let inputs = pendingChatMemoryInputs([record], [], NOW);
      expect(inputs.length).assertEqual(4);
      expect(inputs.map((input: ChatMemoryInput): string => input.user_text).join(''))
        .assertEqual(record.messages[0].content);
      expect(chatMemoryBatches(inputs).length > 1).assertTrue();
      expect(pendingChatMemoryInputs([record], [inputs[0].source_ref], NOW).length).assertEqual(3);
    });

    it('acceptsExplicitEmptyResultsAndRejectsMissingDuplicateOrInvalidResults', 0, () => {
      let inputs = pendingChatMemoryInputs([session('s1')], [], NOW);
      let item: JsonMap = { source_ref: inputs[0].source_ref, facts: [] };
      let valid: JsonMap = { items: [item] };
      expect(parseChatMemoryResults(valid, inputs)[0].facts.length).assertEqual(0);
      expect(responseRejected({ items: [] }, inputs)).assertTrue();
      expect(responseRejected({ items: [item, item] }, inputs)).assertTrue();
      let invalidFact: JsonMap = { scene_id: 999, text: '错误类别' };
      let invalidItem: JsonMap = { source_ref: inputs[0].source_ref, facts: [invalidFact] };
      let invalid: JsonMap = { items: [invalidItem] };
      expect(responseRejected(invalid, inputs)).assertTrue();
    });

    it('persistsNoFactChecksAndOnlyExtractsNewMessagesOnNextSync', 0, async () => {
      let storage = new ChatMemoryTestStorage();
      let paths = new DataManagerPaths('/memory', storage);
      let model = new ChatMemoryTestModel();
      let record = session('greeting');
      record.messages[0].content = '你好';
      saveSession(storage, paths.filesDir, record);
      let sync = new ChatMemorySync(paths, storage, model);
      expect(sync.hasDataToSync(NOW)).assertTrue();
      let first = await sync.sync(CONFIG, undefined, NOW);
      expect(first.factCount).assertEqual(0);
      expect(sync.hasDataToSync(NOW)).assertFalse();
      record.messages.push(createChatMessage('u2', 'user', 'chat', '我买了去北京的车票', NOW));
      saveSession(storage, paths.filesDir, record);
      await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW);
      await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW);
      expect(model.calls.length).assertEqual(2);
      expect(model.calls[1].length).assertEqual(1);
      expect(model.calls[1][0].user_text).assertEqual('我买了去北京的车票');
    });

    it('retriesFailedBatchesWithoutReextractingCommittedMessages', 0, async () => {
      let storage = new ChatMemoryTestStorage();
      let paths = new DataManagerPaths('/memory', storage);
      let model = new ChatMemoryTestModel();
      let record = session('many');
      record.messages = [];
      for (let i = 0; i < 9; i++) {
        record.messages.push(createChatMessage('u' + String(i), 'user', 'chat', '我要去北京' + String(i), NOW));
      }
      saveSession(storage, paths.filesDir, record);
      model.failCall = 2;
      let failed = false;
      try {
        await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW);
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      let retried = await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW);
      expect(retried.processedParts).assertEqual(1);
      expect(model.calls[2].length).assertEqual(1);
      let relative = ChatMemorySync.dailyLogRelativePaths(paths.dailyLogRoot, storage)[0];
      let doc = parseDailyLogDocument(storage.readText(storage.join(paths.dailyLogRoot, relative)));
      expect(parseNumberedEntries(doc.body).length).assertEqual(9);
    });

    it('recoversFailedExportsAfterSevenDaysWithoutCallingModelAgain', 0, async () => {
      let storage = new ChatMemoryTestStorage();
      let paths = new DataManagerPaths('/memory', storage);
      let model = new ChatMemoryTestModel();
      saveSession(storage, paths.filesDir, session('export'));
      storage.failExport = true;
      let failed = false;
      try {
        await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW);
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      storage.failExport = false;
      await new ChatMemorySync(paths, storage, model).sync(CONFIG, undefined, NOW + CHAT_MEMORY_WINDOW_MS + 1);
      expect(model.calls.length).assertEqual(1);
      let relative = ChatMemorySync.dailyLogRelativePaths(paths.dailyLogRoot, storage)[0];
      expect(storage.exists(storage.join(paths.dailyLogRoot, relative))).assertTrue();
    });

    it('keepsExistingEntryIndexesWhenOlderMessagesAreAdded', 0, async () => {
      let storage = new ChatMemoryTestStorage();
      let paths = new DataManagerPaths('/memory', storage);
      let model = new ChatMemoryTestModel();
      saveSession(storage, paths.filesDir, session('first'));
      let sync = new ChatMemorySync(paths, storage, model);
      await sync.sync(CONFIG, undefined, NOW);
      let relative = ChatMemorySync.dailyLogRelativePaths(paths.dailyLogRoot, storage)[0];
      let path = storage.join(paths.dailyLogRoot, relative);
      let before = parseNumberedEntries(parseDailyLogDocument(storage.readText(path)).body)[0];
      let older = session('older', CHAT_MODE_CLOUD_AGENT, NOW - 1000);
      older.messages[0].content = '我昨天去过上海';
      saveSession(storage, paths.filesDir, older);
      await sync.sync(CONFIG, undefined, NOW);
      let after = parseNumberedEntries(parseDailyLogDocument(storage.readText(path)).body);
      expect(after.length).assertEqual(2);
      expect(after[0].index).assertEqual(before.index);
      expect(after[0].text).assertEqual(before.text);
      expect(sourceDisplayName(relative)).assertEqual('云端聊天');
      expect(sourceAppDisplayName('2026-09/app-chat__local__9.md.state.json')).assertEqual('端侧聊天');
    });

    it('doesNotMarkMessagesProcessedWhenModelIsDisabled', 0, async () => {
      let storage = new ChatMemoryTestStorage();
      let paths = new DataManagerPaths('/memory', storage);
      saveSession(storage, paths.filesDir, session('disabled'));
      let sync = new ChatMemorySync(paths, storage, new DataPipelineModelClient());
      let failed = false;
      try {
        await sync.sync(CONFIG, undefined, NOW);
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(sync.hasDataToSync(NOW)).assertTrue();
    });

    it('chatOnlyDataReachesBothCollectionCategoriesThroughExistingPipeline', 0, async () => {
      let now = Date.now();
      let root = '/tmp/chat-memory-pipeline-' + String(now);
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths(root, storage);
      try {
        saveSession(storage, root, session('cloud', CHAT_MODE_CLOUD_AGENT, now));
        let local = session('local', CHAT_MODE_LOCAL_INFERENCE, now);
        local.messages[0].content = '我今天跑了五公里';
        saveSession(storage, root, local);
        let facade = new DataManagerFacade(root);
        expect(facade.hasDailyLogData()).assertFalse();
        expect(facade.hasDataToSync()).assertTrue();
        await new ChatMemorySync(paths, storage, new ChatMemoryTestModel()).sync(CONFIG, undefined, now);
        await facade.refresh(CONFIG);
        expect(facade.loadCollectionViewModel(6).empty).assertFalse();
        expect(facade.loadCollectionViewModel(9).empty).assertFalse();
        let query = collectionTabSpecByIndex(6).query;
        let first = facade.queryIndexedEvents(query);
        await facade.refresh(CONFIG);
        expect(facade.queryIndexedEvents(query).events.length).assertEqual(first.events.length);
      } finally {
        storage.removeTree(root);
      }
    });
  });
}
