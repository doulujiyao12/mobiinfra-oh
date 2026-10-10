import { describe, expect, it } from '@ohos/hypium';
import { IndexedEvent, QueryResult } from '../main/ets/datamanager/DataManagerTypes';
import { PERSONAL_INFO_MEMORY_SCENE_ID } from '../main/ets/utils/WorkflowSceneConfig';
import {
  parsePersonalMemoryA2aRequest,
  personalMemoryA2aError,
  personalMemoryA2aFallbackError,
  personalMemoryA2aInputShape,
  personalMemoryA2aReply,
  personalMemoryA2aReplies
} from '../main/ets/agent/PersonalMemoryA2aProtocol';
import { personalMemoryAnswer, personalMemoryQueryOptions } from '../main/ets/agent/PersonalMemoryQuery';
import { canExposePersonalMemory, PERSONAL_MEMORY_A2A_SCOPE } from '../main/ets/agent/PersonalMemoryAccess';
import { PRIVACY_VERSION } from '../main/ets/utils/PrivacyConsent';

function event(summary: string, scenes: number[]): IndexedEvent {
  return {
    event_id: summary,
    source_state_file: '',
    record_id: 1,
    event_date: '2026-09-30',
    last_seen_date: '2026-09-30',
    summary: summary,
    normalized_fact: summary,
    tags: [],
    source_refs: [],
    sources: [],
    workflow_scene_ids: scenes,
    image_paths: [],
    todo: { type: '', deadline: '', text: '', agent_task: '' },
    keywords: [],
    domains: [],
    entity_mentions: [],
    enrichment_method: '',
    entities: [],
    profile_domains: []
  };
}

