import { describe, expect, it } from '@ohos/hypium';
import {
  PERSONAL_MEMORY_AGENT_REVOKED,
  PERSONAL_MEMORY_AGENT_TIMEOUT,
  PersonalMemoryChatAgent,
  PersonalMemoryChatContext,
  personalMemoryChatMessages
} from '../main/ets/agent/PersonalMemoryChatAgent';
import {
  PersonalMemoryA2aReplySession,
  parsePersonalMemoryA2aRequest
} from '../main/ets/agent/PersonalMemoryA2aProtocol';
import { personalMemorySafeQueryResult } from '../main/ets/agent/PersonalMemoryQuery';
import { IndexedEvent, QueryOptions, QueryResult } from '../main/ets/datamanager/DataManagerTypes';
import {
  CloudChatCompletionOptions,
  CloudChatCompletionResult,
  CloudChatMessage,
  CloudModelClient,
  CloudModelConfig,
  CloudToolCall
} from '../main/ets/utils/CloudModelClient';

class MemoryModelClient extends CloudModelClient {
  requests: CloudChatCompletionOptions[] = [];
  cancelCount: number = 0;
  private responses: CloudChatCompletionResult[];

  constructor(responses: CloudChatCompletionResult[]) {
    super();
    this.responses = responses;
  }

  async chatCompletion(options: CloudChatCompletionOptions): Promise<CloudChatCompletionResult> {
    this.requests.push(options);
    let index = this.requests.length - 1;
    return this.responses[index];
  }

  cancelActiveRequests(): void {
    this.cancelCount += 1;
  }
}

class StalledMemoryModelClient extends CloudModelClient {
  cancelCount: number = 0;

  async chatCompletion(_options: CloudChatCompletionOptions): Promise<CloudChatCompletionResult> {
    return new Promise<CloudChatCompletionResult>(() => {});
  }

  cancelActiveRequests(): void {
    this.cancelCount += 1;
  }
}

function config(): CloudModelConfig {
  return { plannerBaseUrl: 'http://localhost:8000', plannerModel: 'memory-model',
    deciderBaseUrl: '', apiKey: 'test-key', deciderModel: '' };
}

function completion(content: string, args: string = ''): CloudChatCompletionResult {
  let calls: CloudToolCall[] = [];
  if (args.length > 0) {
    let call: CloudToolCall = { id: 'query-1', type: 'function',
      function: { name: 'query_events', arguments: args } };
    calls.push(call);
  }
  return { content: content, toolCalls: calls, finishReason: calls.length > 0 ? 'tool_calls' : 'stop',
    assistantMessage: { role: 'assistant', content: content, tool_calls: calls } };
}

function event(summary: string): IndexedEvent {
  return { event_id: summary, source_state_file: '', record_id: 1, event_date: '2026-09-22',
    last_seen_date: '2026-09-22', summary: summary, normalized_fact: summary, tags: [], source_refs: [],
    sources: ['微信'], workflow_scene_ids: [3], image_paths: [],
    todo: { type: '', deadline: '', text: '', agent_task: '' }, keywords: [], domains: ['work'],
    entity_mentions: [], enrichment_method: '', entities: [], profile_domains: [] };
}

function queryResult(events: IndexedEvent[]): QueryResult {
  return { total_events: events.length, events: events, events_truncated: false };
}

function context(events: IndexedEvent[], captured: QueryOptions[] = []): PersonalMemoryChatContext {
  return {
    filesDir: '',
    hasBuiltIndexes: (): boolean => true,
    isAuthorized: async (): Promise<boolean> => true,
    query: (options: QueryOptions): QueryResult => {
      captured.push(options);
      return queryResult(events);
    }
  };
}

