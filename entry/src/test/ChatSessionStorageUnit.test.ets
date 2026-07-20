import { describe, it, expect } from '@ohos/hypium';
import fs from '@ohos.file.fs';
import {
  CHAT_MESSAGE_KIND_CONTEXT_NOTICE,
  CHAT_MESSAGE_KIND_TASK_RESULT,
  CHAT_MESSAGE_KIND_TASK_TRACE,
  CHAT_MODE_CLOUD_AGENT,
  ChatMessage,
  ChatSessionSummary,
  buildCloudContextMessages,
  chatMessageCopyContent,
  chatMessageRenderKey,
  chatMessageImagePaths,
  chatMessageStableRenderKey,
  chatSessionRenderKey,
  chatMessagesAutoScrollKey,
  chatMessagesStreamFollowKey,
  buildAssistantStreamingRenderContent,
  chatSessionPreview,
  compactChatPreviewText,
  createChatStreamThinkingState,
  createChatMessage,
  createEmptyChatSession,
  parseChatStreamThinkingDelta,
  defaultChatSessionTitle,
  splitAssistantThinkingContent,
  toggleChatMessageThinkingCollapsed,
  toggleChatMessageCollapsed
} from '../main/ets/pages/chat/ChatSessionTypes';
import {
  CHAT_STREAM_FLUSH_CHAR_DELTA,
  CHAT_STREAM_FLUSH_INTERVAL_MS,
  ChatStreamUpdateFlushState,
  chatStreamUpdateDelayMs,
  chatStreamUpdateStateAfterFlush,
  shouldFlushChatStreamUpdate
} from '../main/ets/pages/chat/ChatStreamUpdatePolicy';
import { ChatSessionController, ChatSessionViewState } from '../main/ets/pages/chat/ChatSessionController';
import { ChatSessionStorage } from '../main/ets/utils/ChatSessionStorage';

let testRootCounter: number = 0;

function nextTestRoot(name: string): string {
  testRootCounter += 1;
  return '/tmp/chat-session-storage-unit-' + name + '-' + String(new Date().getTime()) + '-' +
    String(testRootCounter);
}

function cleanupPath(path: string): void {
  try {
    let children = fs.listFileSync(path);
    for (let i = 0; i < children.length; i++) {
      cleanupPath(path + '/' + children[i]);
    }
    fs.rmdirSync(path);
  } catch (e) {
    try {
      fs.unlinkSync(path);
    } catch (err) {
    }
  }
}

function prepareTestRoot(path: string): void {
  cleanupPath(path);
  if (!ChatSessionStorage.pathExists(path)) {
    fs.mkdirSync(path);
  }
}

function findSummaryById(sessions: ChatSessionSummary[], id: string): ChatSessionSummary | null {
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i].id === id) {
      return sessions[i];
    }
  }
  return null;
}

