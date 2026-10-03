import {
  CHAT_MESSAGE_KIND_CHAT,
  CHAT_MESSAGE_KIND_TASK_RESULT,
  CHAT_MESSAGE_KIND_TASK_TRACE,
  CHAT_MODE_CLOUD_AGENT,
  ChatAssistantThinkingParts,
  ChatMessage,
  ChatSessionRecord,
  ChatSessionSummary,
  chatMessageImagePath,
  chatMessageImagePaths,
  chatMessageThinkingCollapsed,
  chatMessageThinkingContent,
  chatMessageVoiceMetadataForStorage,
  splitAssistantThinkingContent,
  normalizeChatMode,
  toggleChatMessageThinkingCollapsed,
  toggleChatMessageCollapsed
} from './ChatSessionTypes';
import { ChatVoiceMetadata, optionalChatVoiceMetadata } from './VoiceInteractionTypes';
import { ChatSessionStorage } from '../../utils/ChatSessionStorage';
import { DebugSettings } from '../../utils/DebugSettings';

export interface ChatSessionViewState {
  sessions: ChatSessionSummary[];
  activeSessionId: string;
  activeMessages: ChatMessage[];
  mode: string;
  activeSession: ChatSessionRecord | null;
}

export class ChatSessionController {
  static emptyState(mode: string = CHAT_MODE_CLOUD_AGENT): ChatSessionViewState {
    return {
      sessions: [],
      activeSessionId: '',
      activeMessages: [],
      mode: normalizeChatMode(mode),
      activeSession: null
    };
  }