export default function personalMemoryA2aUnitTest() {
  describe('personalMemoryA2aUnitTest', () => {
    it('requiresCurrentPrivacyConsentUserOptInAndApi24', 0, () => {
      expect(canExposePersonalMemory('accepted', PRIVACY_VERSION, true, 24, PERSONAL_MEMORY_A2A_SCOPE)).assertTrue();
      expect(canExposePersonalMemory('accepted', PRIVACY_VERSION, true, 20, PERSONAL_MEMORY_A2A_SCOPE)).assertFalse();
      expect(canExposePersonalMemory('accepted', PRIVACY_VERSION, false, 24, PERSONAL_MEMORY_A2A_SCOPE)).assertFalse();
      expect(canExposePersonalMemory('rejected', PRIVACY_VERSION, true, 24, PERSONAL_MEMORY_A2A_SCOPE)).assertFalse();
      expect(canExposePersonalMemory('accepted', 'old-version', true, 24, PERSONAL_MEMORY_A2A_SCOPE)).assertFalse();
      expect(canExposePersonalMemory('accepted', PRIVACY_VERSION, true, 24, '')).assertFalse();
    });

    it('queriesIndexedMemoryAcrossScenesAndExcludesSensitiveResults', 0, () => {
      let options = personalMemoryQueryOptions('我之前说过的生日是什么？');
      expect(options.workflowSceneIds.length).assertEqual(0);
      expect(options.limit).assertEqual(20);
      let sensitiveChat = event('微信里约了周日见面', [3]);
      sensitiveChat.normalized_fact = '对方手机号是13800138000';
      let result: QueryResult = {
        total_events: 6,
        events: [
          event('我的生日是9月17日', [PERSONAL_INFO_MEMORY_SCENE_ID]),
          event('我的身份证号是110101199001011234', [PERSONAL_INFO_MEMORY_SCENE_ID]),
          event('我住在幸福路12号的详细地址', [PERSONAL_INFO_MEMORY_SCENE_ID]),
          event('我点了一杯奶茶', [1]),
          event('微信里和小王聊了周末爬山', [3]),
          sensitiveChat
        ],
        events_truncated: false
      };
      let answer = personalMemoryAnswer(result);
      expect(answer.count).assertEqual(3);
      expect(answer.text.indexOf('9月17日') >= 0).assertTrue();
      expect(answer.text.indexOf('奶茶') >= 0).assertTrue();
      expect(answer.text.indexOf('周末爬山') >= 0).assertTrue();
      expect(answer.text.indexOf('110101') >= 0).assertFalse();
      expect(answer.text.indexOf('幸福路') >= 0).assertFalse();
      expect(answer.text.indexOf('周日见面') >= 0).assertFalse();
    });

    it('usesTakeoutSceneAndWechatSourceForCommonQuestions', 0, () => {
      let takeout = personalMemoryQueryOptions('我上次点了什么外卖？');
      expect(takeout.workflowSceneIds.length).assertEqual(1);
      expect(takeout.workflowSceneIds[0]).assertEqual(1);
      expect(takeout.keywords.length).assertEqual(0);
      let wechat = personalMemoryQueryOptions('我最近的微信聊天里提到了什么？');
      expect(wechat.workflowSceneIds.length).assertEqual(0);
      expect(wechat.keywords[0]).assertEqual('微信');
    });

    it('usesRecentIndexedEventsForAnOverviewQuestion', 0, () => {
      let options = personalMemoryQueryOptions('帮我看一下我做了哪些事');
      expect(options.keywords.length).assertEqual(0);
      expect(options.workflowSceneIds.length).assertEqual(0);
    });

    it('acceptsXiaoyiNativeMessageAndReturnsAgentMessage', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"messageId":"request-1","role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}],"contextId":"context-1"}');
      expect(request.method).assertEqual('native-message');
      expect(request.question).assertEqual('我做了哪些事');
      let reply = personalMemoryA2aReply(request, { text: '• 我点了外卖', count: 1 });
      expect(reply.indexOf('"role":0') >= 0).assertTrue();
      expect(reply.indexOf('"mediaType":"text/plain"') >= 0).assertTrue();
      expect(reply.indexOf('"contextId":"context-1"') >= 0).assertTrue();
      let denied = personalMemoryA2aError('请先授权', request);
      expect(denied.indexOf('"role":0') >= 0).assertTrue();
      expect(denied.indexOf('请先授权') >= 0).assertTrue();
    });

    it('keepsJsonRpcEnvelopeForWrappedXiaoyiMessage', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"message":{"role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]}}}');
      expect(request.numericRole === true).assertTrue();
      let reply = personalMemoryA2aReply(request, { text: '• 我点了外卖', count: 1 });
      expect(reply.indexOf('"jsonrpc":"2.0"') >= 0).assertTrue();
      expect(reply.indexOf('"id":7') >= 0).assertTrue();
      expect(reply.indexOf('"role":0') >= 0).assertTrue();
      expect(reply.indexOf('"mediaType":"text/plain"') >= 0).assertTrue();
    });

    it('acceptsTaskSendWithMessageParts', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"rpc-1","method":"tasks/send","params":{"id":"task-1","message":{"role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]}}}');
      expect(request.method).assertEqual('tasks/send');
      expect(request.taskId).assertEqual('task-1');
      expect(request.question).assertEqual('我做了哪些事');
    });

    it('acceptsStreamingMessageWithNumericRole', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":8,"method":"message/stream","params":{"message":{"role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]}}}');
      expect(request.method).assertEqual('message/stream');
      expect(request.question).assertEqual('我做了哪些事');
      let reply = personalMemoryA2aReply(request, { text: '查询完成', count: 1 });
      expect(reply.indexOf('"id":8') >= 0).assertTrue();
      expect(reply.indexOf('"role":0') >= 0).assertTrue();
      let denied = personalMemoryA2aError('请先授权', request);
      expect(denied.indexOf('"id":8') >= 0).assertTrue();
      expect(denied.indexOf('请先授权') >= 0).assertTrue();
    });

    it('usesHuaweiSubmittedArtifactAndCompletedFramesForXiaoyiStream', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"rpc-10","method":"SendStreamingMessage","params":{"message":{"messageId":"m-1","taskId":"task-10","contextId":"c-1","role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]},"metadata":{"traceId":"trace-10","agentId":"clawmate_personal_memory"}}}');
      expect(request.method).assertEqual('SendStreamingMessage');
      expect(request.question).assertEqual('我做了哪些事');
      let replies = personalMemoryA2aReplies(request, { text: '查询完成', count: 1 });
      expect(replies.length).assertEqual(3);
      expect(replies[0].indexOf('"id":"rpc-10"') >= 0).assertTrue();
      expect(replies[0].indexOf('"result":{"task":') >= 0).assertTrue();
      expect(replies[0].indexOf('"id":"task-10"') >= 0).assertTrue();
      expect(replies[0].indexOf('"state":"TASK_STATE_SUBMITTED"') >= 0).assertTrue();
      expect(replies[0].indexOf('"text":"查询完成"') >= 0).assertFalse();
      expect(replies[1].indexOf('"id":"rpc-10"') >= 0).assertTrue();
      expect(replies[1].indexOf('"result":{"artifactUpdate":') >= 0).assertTrue();
      expect(replies[1].indexOf('"taskId":"task-10"') >= 0).assertTrue();
      expect(replies[1].indexOf('"contextId":"c-1"') >= 0).assertTrue();
      expect(replies[1].indexOf('"artifactId":"memory_artifact_') >= 0).assertTrue();
      expect(replies[1].indexOf('"text":"查询完成"') >= 0).assertTrue();
      expect(replies[1].indexOf('"lastChunk":true') >= 0).assertTrue();
      expect(replies[2].indexOf('"id":"rpc-10"') >= 0).assertTrue();
      expect(replies[2].indexOf('"result":{"statusUpdate":') >= 0).assertTrue();
      expect(replies[2].indexOf('"taskId":"task-10"') >= 0).assertTrue();
      expect(replies[2].indexOf('"contextId":"c-1"') >= 0).assertTrue();
      expect(replies[2].indexOf('"state":"TASK_STATE_COMPLETED"') >= 0).assertTrue();
      expect(replies[2].indexOf('"timestamp":"') >= 0).assertTrue();
      expect(replies[2].indexOf('"traceId":"trace-10"') >= 0).assertTrue();
      expect(replies[2].indexOf('"agentVersion":"1.0.0"') >= 0).assertTrue();
      expect(replies[2].indexOf('"text":"查询完成"') >= 0).assertFalse();
    });

    it('keepsGeneratedStreamIdsAcrossAllFrames', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"rpc-12","method":"SendStreamingMessage","params":{"message":{"role":1,"parts":[{"text":"我做了哪些事"}]}}}');
      let replies = personalMemoryA2aReplies(request, { text: '查询完成', count: 1 });
      let taskStart = replies[0].indexOf('"id":"memory_task_');
      let contextStart = replies[0].indexOf('"contextId":"memory_context_');
      expect(taskStart >= 0).assertTrue();
      expect(contextStart >= 0).assertTrue();
      let taskValueStart = taskStart + '"id":"'.length;
      let contextValueStart = contextStart + '"contextId":"'.length;
      let taskId = replies[0].substring(taskValueStart, replies[0].indexOf('"', taskValueStart));
      let contextId = replies[0].substring(contextValueStart, replies[0].indexOf('"', contextValueStart));
      expect(replies[1].indexOf('"taskId":"' + taskId + '"') >= 0).assertTrue();
      expect(replies[1].indexOf('"contextId":"' + contextId + '"') >= 0).assertTrue();
      expect(replies[2].indexOf('"taskId":"' + taskId + '"') >= 0).assertTrue();
      expect(replies[2].indexOf('"contextId":"' + contextId + '"') >= 0).assertTrue();
    });

    it('acceptsHuaweiDocumentedMessageStreamMethod', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"req-002","method":"MessageStream","params":{"message":{"messageId":"msg-002","role":"ROLE_USER","contextId":"ctx-001","parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]},"metadata":{"traceId":"trace-002","agentId":"clawmate_personal_memory"}}}');
      expect(request.method).assertEqual('MessageStream');
      let replies = personalMemoryA2aReplies(request, { text: '查询完成', count: 1 });
      expect(replies.length).assertEqual(3);
      expect(replies[0].indexOf('"id":"req-002"') >= 0).assertTrue();
      expect(replies[1].indexOf('"result":{"artifactUpdate":') >= 0).assertTrue();
      expect(replies[2].indexOf('"state":"TASK_STATE_COMPLETED"') >= 0).assertTrue();
    });

    it('keepsDirectV1SendMessageReply', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":"rpc-11","method":"SendMessage","params":{"message":{"role":"ROLE_USER","parts":[{"text":"我做了哪些事"}]}}}');
      let reply = personalMemoryA2aReply(request, { text: '查询完成', count: 1 });
      expect(reply.indexOf('"result":{"message":') >= 0).assertTrue();
      expect(reply.indexOf('"role":"ROLE_AGENT"') >= 0).assertTrue();
      expect(personalMemoryA2aReplies(request, { text: '查询完成', count: 1 }).length).assertEqual(1);
    });

    it('rejectsXiaoyiV1CancelMethod', 0, () => {
      let rejected = false;
      try {
        parsePersonalMemoryA2aRequest(
          '{"jsonrpc":"2.0","id":1,"method":"CancelTask","params":{"message":{"role":1,"parts":[{"text":"生日"}]}}}');
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('acceptsLegacyStreamingTaskWithMessageParts', 0, () => {
      let request = parsePersonalMemoryA2aRequest(
        '{"jsonrpc":"2.0","id":9,"method":"tasks/sendSubscribe","params":{"message":{"role":1,"parts":[{"text":"我做了哪些事","mediaType":"text/plain"}]}}}');
      expect(request.question).assertEqual('我做了哪些事');
      let reply = personalMemoryA2aReply(request, { text: '查询完成', count: 1 });
      expect(reply.indexOf('"method":"tasks/sendSubscribe"') >= 0).assertTrue();
    });

    it('reportsSafeEnvelopeShapeAndCorrelatedFallbackError', 0, () => {
      let data = '{"jsonrpc":"2.0","id":"rpc-1","method":"我的私密问题","params":{"message":{"parts":[{"text":"我的私密问题"}]}}}';
      let shape = personalMemoryA2aInputShape(data);
      expect(shape.indexOf('method=other') >= 0).assertTrue();
      expect(shape.indexOf('paramsMessage=true') >= 0).assertTrue();
      expect(shape.indexOf('我的私密问题') >= 0).assertFalse();
      let error = personalMemoryA2aFallbackError(data, '查询失败');
      expect(error.indexOf('"id":"rpc-1"') >= 0).assertTrue();
      expect(error.indexOf('"code":-32602') >= 0).assertTrue();
    });

    it('rejectsNonUserNativeMessage', 0, () => {
      let rejected = false;
      try {
        parsePersonalMemoryA2aRequest('{"messageId":"request-1","role":0,"parts":[{"text":"记忆"}]}');
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('rejectsUnsupportedActionsAndBuildsAReadOnlyTaskReply', 0, () => {
      let rejected = false;
      try {
        parsePersonalMemoryA2aRequest('{"method":"tasks/delete","params":{"task":{"query":"生日"}}}');
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      let request = parsePersonalMemoryA2aRequest(
        '{"method":"tasks/send","params":{"task":{"taskId":"t1","query":"我的生日是什么"}}}');
      let reply = personalMemoryA2aReply(request, { text: '• 我的生日是9月17日', count: 1 });
      expect(reply.indexOf('"taskId":"t1"') >= 0).assertTrue();
      expect(reply.indexOf('"state":"completed"') >= 0).assertTrue();
    });
  });
}