export default function personalMemoryChatAgentUnitTest() {
  describe('personalMemoryChatAgentUnitTest', () => {
    it('passesModelChosenDatesToTheIndexAndReturnsItsSummary', 0, async () => {
      let summary = '9月21日至27日，你参加了鸿蒙开发讨论。';
      let model = new MemoryModelClient([
        completion('', '{"keywords":[],"start_date":"2026-09-21","end_date":"2026-09-27"}'),
        completion(summary)
      ]);
      let captured: QueryOptions[] = [];
      let agent = new PersonalMemoryChatAgent(model);
      let answer = await agent.run('我上周做了哪些事', config(), context([event('参加鸿蒙开发讨论')], captured));
      expect(captured.length).assertEqual(1);
      expect(captured[0].startDate).assertEqual('2026-09-21');
      expect(captured[0].endDate).assertEqual('2026-09-27');
      expect(captured[0].keywords.length).assertEqual(0);
      expect(answer.text).assertEqual(summary);
      expect(answer.count).assertEqual(1);
      expect(model.requests.length).assertEqual(2);
      let tools = model.requests[0].tools || [];
      expect(tools.length).assertEqual(1);
      expect(tools[0].function.name).assertEqual('query_events');
      expect(model.requests[0].logResponseContent === false).assertTrue();
      expect(model.requests[0].readTimeout).assertEqual(30000);
      expect(model.requests[0].maxTokens).assertEqual(2048);
      let toolMessage = model.requests[1].messages.filter((message: CloudChatMessage): boolean => message.role === 'tool')[0];
      expect((toolMessage.content as string).indexOf('参加鸿蒙开发讨论') >= 0).assertTrue();
    });

    it('letsTheModelRelaxKeywordsAndRetryAnEmptySearch', 0, async () => {
      let model = new MemoryModelClient([
        completion('', '{"keywords":["咖啡","外卖"],"keyword_operator":"and"}'),
        completion('', '{"keywords":["咖啡"],"keyword_operator":"or"}'),
        completion('你最近点过咖啡。')
      ]);
      let captured: QueryOptions[] = [];
      let access = context([], captured);
      access.query = (options: QueryOptions): QueryResult => {
        captured.push(options);
        return queryResult(options.keywords.length === 1 ? [event('点了一杯咖啡')] : []);
      };
      let answer = await new PersonalMemoryChatAgent(model).run('我点过什么饮料', config(), access);
      expect(captured.length).assertEqual(2);
      expect(captured[1].keywords[0]).assertEqual('咖啡');
      expect(answer.text).assertEqual('你最近点过咖啡。');
    });

    it('filtersSensitiveToolFieldsBeforeTheyReachTheModel', 0, async () => {
      let hiddenFact = event('讨论周末见面');
      hiddenFact.normalized_fact = '手机号13800138000';
      let hiddenEntity = event('整理联系人');
      hiddenEntity.entities = ['13800138000'];
      let hiddenTodo = event('讨论搬家计划');
      hiddenTodo.todo.text = '家庭住址是幸福路12号';
      let filtered = personalMemorySafeQueryResult(queryResult([
        event('点了一杯咖啡'), hiddenFact, hiddenEntity, hiddenTodo
      ]));
      expect(filtered.events.length).assertEqual(1);
      let model = new MemoryModelClient([completion('', '{}'), completion('你点了一杯咖啡。')]);
      await new PersonalMemoryChatAgent(model).run('我最近做了什么', config(), context([
        event('点了一杯咖啡'), hiddenFact, hiddenEntity, hiddenTodo
      ]));
      let messages = model.requests[1].messages;
      let toolText = messages[messages.length - 1].content as string;
      expect(toolText.indexOf('咖啡') >= 0).assertTrue();
      expect(toolText.indexOf('13800138000') >= 0).assertFalse();
      expect(toolText.indexOf('幸福路') >= 0).assertFalse();
    });

    it('blocksUnsupportedPersonalClaimsWithoutAnyRetrieval', 0, async () => {
      let model = new MemoryModelClient([completion('你上周买了一台手机。')]);
      let answer = await new PersonalMemoryChatAgent(model).run('我上周做了什么', config(), context([]));
      expect(answer.count).assertEqual(0);
      expect(answer.text.indexOf('买了一台手机') >= 0).assertFalse();
      expect(answer.text.indexOf('未完成记忆检索') >= 0).assertTrue();
    });

    it('stopsBeforeAnotherModelRequestWhenAuthorizationIsRevoked', 0, async () => {
      let allowed = true;
      let model = new MemoryModelClient([completion('', '{}'), completion('不应返回这个回答')]);
      let access = context([]);
      access.isAuthorized = async (): Promise<boolean> => allowed;
      access.query = (_options: QueryOptions): QueryResult => {
        allowed = false;
        return queryResult([event('讨论鸿蒙开发')]);
      };
      let reason = '';
      try {
        await new PersonalMemoryChatAgent(model).run('我做了什么', config(), access);
      } catch (e) {
        reason = (e as Error).message;
      }
      expect(reason).assertEqual(PERSONAL_MEMORY_AGENT_REVOKED);
      expect(model.requests.length).assertEqual(1);
    });

    it('boundsAStalledModelAndCanCloseItsA2aTask', 0, async () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"rpc-1","method":"SendStreamingMessage","params":{"message":{"role":1,"parts":[{"text":"我做了什么"}]}}}');
      let session = new PersonalMemoryA2aReplySession(request);
      let first = session.start();
      let model = new StalledMemoryModelClient();
      let reason = '';
      try {
        await new PersonalMemoryChatAgent(model, 1).run(request.question, config(), context([]));
      } catch (e) {
        reason = (e as Error).message;
      }
      expect(reason).assertEqual(PERSONAL_MEMORY_AGENT_TIMEOUT);
      expect(model.cancelCount > 0).assertTrue();
      let last = session.finish({ text: '查询超时，本次已结束', count: 0 });
      expect(first[0].indexOf('TASK_STATE_SUBMITTED') >= 0).assertTrue();
      expect(last[0].indexOf('"lastChunk":true') >= 0).assertTrue();
      expect(last[1].indexOf('TASK_STATE_COMPLETED') >= 0).assertTrue();
      let taskStart = first[0].indexOf('"id":"memory_task_') + '"id":"'.length;
      let taskId = first[0].substring(taskStart, first[0].indexOf('"', taskStart));
      expect(last[0].indexOf('"taskId":"' + taskId + '"') >= 0).assertTrue();
      expect(last[1].indexOf('"taskId":"' + taskId + '"') >= 0).assertTrue();
      expect(session.finish({ text: '不得重复发送', count: 0 }).length).assertEqual(0);
    });

    it('suppliesCalendarWeekRangesAcrossYearBoundaries', 0, () => {
      let messages = personalMemoryChatMessages('我上周做了什么', new Date(2027, 0, 1, 12));
      let system = messages[0].content as string;
      expect(system.indexOf('2027-01-01') >= 0).assertTrue();
      expect(system.indexOf('2026-12-28 至 2027-01-03') >= 0).assertTrue();
      expect(system.indexOf('2026-12-21 至 2026-12-27') >= 0).assertTrue();
      expect(messages[1].content).assertEqual('我上周做了什么');
    });
  });
}