  static init(filesDir: string, mode: string): ChatSessionViewState {
    if (filesDir.length === 0) {
      return ChatSessionController.emptyState(mode);
    }
    ChatSessionStorage.ensureWorkspace(filesDir);
    let sessions = ChatSessionStorage.loadIndex(filesDir);
    if (sessions.length === 0) {
      let session = ChatSessionStorage.createSession(filesDir, mode);
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    let firstSession = ChatSessionStorage.loadSession(filesDir, sessions[0].id);
    if (firstSession === null) {
      let session = ChatSessionStorage.createSession(filesDir, mode);
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateFromSession(filesDir, firstSession);
  }

  static ensureActive(filesDir: string, state: ChatSessionViewState, mode: string): ChatSessionViewState {
    if (filesDir.length === 0) {
      return ChatSessionController.emptyState(mode);
    }
    if (state.activeSessionId.length > 0) {
      let session = ChatSessionStorage.loadSession(filesDir, state.activeSessionId);
      if (session !== null) {
        return ChatSessionController.stateFromSession(filesDir, session);
      }
    }
    let created = ChatSessionStorage.createSession(filesDir, mode);
    return ChatSessionController.stateFromSession(filesDir, created);
  }

  static appendMessage(filesDir: string, state: ChatSessionViewState, mode: string,
    message: ChatMessage): ChatSessionViewState {
    if (message.kind === CHAT_MESSAGE_KIND_TASK_TRACE && !DebugSettings.isEnabled()) { return state; }
    let active = ChatSessionController.ensureActive(filesDir, state, mode);
    if (active.activeSession === null) {
      return active;
    }
    let session = ChatSessionStorage.appendMessage(filesDir, active.activeSession.id, message);
    if (session === null) {
      return active;
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static appendMessageToSession(filesDir: string, state: ChatSessionViewState, sessionId: string,
    message: ChatMessage): ChatSessionViewState {
    if (message.kind === CHAT_MESSAGE_KIND_TASK_TRACE && !DebugSettings.isEnabled()) { return state; }
    if (filesDir.length === 0 || sessionId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.appendMessage(filesDir, sessionId, message);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    if (state.activeSessionId === sessionId) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
  }

  static appendTaskTraceLine(filesDir: string, state: ChatSessionViewState, mode: string, line: string,
    messageId: string): ChatSessionViewState {
    return ChatSessionController.appendTaskTraceLineToSession(filesDir, state, state.activeSessionId, line, messageId);
  }

  static appendTaskTraceLineToSession(filesDir: string, state: ChatSessionViewState, sessionId: string, line: string,
    messageId: string): ChatSessionViewState {
    if (!DebugSettings.isEnabled()) { return state; }
    if (filesDir.length === 0) {
      return state;
    }
    if (sessionId.length === 0) {
      return state;
    }
    // App 内 Agent loop 是异步执行的，用户切换会话后仍要把步骤写回发起任务的会话。
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null || session.messages.length === 0) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let messages = session.messages.slice();
    let traceIndex = ChatSessionController.findTaskTraceIndex(messages, messageId);
    if (traceIndex < 0) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    let lastMessage = messages[traceIndex];
    let trace = lastMessage.trace.slice();
    trace.push(line);
    let updatedTraceMessage: ChatMessage = {
      id: lastMessage.id,
      role: lastMessage.role,
      kind: lastMessage.kind,
      content: lastMessage.content,
      thinkingContent: chatMessageThinkingContent(lastMessage),
      thinkingCollapsed: chatMessageThinkingCollapsed(lastMessage),
      trace: trace,
      collapsed: lastMessage.collapsed,
      createdAt: lastMessage.createdAt,
      imagePath: chatMessageImagePath(lastMessage),
      imagePaths: chatMessageImagePaths(lastMessage)
    };
    let traceVoiceMetadata = chatMessageVoiceMetadataForStorage(lastMessage);
    if (traceVoiceMetadata !== undefined) {
      updatedTraceMessage.voice = traceVoiceMetadata;
    }
    messages[traceIndex] = updatedTraceMessage;
    session.messages = messages;
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    if (state.activeSessionId !== sessionId) {
      return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static attachTaskResultImage(filesDir: string, state: ChatSessionViewState, sessionId: string,
    imagePath: string): ChatSessionViewState {
    if (filesDir.length === 0 || sessionId.length === 0 || imagePath.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let messages = session.messages.slice();
    let resultIndex = ChatSessionController.findLatestTaskResultIndex(messages);
    if (resultIndex < 0) {
      return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
    }
    let sessionImagePath = ChatSessionStorage.adoptImageForSession(filesDir, sessionId, imagePath);
    let resultMessage = messages[resultIndex];
    let updatedResultMessage: ChatMessage = {
      id: resultMessage.id,
      role: resultMessage.role,
      kind: resultMessage.kind,
      content: resultMessage.content,
      thinkingContent: chatMessageThinkingContent(resultMessage),
      thinkingCollapsed: chatMessageThinkingCollapsed(resultMessage),
      trace: resultMessage.trace.slice(),
      collapsed: resultMessage.collapsed,
      createdAt: resultMessage.createdAt,
      imagePath: sessionImagePath,
      imagePaths: [sessionImagePath]
    };
    let resultVoiceMetadata = chatMessageVoiceMetadataForStorage(resultMessage);
    if (resultVoiceMetadata !== undefined) {
      updatedResultMessage.voice = resultVoiceMetadata;
    }
    messages[resultIndex] = updatedResultMessage;
    session.messages = messages;
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    if (state.activeSessionId === sessionId) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
  }

  static createSession(filesDir: string, state: ChatSessionViewState, mode: string): ChatSessionViewState {
    if (filesDir.length === 0) {
      return ChatSessionController.emptyState(mode);
    }
    let nextMode = mode.length > 0 ? mode : state.mode;
    let session = ChatSessionStorage.createSession(filesDir, nextMode);
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static selectSession(filesDir: string, state: ChatSessionViewState, id: string): ChatSessionViewState {
    if (filesDir.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, id);
    if (session === null) {
      return {
        sessions: ChatSessionStorage.loadIndex(filesDir),
        activeSessionId: state.activeSessionId,
        activeMessages: state.activeMessages.slice(),
        mode: normalizeChatMode(state.mode),
        activeSession: null
      };
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static switchMode(filesDir: string, state: ChatSessionViewState, mode: string): ChatSessionViewState {
    let normalizedMode = normalizeChatMode(mode);
    if (state.mode === normalizedMode && state.activeSessionId.length > 0) {
      return state;
    }
    if (filesDir.length === 0) {
      return ChatSessionController.emptyState(normalizedMode);
    }
    let sessions = ChatSessionStorage.loadIndex(filesDir);
    for (let i = 0; i < sessions.length; i++) {
      if (normalizeChatMode(sessions[i].mode) === normalizedMode) {
        return ChatSessionController.selectSession(filesDir, state, sessions[i].id);
      }
    }
    return ChatSessionController.createSession(filesDir, state, normalizedMode);
  }

  static deleteSession(filesDir: string, state: ChatSessionViewState, id: string,
    fallbackMode: string): ChatSessionViewState {
    if (filesDir.length === 0) {
      return state;
    }
    let deleted = ChatSessionStorage.deleteSession(filesDir, id);
    if (!deleted) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let next = ChatSessionStorage.nextSessionAfterDelete(filesDir, id);
    if (next === null) {
      let session = ChatSessionStorage.createSession(filesDir, fallbackMode);
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    let nextSession = ChatSessionStorage.loadSession(filesDir, next.id);
    if (nextSession === null) {
      let session = ChatSessionStorage.createSession(filesDir, fallbackMode);
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateFromSession(filesDir, nextSession);
  }

  static renameSession(filesDir: string, state: ChatSessionViewState, id: string,
    title: string): ChatSessionViewState {
    if (filesDir.length === 0 || id.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.renameSession(filesDir, id, title);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    if (state.activeSessionId === id) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
  }

  static toggleSessionPinned(filesDir: string, state: ChatSessionViewState, id: string,
    now: number = new Date().getTime()): ChatSessionViewState {
    if (filesDir.length === 0 || id.length === 0) {
      return state;
    }
    let current = ChatSessionStorage.loadSession(filesDir, id);
    if (current === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let session = ChatSessionStorage.setSessionPinned(filesDir, id, current.pinned !== true, now);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    if (state.activeSessionId === id) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
  }

  static toggleTaskTrace(filesDir: string, state: ChatSessionViewState, messageId: string): ChatSessionViewState {
    if (filesDir.length === 0 || state.activeSessionId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, state.activeSessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    session.messages = toggleChatMessageCollapsed(session.messages, messageId);
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static toggleThinking(filesDir: string, state: ChatSessionViewState, messageId: string): ChatSessionViewState {
    if (filesDir.length === 0 || state.activeSessionId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, state.activeSessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    session.messages = toggleChatMessageThinkingCollapsed(session.messages, messageId);
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static updateMessageContent(filesDir: string, state: ChatSessionViewState, messageId: string, content: string,
    trace?: string[]): ChatSessionViewState {
    if (filesDir.length === 0 || state.activeSessionId.length === 0 || messageId.length === 0) {
      return state;
    }
    return ChatSessionController.updateMessageContentInSession(filesDir, state, state.activeSessionId, messageId,
      content, trace);
  }

  static updateMessageContentInSession(filesDir: string, state: ChatSessionViewState, sessionId: string,
    messageId: string, content: string, trace?: string[]): ChatSessionViewState {
    if (filesDir.length === 0 || sessionId.length === 0 || messageId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let messages = session.messages.slice();
    let changed = false;
    for (let i = 0; i < messages.length; i++) {
      let message = messages[i];
      if (message.id !== messageId) {
        continue;
      }
      let visibleContent = content;
      let thinkingContent = chatMessageThinkingContent(message);
      let thinkingCollapsed = chatMessageThinkingCollapsed(message);
      if (message.role === 'assistant' && message.kind === CHAT_MESSAGE_KIND_CHAT) {
        let previousThinkingContent = chatMessageThinkingContent(message);
        let parts: ChatAssistantThinkingParts = splitAssistantThinkingContent(content);
        visibleContent = parts.content;
        thinkingContent = parts.thinkingContent;
        if (previousThinkingContent.length === 0 && thinkingContent.length > 0) {
          thinkingCollapsed = false;
        }
      }
      let updatedMessage: ChatMessage = {
        id: message.id,
        role: message.role,
        kind: message.kind,
        content: visibleContent,
        thinkingContent: thinkingContent,
        thinkingCollapsed: thinkingCollapsed,
        trace: trace === undefined ? message.trace.slice() : trace.slice(),
        collapsed: message.collapsed,
        createdAt: message.createdAt,
        imagePath: chatMessageImagePath(message),
        imagePaths: chatMessageImagePaths(message)
      };
      let voiceMetadata = chatMessageVoiceMetadataForStorage(message);
      if (voiceMetadata !== undefined) {
        updatedMessage.voice = voiceMetadata;
      }
      messages[i] = updatedMessage;
      changed = true;
      break;
    }
    if (!changed) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    session.messages = messages;
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    if (state.activeSessionId !== sessionId) {
      return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static updateMessageVoiceMetadataInSession(filesDir: string, state: ChatSessionViewState, sessionId: string,
    messageId: string, voice?: ChatVoiceMetadata): ChatSessionViewState {
    if (filesDir.length === 0 || sessionId.length === 0 || messageId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    let messages = session.messages.slice();
    let changed = false;
    for (let i = 0; i < messages.length; i++) {
      let message = messages[i];
      if (message.id !== messageId) {
        continue;
      }
      let updatedMessage: ChatMessage = {
        id: message.id,
        role: message.role,
        kind: message.kind,
        content: message.content,
        thinkingContent: chatMessageThinkingContent(message),
        thinkingCollapsed: chatMessageThinkingCollapsed(message),
        trace: message.trace.slice(),
        collapsed: message.collapsed,
        createdAt: message.createdAt,
        imagePath: chatMessageImagePath(message),
        imagePaths: chatMessageImagePaths(message)
      };
      let voiceMetadata = optionalChatVoiceMetadata(voice);
      if (voiceMetadata !== undefined) {
        updatedMessage.voice = voiceMetadata;
      }
      messages[i] = updatedMessage;
      changed = true;
      break;
    }
    if (!changed) {
      return ChatSessionController.stateFromSession(filesDir, session);
    }
    session.messages = messages;
    session.updatedAt = new Date().getTime();
    ChatSessionStorage.saveSession(filesDir, session);
    if (state.activeSessionId !== sessionId) {
      return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  static updateContextSummary(filesDir: string, state: ChatSessionViewState, summary: string, updatedAt: number,
    untilMessageId: string, messageCount: number): ChatSessionViewState {
    if (filesDir.length === 0 || state.activeSessionId.length === 0) {
      return state;
    }
    return ChatSessionController.updateContextSummaryInSession(filesDir, state, state.activeSessionId, summary,
      updatedAt, untilMessageId, messageCount);
  }

  static updateContextSummaryInSession(filesDir: string, state: ChatSessionViewState, sessionId: string,
    summary: string, updatedAt: number, untilMessageId: string, messageCount: number): ChatSessionViewState {
    if (filesDir.length === 0 || sessionId.length === 0) {
      return state;
    }
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return ChatSessionController.refreshCurrent(filesDir, state);
    }
    session.contextSummary = summary;
    session.contextSummaryUpdatedAt = updatedAt;
    session.contextSummaryUntilMessageId = untilMessageId;
    session.contextSummaryMessageCount = messageCount;
    ChatSessionStorage.saveSession(filesDir, session);
    if (state.activeSessionId !== sessionId) {
      return ChatSessionController.stateAfterBackgroundSessionUpdate(filesDir, state);
    }
    return ChatSessionController.stateFromSession(filesDir, session);
  }

  private static stateFromSession(filesDir: string, session: ChatSessionRecord): ChatSessionViewState {
    return {
      sessions: ChatSessionStorage.loadIndex(filesDir),
      activeSessionId: session.id,
      activeMessages: session.messages.slice(),
      mode: normalizeChatMode(session.mode),
      activeSession: session
    };
  }

  private static refreshCurrent(filesDir: string, state: ChatSessionViewState): ChatSessionViewState {
    if (state.activeSessionId.length > 0) {
      let session = ChatSessionStorage.loadSession(filesDir, state.activeSessionId);
      if (session !== null) {
        return ChatSessionController.stateFromSession(filesDir, session);
      }
    }
    return {
      sessions: ChatSessionStorage.loadIndex(filesDir),
      activeSessionId: '',
      activeMessages: [],
      mode: normalizeChatMode(state.mode),
      activeSession: null
    };
  }

  private static stateAfterBackgroundSessionUpdate(filesDir: string, state: ChatSessionViewState): ChatSessionViewState {
    return {
      sessions: ChatSessionStorage.loadIndex(filesDir),
      activeSessionId: state.activeSessionId,
      activeMessages: state.activeMessages.slice(),
      mode: normalizeChatMode(state.mode),
      activeSession: state.activeSession
    };
  }

  private static findTaskTraceIndex(messages: ChatMessage[], messageId: string): number {
    if (messageId.length > 0) {
      for (let i = 0; i < messages.length; i++) {
        if (messages[i].id === messageId && messages[i].kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
          return i;
        }
      }
      return -1;
    }
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
        return i;
      }
    }
    return -1;
  }

  private static findLatestTaskResultIndex(messages: ChatMessage[]): number {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
        return i;
      }
    }
    return -1;
  }
}