export default function chatSessionStorageUnitTest() {
  describe('chatSessionStorageUnitTest', () => {
    it('createsDefaultSessionWithModeAndTitle', 0, () => {
      let session = createEmptyChatSession('session-1', CHAT_MODE_CLOUD_AGENT, 1000);

      expect(session.id).assertEqual('session-1');
      expect(session.mode).assertEqual(CHAT_MODE_CLOUD_AGENT);
      expect(session.title).assertEqual(defaultChatSessionTitle(CHAT_MODE_CLOUD_AGENT));
      expect(session.messages.length).assertEqual(0);
    });

    it('buildsPreviewFromLatestUsefulMessage', 0, () => {
      let messages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', '请整理今天截图里的关键信息', 1000),
        createChatMessage('m2', 'assistant', 'chat', '我会先读取最近截图并按主题归纳。', 1001)
      ];

      expect(chatSessionPreview(messages)).assertEqual('我会先读取最近截图并按主题归纳。');
    });

    it('buildsAutoScrollKeyFromSessionAndLatestMessage', 0, () => {
      let messages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', '第一条消息', 1000),
        createChatMessage('m2', 'assistant', 'chat', '最新回答', 1001)
      ];
      let sameSessionKey = chatMessagesAutoScrollKey('session-a', messages, false);
      let changedSessionKey = chatMessagesAutoScrollKey('session-b', messages, false);
      let streamingKey = chatMessagesAutoScrollKey('session-a', messages, true);

      expect(sameSessionKey.indexOf('session-a') === 0).assertTrue();
      expect(sameSessionKey.indexOf(chatMessageStableRenderKey(messages[1])) >= 0).assertTrue();
      expect(changedSessionKey === sameSessionKey).assertFalse();
      expect(streamingKey === sameSessionKey).assertFalse();
    });

    it('keepsStableRenderKeyWhenStreamingContentGrows', 0, () => {
      let initial = createChatMessage('m1', 'assistant', 'chat', '正在整理', 1000);
      let streamed = createChatMessage('m1', 'assistant', 'chat', '正在整理更多内容', 1000);

      expect(chatMessageStableRenderKey(initial)).assertEqual(chatMessageStableRenderKey(streamed));
      expect(chatMessageRenderKey(initial) === chatMessageRenderKey(streamed)).assertFalse();
    });

    // 整条复制仅暴露用户可见正文，不能把模型思考区或工具轨迹写入系统剪贴板。
    it('buildsCopyContentFromVisibleMessageBodyOnly', 0, () => {
      let message = createChatMessage('assistant-copy-1', 'assistant', 'chat',
        '<think>内部推理。</think>最终回答正文。', 1000, ['工具执行轨迹']);

      expect(chatMessageCopyContent(message)).assertEqual('最终回答正文。');
    });

    it('updatesRenderKeyWhenSameLengthContentChangesWithoutAutoScroll', 0, () => {
      let initialMessages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', 'hello', 1000),
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙丁', 1001)
      ];
      let changedMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙戊', 1001)
      ];

      expect(chatMessageRenderKey(initialMessages[1]) === chatMessageRenderKey(changedMessages[1])).assertFalse();
      expect(chatMessagesAutoScrollKey('session-a', initialMessages, true))
        .assertEqual(chatMessagesAutoScrollKey('session-a', changedMessages, true));
    });

    it('keepsAutoScrollKeyStableForStreamingContentGrowth', 0, () => {
      let initialMessages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', '查一下最近一个月干了啥', 1000),
        createChatMessage('m2', 'assistant', 'chat', '正在整理', 1001)
      ];
      let streamedMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '正在整理更多内容', 1001)
      ];
      let newMessageMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m3', 'assistant', 'chat', '新的回答', 1002)
      ];

      expect(chatMessagesAutoScrollKey('session-a', initialMessages, true))
        .assertEqual(chatMessagesAutoScrollKey('session-a', streamedMessages, true));
      expect(chatMessagesAutoScrollKey('session-a', initialMessages, true) ===
        chatMessagesAutoScrollKey('session-a', newMessageMessages, true)).assertFalse();
      expect(chatMessagesAutoScrollKey('session-a', initialMessages, true) ===
        chatMessagesAutoScrollKey('session-a', initialMessages, false)).assertFalse();
    });

    it('buildsStreamFollowKeyFromLatestStreamingContent', 0, () => {
      let initialMessages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', '查一下最近一个月干了啥', 1000),
        createChatMessage('m2', 'assistant', 'chat', '正在整理', 1001)
      ];
      let streamedMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '正在整理更多内容', 1001)
      ];

      expect(chatMessagesStreamFollowKey('session-a', initialMessages, true) ===
        chatMessagesStreamFollowKey('session-a', streamedMessages, true)).assertFalse();
      expect(chatMessagesStreamFollowKey('session-a', initialMessages, true) ===
        chatMessagesStreamFollowKey('session-a', initialMessages, false)).assertFalse();
    });

    it('buildsStreamFollowKeyFromSameLengthContentChanges', 0, () => {
      let initialMessages: ChatMessage[] = [
        createChatMessage('m1', 'user', 'chat', '查一下最近一个月干了啥', 1000),
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙丁', 1001)
      ];
      let changedMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙戊', 1001)
      ];
      let traceInitialMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙丁', 1001, ['工具 A 完成'])
      ];
      let traceChangedMessages: ChatMessage[] = [
        initialMessages[0],
        createChatMessage('m2', 'assistant', 'chat', '甲乙丙丁', 1001, ['工具 B 完成'])
      ];

      expect(chatMessagesStreamFollowKey('session-a', initialMessages, true) ===
        chatMessagesStreamFollowKey('session-a', changedMessages, true)).assertFalse();
      expect(chatMessagesStreamFollowKey('session-a', traceInitialMessages, true) ===
        chatMessagesStreamFollowKey('session-a', traceChangedMessages, true)).assertFalse();
    });

    it('compactsLongPreviewFromPrefixOnly', 0, () => {
      let longText = '长文标题\n\n第一段内容' + ' 很长'.repeat(1000) + ' 结尾';

      let preview = compactChatPreviewText(longText, 36);

      expect(preview.indexOf('长文标题 第一段内容') === 0).assertTrue();
      expect(preview.endsWith('...')).assertTrue();
      expect(preview.indexOf('结尾')).assertEqual(-1);
    });

    it('throttlesStreamingContentFlushes', 0, () => {
      let initial: ChatStreamUpdateFlushState = {
        lastFlushAt: 0,
        lastFlushedLength: 0,
        timerScheduled: false
      };

      expect(shouldFlushChatStreamUpdate(1000, 1, initial)).assertTrue();

      let flushed = chatStreamUpdateStateAfterFlush(1000, 1, false);
      expect(shouldFlushChatStreamUpdate(1000 + CHAT_STREAM_FLUSH_INTERVAL_MS - 1, 20, flushed)).assertFalse();
      expect(shouldFlushChatStreamUpdate(1000 + CHAT_STREAM_FLUSH_INTERVAL_MS, 20, flushed)).assertTrue();
      expect(shouldFlushChatStreamUpdate(1001, 1 + CHAT_STREAM_FLUSH_CHAR_DELTA, flushed)).assertTrue();

      let waiting: ChatStreamUpdateFlushState = {
        lastFlushAt: flushed.lastFlushAt,
        lastFlushedLength: flushed.lastFlushedLength,
        timerScheduled: true
      };
      expect(shouldFlushChatStreamUpdate(1001, 1 + CHAT_STREAM_FLUSH_CHAR_DELTA, waiting)).assertFalse();
      expect(chatStreamUpdateDelayMs(1000 + 100, flushed)).assertEqual(CHAT_STREAM_FLUSH_INTERVAL_MS - 100);
    });

    it('splitsAssistantThinkingFromVisibleAnswer', 0, () => {
      let parts = splitAssistantThinkingContent('<think>\n先分析问题。\n</think>\n最终回答。');

      expect(parts.thinkingContent).assertEqual('先分析问题。');
      expect(parts.content).assertEqual('最终回答。');
    });

    it('splitsAssistantThinkingWhenOpeningTagIsMissing', 0, () => {
      let parts = splitAssistantThinkingContent('先分析问题。\n</think>\n最终回答。');

      expect(parts.thinkingContent).assertEqual('先分析问题。');
      expect(parts.content).assertEqual('最终回答。');
    });

    it('keepsPartialStreamingThinkingOutOfVisibleAnswer', 0, () => {
      let parts = splitAssistantThinkingContent('<think>\n正在分析第一步');

      expect(parts.thinkingContent).assertEqual('正在分析第一步');
      expect(parts.content).assertEqual('');
    });

    it('streamsThinkingContentBeforeClosingTagWhenThinkingEnabled', 0, () => {
      let state = createChatStreamThinkingState(true);
      let thinking = '';
      let content = '';

      let first = parseChatStreamThinkingDelta('先分析问题。', state);
      state = first.state;
      thinking += first.thinkingDelta;
      content += first.contentDelta;
      let rendered = splitAssistantThinkingContent(buildAssistantStreamingRenderContent(content, thinking));

      expect(first.thinkingDelta).assertEqual('先分析问题。');
      expect(first.contentDelta).assertEqual('');
      expect(rendered.thinkingContent).assertEqual('先分析问题。');
      expect(rendered.content).assertEqual('');
    });

    it('streamsVisibleContentAfterSplitClosingThinkTag', 0, () => {
      let state = createChatStreamThinkingState(true);
      let thinking = '';
      let content = '';

      let first = parseChatStreamThinkingDelta('先分析</thi', state);
      state = first.state;
      thinking += first.thinkingDelta;
      content += first.contentDelta;
      let second = parseChatStreamThinkingDelta('nk>\n最终回答。', state);
      state = second.state;
      thinking += second.thinkingDelta;
      content += second.contentDelta;

      expect(first.thinkingDelta).assertEqual('先分析');
      expect(first.contentDelta).assertEqual('');
      expect(second.thinkingDelta).assertEqual('');
      expect(second.contentDelta).assertEqual('\n最终回答。');
      expect(state.inThinking).assertFalse();
      expect(state.pendingTag).assertEqual('');
      let rendered = splitAssistantThinkingContent(buildAssistantStreamingRenderContent(content, thinking));
      expect(rendered.thinkingContent).assertEqual('先分析');
      expect(rendered.content).assertEqual('最终回答。');
    });

    it('doesNotTreatContentAsThinkingWhenThinkingDisabled', 0, () => {
      let state = createChatStreamThinkingState(false);

      let parsed = parseChatStreamThinkingDelta('先分析</think>最终回答。', state);

      expect(parsed.thinkingDelta).assertEqual('');
      expect(parsed.contentDelta).assertEqual('先分析</think>最终回答。');
      expect(parsed.state.inThinking).assertFalse();
    });

    it('dropsSplitOpeningThinkTagDuringThinkingStream', 0, () => {
      let state = createChatStreamThinkingState(true);
      let first = parseChatStreamThinkingDelta('<thi', state);
      let second = parseChatStreamThinkingDelta('nk>先分析', first.state);

      expect(first.thinkingDelta).assertEqual('');
      expect(first.contentDelta).assertEqual('');
      expect(second.thinkingDelta).assertEqual('先分析');
      expect(second.contentDelta).assertEqual('');
    });

    it('createsAssistantMessageWithCollapsedThinkingModule', 0, () => {
      let message = createChatMessage('assistant-1', 'assistant', 'chat',
        '<think>\n先分析。\n</think>\n回答正文。', 1000);

      expect(message.content).assertEqual('回答正文。');
      expect(message.thinkingContent).assertEqual('先分析。');
      expect(message.thinkingCollapsed).assertTrue();

      let toggled = toggleChatMessageThinkingCollapsed([message], 'assistant-1');

      expect(toggled[0].thinkingCollapsed).assertFalse();
      expect(chatMessageRenderKey(message) === chatMessageRenderKey(toggled[0])).assertFalse();
    });

    it('keepsTaskTraceCollapsedByDefaultAndTogglesIt', 0, () => {
      let message = createChatMessage('trace-1', 'task', CHAT_MESSAGE_KIND_TASK_TRACE, '执行过程', 1000,
        ['Planner started', 'Decider selected click']);

      expect(message.collapsed).assertTrue();

      let toggled = toggleChatMessageCollapsed([message], 'trace-1');

      expect(toggled[0].collapsed).assertFalse();
      expect(chatMessageRenderKey(message) === chatMessageRenderKey(toggled[0])).assertFalse();
    });

    it('cloudContextSkipsTaskTraceMessages', 0, () => {
      let messages: ChatMessage[] = [
        createChatMessage('u1', 'user', 'chat', '你好', 1000),
        createChatMessage('t1', 'task', CHAT_MESSAGE_KIND_TASK_TRACE, '执行过程', 1001, ['step 1']),
        createChatMessage('r1', 'task', CHAT_MESSAGE_KIND_TASK_RESULT, '执行完成', 1002),
        createChatMessage('a1', 'assistant', 'chat', '你好，我可以帮你。', 1003)
      ];

      let context = buildCloudContextMessages(messages);

      expect(context.length).assertEqual(3);
      expect(context[0].role).assertEqual('user');
      expect(context[1].role).assertEqual('assistant');
      let taskResultContent = context[1].content as string;
      expect(taskResultContent).assertEqual('执行完成');
      expect(context[2].role).assertEqual('assistant');
    });

    it('cloudContextSkipsReactToolTraceMessages', 0, () => {
      let messages: ChatMessage[] = [
        createChatMessage('u1', 'user', 'chat', '查一下今天咖啡记录', 1000),
        createChatMessage('trace1', 'task', CHAT_MESSAGE_KIND_TASK_TRACE, '工具调用过程', 1001,
          ['工具：lookup_note\n参数：{"query":"咖啡"}\n结果：{"ok":true}']),
        createChatMessage('a1', 'assistant', 'chat', '今天有一条咖啡记录。', 1002)
      ];

      let context = buildCloudContextMessages(messages);

      expect(context.length).assertEqual(2);
      expect(context[0].role).assertEqual('user');
      expect(context[1].role).assertEqual('assistant');
      expect(context[1].content as string).assertEqual('今天有一条咖啡记录。');
    });

    it('cloudContextSkipsContextCompressionNoticeMessages', 0, () => {
      let messages: ChatMessage[] = [
        createChatMessage('u1', 'user', 'chat', '继续总结', 1000),
        createChatMessage('notice1', 'system', CHAT_MESSAGE_KIND_CONTEXT_NOTICE, '历史过长，已自动压缩上下文', 1001),
        createChatMessage('a1', 'assistant', 'chat', '已继续处理。', 1002)
      ];

      let context = buildCloudContextMessages(messages);

      expect(context.length).assertEqual(2);
      expect(context[0].role).assertEqual('user');
      expect(context[1].role).assertEqual('assistant');
      expect(context[1].content as string).assertEqual('已继续处理。');
    });

    it('persistsContextSummaryMetadataWithoutChangingOriginalMessages', 0, () => {
      let root = nextTestRoot('context-summary');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      session.contextSummary = '较早历史摘要';
      session.contextSummaryUpdatedAt = 2000;
      session.contextSummaryUntilMessageId = 'm-old';
      session.contextSummaryMessageCount = 12;
      session.messages = [
        createChatMessage('m1', 'user', 'chat', '原始用户消息', 1001),
        createChatMessage('m2', 'assistant', 'chat', '原始助手消息', 1002)
      ];
      ChatSessionStorage.saveSession(root, session);

      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        expect(reloaded.contextSummary).assertEqual('较早历史摘要');
        expect(reloaded.contextSummaryUpdatedAt).assertEqual(2000);
        expect(reloaded.contextSummaryUntilMessageId).assertEqual('m-old');
        expect(reloaded.contextSummaryMessageCount).assertEqual(12);
        expect(reloaded.messages.length).assertEqual(2);
        expect(reloaded.messages[0].content).assertEqual('原始用户消息');
        expect(reloaded.messages[1].content).assertEqual('原始助手消息');
      }

      cleanupPath(root);
    });

    it('loadsLegacySessionAndIndexWithDefaultMenuMetadata', 0, () => {
      let root = nextTestRoot('legacy-menu-metadata');
      prepareTestRoot(root);
      ChatSessionStorage.ensureWorkspace(root);
      let legacySessionId = 'legacy-session';
      let legacyJson = '{"id":"legacy-session","title":"旧会话","mode":"' + CHAT_MODE_CLOUD_AGENT +
        '","createdAt":1000,"updatedAt":2000,"messages":[]}';
      ChatSessionStorage.writeText(ChatSessionStorage.sessionPath(root, legacySessionId), legacyJson);
      let indexJson = '{"sessions":[{"id":"legacy-summary","title":"旧摘要","mode":"' + CHAT_MODE_CLOUD_AGENT +
        '","fileName":"legacy-summary.json","createdAt":1000,"updatedAt":2000,' +
        '"messageCount":2,"lastMessagePreview":"旧消息"}]}';
      ChatSessionStorage.writeText(ChatSessionStorage.indexPath(root), indexJson);

      let loaded = ChatSessionStorage.loadSession(root, legacySessionId);
      let index = ChatSessionStorage.loadIndex(root);

      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.customTitle).assertEqual('');
        expect(loaded.pinned).assertFalse();
        expect(loaded.pinnedAt).assertEqual(0);
      }
      expect(index.length).assertEqual(1);
      expect(index[0].customTitle).assertEqual('');
      expect(index[0].pinned).assertFalse();
      expect(index[0].pinnedAt).assertEqual(0);

      cleanupPath(root);
    });

    it('usesCustomTitleAndUpdatesSessionRenderKey', 0, () => {
      let root = nextTestRoot('custom-title-summary');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      session.customTitle = '自定义标题';
      session.messages = [
        createChatMessage('m1', 'user', 'chat', '第一条用户消息标题', 1001)
      ];
      ChatSessionStorage.saveSession(root, session);
      let index = ChatSessionStorage.loadIndex(root);
      let renamedKey = chatSessionRenderKey(index[0]);
      session.customTitle = '另一个标题';
      ChatSessionStorage.saveSession(root, session);
      let nextIndex = ChatSessionStorage.loadIndex(root);

      expect(index.length).assertEqual(1);
      expect(index[0].title).assertEqual('自定义标题');
      expect(index[0].customTitle).assertEqual('自定义标题');
      expect(chatSessionRenderKey(nextIndex[0]) === renamedKey).assertFalse();

      cleanupPath(root);
    });

    it('fallsBackWhenTrimmedCustomTitleIsEmpty', 0, () => {
      let root = nextTestRoot('blank-custom-title');
      prepareTestRoot(root);

      let withMessage = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      withMessage.customTitle = '   ';
      withMessage.messages = [
        createChatMessage('m1', 'user', 'chat', '第一条用户消息标题', 1001)
      ];
      ChatSessionStorage.saveSession(root, withMessage);
      let empty = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      empty.customTitle = '\n\t ';
      ChatSessionStorage.saveSession(root, empty);

      let withMessageSummary = findSummaryById(ChatSessionStorage.loadIndex(root), withMessage.id);
      let emptySummary = findSummaryById(ChatSessionStorage.loadIndex(root), empty.id);

      expect(withMessageSummary !== null).assertTrue();
      if (withMessageSummary !== null) {
        expect(withMessageSummary.title).assertEqual('第一条用户消息标题');
        expect(withMessageSummary.customTitle).assertEqual('');
      }
      expect(emptySummary !== null).assertTrue();
      if (emptySummary !== null) {
        expect(emptySummary.title).assertEqual(defaultChatSessionTitle(CHAT_MODE_CLOUD_AGENT));
        expect(emptySummary.customTitle).assertEqual('');
      }

      cleanupPath(root);
    });

    it('renamesSessionWithoutChangingMessagesOrUpdatedAt', 0, () => {
      let root = nextTestRoot('rename-session');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      session.updatedAt = 3000;
      session.messages = [
        createChatMessage('m1', 'user', 'chat', '原始用户消息', 1001),
        createChatMessage('m2', 'assistant', 'chat', '原始助手消息', 1002)
      ];
      ChatSessionStorage.saveSession(root, session);

      let renamed = ChatSessionStorage.renameSession(root, session.id,
        '  1234567890123456789012345678901234567890EXTRA  ');
      let reloaded = ChatSessionStorage.loadSession(root, session.id);
      let index = ChatSessionStorage.loadIndex(root);

      expect(renamed !== null).assertTrue();
      expect(reloaded !== null).assertTrue();
      if (renamed !== null && reloaded !== null) {
        expect(renamed.customTitle).assertEqual('1234567890123456789012345678901234567890');
        expect(reloaded.updatedAt).assertEqual(3000);
        expect(reloaded.messages.length).assertEqual(2);
      }
      expect(index[0].title).assertEqual('1234567890123456789012345678901234567890');

      cleanupPath(root);
    });

    it('sortsPinnedSessionsBeforeNormalSessionsByPinnedAt', 0, () => {
      let root = nextTestRoot('pinned-sort');
      prepareTestRoot(root);

      let oldNormal = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      oldNormal.updatedAt = 9000;
      ChatSessionStorage.saveSession(root, oldNormal);
      let firstPinned = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      firstPinned.updatedAt = 2000;
      ChatSessionStorage.saveSession(root, firstPinned);
      let secondPinned = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 3000);
      secondPinned.updatedAt = 3000;
      ChatSessionStorage.saveSession(root, secondPinned);

      ChatSessionStorage.setSessionPinned(root, firstPinned.id, true, 5000);
      ChatSessionStorage.setSessionPinned(root, secondPinned.id, true, 7000);
      let index = ChatSessionStorage.loadIndex(root);

      expect(index.length).assertEqual(3);
      expect(index[0].id).assertEqual(secondPinned.id);
      expect(index[1].id).assertEqual(firstPinned.id);
      expect(index[2].id).assertEqual(oldNormal.id);

      cleanupPath(root);
    });

    it('returnsUnpinnedSessionsToUpdatedAtSorting', 0, () => {
      let root = nextTestRoot('unpinned-sort');
      prepareTestRoot(root);

      let newer = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      newer.updatedAt = 9000;
      ChatSessionStorage.saveSession(root, newer);
      let pinned = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      pinned.updatedAt = 1000;
      ChatSessionStorage.saveSession(root, pinned);
      ChatSessionStorage.setSessionPinned(root, pinned.id, true, 8000);
      ChatSessionStorage.setSessionPinned(root, pinned.id, false, 9000);
      let index = ChatSessionStorage.loadIndex(root);

      expect(index[0].id).assertEqual(newer.id);
      expect(index[1].id).assertEqual(pinned.id);
      expect(index[1].pinned).assertFalse();
      expect(index[1].pinnedAt).assertEqual(0);

      cleanupPath(root);
    });

    it('controllerRenamesAndPinsBackgroundSession', 0, () => {
      let root = nextTestRoot('controller-session-menu');
      prepareTestRoot(root);

      let active = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let background = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: active.id,
        activeMessages: active.messages,
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: active
      };

      let renamed = ChatSessionController.renameSession(root, state, background.id, '后台会话');
      let pinned = ChatSessionController.toggleSessionPinned(root, renamed, background.id, 5000);
      let backgroundSummary = findSummaryById(pinned.sessions, background.id);

      expect(pinned.activeSessionId).assertEqual(active.id);
      expect(backgroundSummary !== null).assertTrue();
      if (backgroundSummary !== null) {
        expect(backgroundSummary.customTitle).assertEqual('后台会话');
        expect(backgroundSummary.pinned).assertTrue();
        expect(backgroundSummary.pinnedAt).assertEqual(5000);
      }

      cleanupPath(root);
    });

    it('persistsSessionIndexAndDeletesSessionFile', 0, () => {
      let root = nextTestRoot('persist');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.appendMessage(root, session.id,
        createChatMessage('m1', 'user', 'chat', '第一条消息', 1001));

      let index = ChatSessionStorage.loadIndex(root);
      expect(index.length).assertEqual(1);
      expect(index[0].messageCount).assertEqual(1);
      expect(index[0].lastMessagePreview).assertEqual('第一条消息');

      let deleted = ChatSessionStorage.deleteSession(root, session.id);
      expect(deleted).assertTrue();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionPath(root, session.id))).assertFalse();

      cleanupPath(root);
    });

    it('createsUniqueSessionIdAndCleansMissingFileIndex', 0, () => {
      let root = nextTestRoot('unique');
      prepareTestRoot(root);

      let first = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let second = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);

      expect(first.id).assertEqual('chat-1000');
      expect(second.id).assertEqual('chat-1000-1');

      fs.unlinkSync(ChatSessionStorage.sessionPath(root, first.id));
      let deleted = ChatSessionStorage.deleteSession(root, first.id);
      let index = ChatSessionStorage.loadIndex(root);

      expect(deleted).assertTrue();
      expect(index.length).assertEqual(1);
      expect(index[0].id).assertEqual(second.id);

      cleanupPath(root);
    });

    it('toggleTaskTracePersistsCollapsedState', 0, () => {
      let root = nextTestRoot('toggle');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let trace = createChatMessage('trace-1', 'task', CHAT_MESSAGE_KIND_TASK_TRACE, '云端任务执行过程', 1001,
        ['动作：click']);
      let saved = ChatSessionStorage.appendMessage(root, session.id, trace);
      expect(saved !== null).assertTrue();

      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: session.id,
        activeMessages: [trace],
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: saved
      };
      let next = ChatSessionController.toggleTaskTrace(root, state, 'trace-1');
      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(next.activeMessages[0].collapsed).assertFalse();
      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        expect(reloaded.messages[0].collapsed).assertFalse();
      }

      cleanupPath(root);
    });

    it('updatesAssistantMessageContentAndSplitsStreamingThinking', 0, () => {
      let root = nextTestRoot('stream-update');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let assistant = createChatMessage('assistant-1', 'assistant', 'chat', '', 1001);
      let saved = ChatSessionStorage.appendMessage(root, session.id, assistant);
      expect(saved !== null).assertTrue();
      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: session.id,
        activeMessages: [assistant],
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: saved
      };

      let next = ChatSessionController.updateMessageContent(root, state, 'assistant-1',
        '<think>\n先分析。\n</think>\n最终回答。', ['工具：lookup_note']);
      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(next.activeMessages[0].content).assertEqual('最终回答。');
      expect(next.activeMessages[0].thinkingContent).assertEqual('先分析。');
      expect(next.activeMessages[0].trace.length).assertEqual(1);
      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        expect(reloaded.messages[0].content).assertEqual('最终回答。');
      }

      cleanupPath(root);
    });

    it('expandsThinkingModuleWhenStreamingThinkingStarts', 0, () => {
      let root = nextTestRoot('stream-thinking-expanded');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let assistant = createChatMessage('assistant-1', 'assistant', 'chat', '', 1001);
      let saved = ChatSessionStorage.appendMessage(root, session.id, assistant);
      expect(saved !== null).assertTrue();
      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: session.id,
        activeMessages: [assistant],
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: saved
      };

      let next = ChatSessionController.updateMessageContent(root, state, 'assistant-1',
        '<think>正在分析问题。', []);
      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(next.activeMessages[0].content).assertEqual('');
      expect(next.activeMessages[0].thinkingContent).assertEqual('正在分析问题。');
      expect(next.activeMessages[0].thinkingCollapsed).assertFalse();
      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        expect(reloaded.messages[0].thinkingCollapsed).assertFalse();
      }

      cleanupPath(root);
    });

    it('createsMessageWithMultipleImageAttachmentsAndKeepsLegacyFirstImagePath', 0, () => {
      let message = createChatMessage('u1', 'user', 'chat', '看看这些图片', 1000, [],
        'photo://image/1', ['photo://image/1', 'photo://image/2']);
      let imagePaths = chatMessageImagePaths(message);

      expect(message.imagePath === undefined ? '' : message.imagePath).assertEqual('photo://image/1');
      expect(imagePaths.length).assertEqual(2);
      expect(imagePaths[0]).assertEqual('photo://image/1');
      expect(imagePaths[1]).assertEqual('photo://image/2');
    });

    it('readsLegacySingleImagePathAsImagePathList', 0, () => {
      let message = createChatMessage('u1', 'user', 'chat', '看看这张图片', 1000, [], 'photo://legacy/1');
      let imagePaths = chatMessageImagePaths(message);

      expect(imagePaths.length).assertEqual(1);
      expect(imagePaths[0]).assertEqual('photo://legacy/1');
    });

    it('persistsMultipleImageAttachmentsInSessionMessages', 0, () => {
      let root = nextTestRoot('multi-image-message');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      session.messages = [
        createChatMessage('u1', 'user', 'chat', '请分析这些图片', 1001, [],
          'photo://image/1', ['photo://image/1', 'photo://image/2'])
      ];
      ChatSessionStorage.saveSession(root, session);

      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        let imagePaths = chatMessageImagePaths(reloaded.messages[0]);
        expect(reloaded.messages[0].imagePath === undefined ? '' : reloaded.messages[0].imagePath)
          .assertEqual('photo://image/1');
        expect(imagePaths.length).assertEqual(2);
        expect(imagePaths[1]).assertEqual('photo://image/2');
      }

      cleanupPath(root);
    });

    it('attachesTaskResultImageOnlyToTargetSession', 0, () => {
      let root = nextTestRoot('image');
      prepareTestRoot(root);

      let first = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.appendMessage(root, first.id,
        createChatMessage('r1', 'task', CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行完成。', 1001));
      let second = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      ChatSessionStorage.appendMessage(root, second.id,
        createChatMessage('u1', 'user', 'chat', '新的会话', 2001));

      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: second.id,
        activeMessages: [createChatMessage('u1', 'user', 'chat', '新的会话', 2001)],
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: second
      };
      let next = ChatSessionController.attachTaskResultImage(root, state, first.id, 'file:///tmp/snapshot.jpg');
      let reloadedFirst = ChatSessionStorage.loadSession(root, first.id);
      let reloadedSecond = ChatSessionStorage.loadSession(root, second.id);

      expect(next.activeSessionId).assertEqual(second.id);
      expect(next.activeMessages.length).assertEqual(1);
      expect(next.activeMessages[0].imagePath === undefined ? '' : next.activeMessages[0].imagePath).assertEqual('');
      expect(reloadedFirst !== null).assertTrue();
      if (reloadedFirst !== null) {
        expect(reloadedFirst.messages[0].imagePath === undefined ? '' : reloadedFirst.messages[0].imagePath)
          .assertEqual('file:///tmp/snapshot.jpg');
      }
      expect(reloadedSecond !== null).assertTrue();
      if (reloadedSecond !== null) {
        expect(reloadedSecond.messages[0].imagePath === undefined ? '' : reloadedSecond.messages[0].imagePath)
          .assertEqual('');
      }

      cleanupPath(root);
    });

    it('copiesTaskResultImageIntoTargetSessionAssets', 0, () => {
      let root = nextTestRoot('image-assets');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.appendMessage(root, session.id,
        createChatMessage('r1', 'task', CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行完成。', 1001));
      let sourcePath = root + '/agent_snapshot_1001.jpg';
      ChatSessionStorage.writeText(sourcePath, 'fake-image');

      let state: ChatSessionViewState = {
        sessions: ChatSessionStorage.loadIndex(root),
        activeSessionId: session.id,
        activeMessages: session.messages,
        mode: CHAT_MODE_CLOUD_AGENT,
        activeSession: session
      };
      let next = ChatSessionController.attachTaskResultImage(root, state, session.id, 'file://' + sourcePath);
      let expectedPath = ChatSessionStorage.sessionAssetPath(root, session.id, 'agent_snapshot_1001.jpg');
      let reloaded = ChatSessionStorage.loadSession(root, session.id);

      expect(ChatSessionStorage.pathExists(sourcePath)).assertTrue();
      expect(ChatSessionStorage.pathExists(expectedPath)).assertTrue();
      expect(next.activeMessages[0].imagePath === undefined ? '' : next.activeMessages[0].imagePath)
        .assertEqual('file://' + expectedPath);
      expect(reloaded !== null).assertTrue();
      if (reloaded !== null) {
        expect(reloaded.messages[0].imagePath === undefined ? '' : reloaded.messages[0].imagePath)
          .assertEqual('file://' + expectedPath);
      }

      cleanupPath(root);
    });

    it('deleteSessionRemovesSessionAssetFiles', 0, () => {
      let root = nextTestRoot('delete-assets');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.ensureSessionAssetsDir(root, session.id);
      let imagePath = ChatSessionStorage.sessionAssetPath(root, session.id, 'agent_snapshot_1001.jpg');
      ChatSessionStorage.writeText(imagePath, 'fake-image');

      let deleted = ChatSessionStorage.deleteSession(root, session.id);

      expect(deleted).assertTrue();
      expect(ChatSessionStorage.pathExists(imagePath)).assertFalse();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, session.id))).assertFalse();

      cleanupPath(root);
    });

    it('deleteSessionRemovesTtsVoiceCacheFiles', 0, () => {
      let root = nextTestRoot('delete-tts-assets');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.ensureSessionAssetsDir(root, session.id);
      let voicePath = ChatSessionStorage.sessionAssetPath(root, session.id, 'assistant-1-tts.wav');
      ChatSessionStorage.writeText(voicePath, 'fake-wav');

      let deleted = ChatSessionStorage.deleteSession(root, session.id);

      expect(deleted).assertTrue();
      expect(ChatSessionStorage.pathExists(voicePath)).assertFalse();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, session.id))).assertFalse();

      cleanupPath(root);
    });

    it('sessionExistsTracksDeletedSessionRecords', 0, () => {
      let root = nextTestRoot('session-exists-after-delete');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.ensureSessionAssetsDir(root, session.id);

      expect(ChatSessionStorage.sessionExists(root, session.id)).assertTrue();

      ChatSessionStorage.deleteSession(root, session.id);

      // 覆盖异步 TTS 保存前的会话存活判断，避免删除后继续落盘缓存。
      expect(ChatSessionStorage.sessionExists(root, session.id)).assertFalse();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, session.id))).assertFalse();

      cleanupPath(root);
    });

    it('deleteSessionAssetsDirRemovesTtsCacheWithoutDeletingSessionRecord', 0, () => {
      let root = nextTestRoot('delete-session-assets-dir-only');
      prepareTestRoot(root);

      let session = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      ChatSessionStorage.ensureSessionAssetsDir(root, session.id);
      let voicePath = ChatSessionStorage.sessionAssetPath(root, session.id, 'assistant-1-tts.wav');
      ChatSessionStorage.writeText(voicePath, 'fake-wav');

      ChatSessionStorage.deleteSessionAssetsDir(root, session.id);

      // 覆盖 TTS 删除竞态的补偿清理：只移除缓存目录，不破坏仍存在的会话记录。
      expect(ChatSessionStorage.pathExists(voicePath)).assertFalse();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, session.id))).assertFalse();
      expect(ChatSessionStorage.sessionExists(root, session.id)).assertTrue();

      cleanupPath(root);
    });

    it('deleteSessionKeepsOtherSessionAssetFiles', 0, () => {
      let root = nextTestRoot('delete-assets-isolated');
      prepareTestRoot(root);

      let first = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let second = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      ChatSessionStorage.ensureSessionAssetsDir(root, first.id);
      ChatSessionStorage.ensureSessionAssetsDir(root, second.id);
      let firstImagePath = ChatSessionStorage.sessionAssetPath(root, first.id, 'agent_snapshot_1001.jpg');
      let secondImagePath = ChatSessionStorage.sessionAssetPath(root, second.id, 'agent_snapshot_2001.jpg');
      ChatSessionStorage.writeText(firstImagePath, 'first-image');
      ChatSessionStorage.writeText(secondImagePath, 'second-image');

      let deleted = ChatSessionStorage.deleteSession(root, first.id);

      expect(deleted).assertTrue();
      expect(ChatSessionStorage.pathExists(firstImagePath)).assertFalse();
      expect(ChatSessionStorage.pathExists(secondImagePath)).assertTrue();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, second.id))).assertTrue();

      cleanupPath(root);
    });

    it('deleteSessionKeepsOtherSessionTtsVoiceCacheFiles', 0, () => {
      let root = nextTestRoot('delete-tts-assets-isolated');
      prepareTestRoot(root);

      let first = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 1000);
      let second = ChatSessionStorage.createSession(root, CHAT_MODE_CLOUD_AGENT, 2000);
      ChatSessionStorage.ensureSessionAssetsDir(root, first.id);
      ChatSessionStorage.ensureSessionAssetsDir(root, second.id);
      let firstVoicePath = ChatSessionStorage.sessionAssetPath(root, first.id, 'assistant-1-tts.wav');
      let secondVoicePath = ChatSessionStorage.sessionAssetPath(root, second.id, 'assistant-2-tts.wav');
      ChatSessionStorage.writeText(firstVoicePath, 'first-wav');
      ChatSessionStorage.writeText(secondVoicePath, 'second-wav');

      let deleted = ChatSessionStorage.deleteSession(root, first.id);

      expect(deleted).assertTrue();
      expect(ChatSessionStorage.pathExists(firstVoicePath)).assertFalse();
      expect(ChatSessionStorage.pathExists(secondVoicePath)).assertTrue();
      expect(ChatSessionStorage.pathExists(ChatSessionStorage.sessionAssetsDir(root, second.id))).assertTrue();

      cleanupPath(root);
    });
  });
}
