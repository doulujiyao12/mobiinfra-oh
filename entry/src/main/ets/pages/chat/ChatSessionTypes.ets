import { CloudChatMessage } from '../../utils/CloudModelClient';
import { CHAT_MODE_CLOUD_AGENT, CHAT_MODE_LOCAL_INFERENCE, chatModeLabel } from './ChatPageTypes';
import {
  ChatVoiceMetadata,
  normalizeChatVoiceMetadata,
  optionalChatVoiceMetadata
} from './VoiceInteractionTypes';

export { CHAT_MODE_CLOUD_AGENT, CHAT_MODE_LOCAL_INFERENCE };

export type ChatMessageRole = 'user' | 'assistant' | 'system' | 'task';
export type ChatMessageKind = 'chat' | 'task_result' | 'task_trace' | 'context_notice';

export const CHAT_MESSAGE_KIND_CHAT: ChatMessageKind = 'chat';
export const CHAT_MESSAGE_KIND_TASK_RESULT: ChatMessageKind = 'task_result';
export const CHAT_MESSAGE_KIND_TASK_TRACE: ChatMessageKind = 'task_trace';
export const CHAT_MESSAGE_KIND_CONTEXT_NOTICE: ChatMessageKind = 'context_notice';

export interface ChatMessage {
  id: string;
  role: ChatMessageRole;
  kind: ChatMessageKind;
  content: string;
  thinkingContent: string;
  thinkingCollapsed: boolean;
  trace: string[];
  collapsed: boolean;
  createdAt: number;
  imagePath?: string;
  imagePaths?: string[];
  streamingActive?: boolean;
  streamingVersion?: number;
  voice?: ChatVoiceMetadata;
}

export interface ChatAssistantThinkingParts {
  content: string;
  thinkingContent: string;
}

export interface ChatStreamThinkingState {
  enabled: boolean;
  inThinking: boolean;
  pendingTag: string;
}

export interface ChatStreamThinkingDeltaParts {
  contentDelta: string;
  thinkingDelta: string;
  state: ChatStreamThinkingState;
}

export interface ChatSessionSummary {
  id: string;
  title: string;
  mode: string;
  fileName: string;
  createdAt: number;
  updatedAt: number;
  messageCount: number;
  lastMessagePreview: string;
  customTitle?: string;
  pinned?: boolean;
  pinnedAt?: number;
}

export interface ChatSessionRecord {
  id: string;
  title: string;
  mode: string;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
  contextSummary?: string;
  contextSummaryUpdatedAt?: number;
  contextSummaryUntilMessageId?: string;
  contextSummaryMessageCount?: number;
  customTitle?: string;
  pinned?: boolean;
  pinnedAt?: number;
}

export interface ChatSessionIndex {
  sessions: ChatSessionSummary[];
}

export function defaultChatSessionTitle(mode: string): string {
  return chatModeLabel(mode) + '新会话';
}

export function normalizeChatMode(mode: string): string {
  return mode === CHAT_MODE_LOCAL_INFERENCE ? CHAT_MODE_LOCAL_INFERENCE : CHAT_MODE_CLOUD_AGENT;
}

export function createEmptyChatSession(id: string, mode: string, now: number): ChatSessionRecord {
  return {
    id: id,
    title: defaultChatSessionTitle(normalizeChatMode(mode)),
    mode: normalizeChatMode(mode),
    createdAt: now,
    updatedAt: now,
    messages: [],
    contextSummary: '',
    contextSummaryUpdatedAt: 0,
    contextSummaryUntilMessageId: '',
    contextSummaryMessageCount: 0,
    customTitle: '',
    pinned: false,
    pinnedAt: 0
  };
}

const CHAT_THINK_OPEN_TAG = '<think>';
const CHAT_THINK_CLOSE_TAG = '</think>';

export function splitAssistantThinkingContent(rawContent: string): ChatAssistantThinkingParts {
  let lookup = rawContent.toLowerCase();
  let closeIndex = lookup.indexOf(CHAT_THINK_CLOSE_TAG);
  if (closeIndex < 0) {
    let partialOpenIndex = lookup.indexOf(CHAT_THINK_OPEN_TAG);
    if (partialOpenIndex >= 0) {
      let beforeThinking = rawContent.substring(0, partialOpenIndex).trim();
      let thinkingContent = rawContent.substring(partialOpenIndex + CHAT_THINK_OPEN_TAG.length).trim();
      return {
        content: beforeThinking,
        thinkingContent: thinkingContent
      };
    }
    return {
      content: rawContent,
      thinkingContent: ''
    };
  }

  let openIndex = lookup.lastIndexOf(CHAT_THINK_OPEN_TAG, closeIndex);
  let thinkingStart = openIndex >= 0 ? openIndex + CHAT_THINK_OPEN_TAG.length : 0;
  let beforeThinking = openIndex >= 0 ? rawContent.substring(0, openIndex).trim() : '';
  let thinkingContent = rawContent.substring(thinkingStart, closeIndex).trim();
  let afterThinking = rawContent.substring(closeIndex + CHAT_THINK_CLOSE_TAG.length).trim();
  let visibleContent = afterThinking;
  if (beforeThinking.length > 0) {
    visibleContent = afterThinking.length > 0 ? beforeThinking + '\n\n' + afterThinking : beforeThinking;
  }
  return {
    content: visibleContent,
    thinkingContent: thinkingContent
  };
}

export function createChatStreamThinkingState(enableThinking: boolean): ChatStreamThinkingState {
  return {
    enabled: enableThinking,
    inThinking: enableThinking,
    pendingTag: ''
  };
}

function isKnownThinkTagPrefix(lowerText: string): boolean {
  return CHAT_THINK_OPEN_TAG.indexOf(lowerText) === 0 || CHAT_THINK_CLOSE_TAG.indexOf(lowerText) === 0;
}

export function parseChatStreamThinkingDelta(delta: string,
  state: ChatStreamThinkingState): ChatStreamThinkingDeltaParts {
  if (!state.enabled) {
    return {
      contentDelta: delta,
      thinkingDelta: '',
      state: {
        enabled: false,
        inThinking: false,
        pendingTag: ''
      }
    };
  }

  let text = state.pendingTag + delta;
  let inThinking = state.inThinking;
  let pendingTag = '';
  let contentDelta = '';
  let thinkingDelta = '';
  let index = 0;
  while (index < text.length) {
    let rest = text.substring(index);
    let lowerRest = rest.toLowerCase();
    if (lowerRest.indexOf(CHAT_THINK_CLOSE_TAG) === 0) {
      inThinking = false;
      index += CHAT_THINK_CLOSE_TAG.length;
      continue;
    }
    if (lowerRest.indexOf(CHAT_THINK_OPEN_TAG) === 0) {
      inThinking = true;
      index += CHAT_THINK_OPEN_TAG.length;
      continue;
    }
    if (rest.charAt(0) === '<' && isKnownThinkTagPrefix(lowerRest)) {
      pendingTag = rest;
      break;
    }
    if (inThinking) {
      thinkingDelta += text.charAt(index);
    } else {
      contentDelta += text.charAt(index);
    }
    index += 1;
  }

  return {
    contentDelta: contentDelta,
    thinkingDelta: thinkingDelta,
    state: {
      enabled: state.enabled,
      inThinking: inThinking,
      pendingTag: pendingTag
    }
  };
}

export function buildAssistantStreamingRenderContent(content: string, thinkingContent: string): string {
  if (thinkingContent.length === 0) {
    return content;
  }
  if (content.length === 0) {
    return CHAT_THINK_OPEN_TAG + thinkingContent;
  }
  return CHAT_THINK_OPEN_TAG + thinkingContent + CHAT_THINK_CLOSE_TAG + '\n\n' + content;
}

function normalizeAssistantMessageContent(role: ChatMessageRole, kind: ChatMessageKind,
  content: string): ChatAssistantThinkingParts {
  if (role === 'assistant' && kind === CHAT_MESSAGE_KIND_CHAT) {
    return splitAssistantThinkingContent(content);
  }
  return {
    content: content,
    thinkingContent: ''
  };
}

function normalizeChatMessageImagePathInputs(imagePath: string, imagePaths?: string[]): string[] {
  let normalized: string[] = [];
  let legacyPath = imagePath.trim();
  if (legacyPath.length > 0) {
    normalized.push(legacyPath);
  }
  if (imagePaths !== undefined) {
    for (let i = 0; i < imagePaths.length; i++) {
      let path = imagePaths[i].trim();
      if (path.length > 0 && normalized.indexOf(path) < 0) {
        normalized.push(path);
      }
    }
  }
  return normalized;
}

export function createChatMessage(id: string, role: ChatMessageRole, kind: ChatMessageKind, content: string,
  createdAt: number, trace: string[] = [], imagePath: string = '', imagePaths: string[] = [],
  voice?: ChatVoiceMetadata): ChatMessage {
  let parts = normalizeAssistantMessageContent(role, kind, content);
  let normalizedImagePaths = normalizeChatMessageImagePathInputs(imagePath, imagePaths);
  let firstImagePath = normalizedImagePaths.length > 0 ? normalizedImagePaths[0] : '';
  let message: ChatMessage = {
    id: id,
    role: role,
    kind: kind,
    content: parts.content,
    thinkingContent: parts.thinkingContent,
    thinkingCollapsed: true,
    trace: trace,
    collapsed: kind === CHAT_MESSAGE_KIND_TASK_TRACE,
    createdAt: createdAt,
    imagePath: firstImagePath,
    imagePaths: normalizedImagePaths
  };
  let voiceMetadata = optionalChatVoiceMetadata(voice);
  if (voiceMetadata !== undefined) {
    message.voice = voiceMetadata;
  }
  return message;
}

export function chatMessageImagePaths(message: ChatMessage): string[] {
  return normalizeChatMessageImagePathInputs(message.imagePath === undefined ? '' : message.imagePath,
    message.imagePaths);
}

export function chatMessageImagePath(message: ChatMessage): string {
  let imagePaths = chatMessageImagePaths(message);
  return imagePaths.length > 0 ? imagePaths[0] : '';
}

export function chatMessageStreamingActive(message: ChatMessage): boolean {
  return message.streamingActive === true;
}

export function chatMessageStreamingVersion(message: ChatMessage): number {
  return message.streamingVersion === undefined ? 0 : message.streamingVersion;
}

export function chatMessageVoiceMetadata(message: ChatMessage): ChatVoiceMetadata {
  return normalizeChatVoiceMetadata(message.voice);
}

export function chatMessageVoiceMetadataForStorage(message: ChatMessage): ChatVoiceMetadata | undefined {
  return optionalChatVoiceMetadata(message.voice);
}

export function chatMessageThinkingContent(message: ChatMessage): string {
  return message.thinkingContent === undefined ? '' : message.thinkingContent;
}

export function chatMessageThinkingCollapsed(message: ChatMessage): boolean {
  return message.thinkingCollapsed === undefined ? true : message.thinkingCollapsed;
}

/**
 * 返回用于“复制整条消息”的可见正文。助手思考内容已在消息创建或流式解析时拆分，
 * 因而不能将其与工具轨迹一并复制给用户。
 */
export function chatMessageCopyContent(message: ChatMessage): string {
  return message.content;
}

function isCompactPreviewWhitespace(ch: string): boolean {
  return ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t' || ch === '\f' || ch === '\v';
}

export function compactChatPreviewText(content: string, maxLength: number): string {
  if (maxLength <= 0 || content.length === 0) {
    return '';
  }
  let scanLimit = Math.min(content.length, 4096);
  let result = '';
  let pendingSpace = false;
  for (let i = 0; i < scanLimit; i++) {
    let ch = content.charAt(i);
    if (isCompactPreviewWhitespace(ch)) {
      if (result.length > 0) {
        pendingSpace = true;
      }
      continue;
    }
    if (pendingSpace && result.length > 0) {
      result += ' ';
      if (result.length > maxLength) {
        break;
      }
    }
    result += ch;
    pendingSpace = false;
    if (result.length > maxLength) {
      break;
    }
  }
  if (result.length > maxLength) {
    return result.substring(0, maxLength) + '...';
  }
  return result;
}

export function chatSessionPreview(messages: ChatMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    let message = messages[i];
    if (message.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
      continue;
    }
    let text = compactChatPreviewText(message.content, 36);
    if (text.length > 0) {
      return text;
    }
  }
  return '暂无消息';
}

export function chatSessionTitleFromMessages(mode: string, messages: ChatMessage[]): string {
  for (let i = 0; i < messages.length; i++) {
    let message = messages[i];
    if (message.role === 'user') {
      let text = compactChatPreviewText(message.content, 18);
      if (text.length > 0) {
        return text;
      }
    }
  }
  return defaultChatSessionTitle(mode);
}

function normalizedSessionCustomTitle(value?: string): string {
  return value === undefined ? '' : value.trim();
}

function chatSessionDisplayTitle(session: ChatSessionRecord): string {
  let customTitle = normalizedSessionCustomTitle(session.customTitle);
  if (customTitle.length > 0) {
    return customTitle;
  }
  return chatSessionTitleFromMessages(session.mode, session.messages);
}

export function buildChatSessionSummary(session: ChatSessionRecord, fileName: string): ChatSessionSummary {
  let customTitle = normalizedSessionCustomTitle(session.customTitle);
  let pinned = session.pinned === true;
  return {
    id: session.id,
    title: chatSessionDisplayTitle(session),
    mode: normalizeChatMode(session.mode),
    fileName: fileName,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    messageCount: session.messages.length,
    lastMessagePreview: chatSessionPreview(session.messages),
    customTitle: customTitle,
    pinned: pinned,
    pinnedAt: pinned && session.pinnedAt !== undefined ? session.pinnedAt : 0
  };
}

export function toggleChatMessageCollapsed(messages: ChatMessage[], messageId: string): ChatMessage[] {
  let next: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    let message = messages[i];
    if (message.id === messageId && message.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
      let updated: ChatMessage = {
        id: message.id,
        role: message.role,
        kind: message.kind,
        content: message.content,
        thinkingContent: chatMessageThinkingContent(message),
        thinkingCollapsed: chatMessageThinkingCollapsed(message),
        trace: message.trace.slice(),
        collapsed: !message.collapsed,
        createdAt: message.createdAt,
        imagePath: chatMessageImagePath(message),
        imagePaths: chatMessageImagePaths(message)
      };
      let voiceMetadata = chatMessageVoiceMetadataForStorage(message);
      if (voiceMetadata !== undefined) {
        updated.voice = voiceMetadata;
      }
      next.push(updated);
    } else {
      next.push(message);
    }
  }
  return next;
}

export function toggleChatMessageThinkingCollapsed(messages: ChatMessage[], messageId: string): ChatMessage[] {
  let next: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    let message = messages[i];
    if (message.id === messageId && chatMessageThinkingContent(message).length > 0) {
      let updated: ChatMessage = {
        id: message.id,
        role: message.role,
        kind: message.kind,
        content: message.content,
        thinkingContent: chatMessageThinkingContent(message),
        thinkingCollapsed: !chatMessageThinkingCollapsed(message),
        trace: message.trace.slice(),
        collapsed: message.collapsed,
        createdAt: message.createdAt,
        imagePath: chatMessageImagePath(message),
        imagePaths: chatMessageImagePaths(message)
      };
      let voiceMetadata = chatMessageVoiceMetadataForStorage(message);
      if (voiceMetadata !== undefined) {
        updated.voice = voiceMetadata;
      }
      next.push(updated);
    } else {
      next.push(message);
    }
  }
  return next;
}

function chatTextSignature(text: string): string {
  let hash = 0;
  for (let i = 0; i < text.length; i++) {
    hash = (hash * 131 + text.charCodeAt(i)) % 2147483647;
  }
  return String(text.length) + '#' + String(hash);
}

function chatTraceSignature(trace: string[]): string {
  let parts: string[] = [String(trace.length)];
  for (let i = 0; i < trace.length; i++) {
    parts.push(chatTextSignature(trace[i]));
  }
  return parts.join('|');
}

function chatImagePathsSignature(message: ChatMessage): string {
  let imagePaths = chatMessageImagePaths(message);
  let parts: string[] = [String(imagePaths.length)];
  for (let i = 0; i < imagePaths.length; i++) {
    parts.push(chatTextSignature(imagePaths[i]));
  }
  return parts.join('|');
}

export function chatMessageRenderKey(message: ChatMessage): string {
  return message.id + ':' + message.kind +
    ':trace=' + chatTraceSignature(message.trace) +
    ':collapsed=' + (message.collapsed ? '1' : '0') +
    ':content=' + chatTextSignature(message.content) +
    ':thinking=' + chatTextSignature(chatMessageThinkingContent(message)) +
    ':thinkingCollapsed=' + (chatMessageThinkingCollapsed(message) ? '1' : '0') +
    ':image=' + chatImagePathsSignature(message);
}

export function chatMessageStableRenderKey(message: ChatMessage): string {
  return message.id + ':' + message.kind;
}

export function chatSessionRenderKey(session: ChatSessionSummary): string {
  // 会话标题、置顶状态和预览都可能在 id 不变时刷新；key 覆盖这些字段以避免抽屉列表复用旧子树。
  return session.id + ':' + session.title + ':' + (session.pinned === true ? '1' : '0') + ':' +
    String(session.pinnedAt === undefined ? 0 : session.pinnedAt) + ':' + String(session.updatedAt) + ':' +
    String(session.messageCount) + ':' + session.lastMessagePreview;
}

function chatMessageStreamFollowRenderKey(message: ChatMessage): string {
  return chatMessageStableRenderKey(message) +
    ':content=' + chatTextSignature(message.content) +
    ':thinking=' + chatTextSignature(chatMessageThinkingContent(message)) +
    ':thinkingCollapsed=' + (chatMessageThinkingCollapsed(message) ? '1' : '0') +
    ':trace=' + chatTraceSignature(message.trace) +
    ':image=' + chatImagePathsSignature(message);
}

export function chatMessagesAutoScrollKey(sessionId: string, messages: ChatMessage[], thinking: boolean): string {
  let normalizedSessionId = sessionId.length > 0 ? sessionId : 'no-session';
  let latestMessageKey = messages.length > 0 ? chatMessageStableRenderKey(messages[messages.length - 1]) : 'empty';
  return normalizedSessionId + ':' + String(messages.length) + ':' + latestMessageKey + ':' +
    (thinking ? 'thinking' : 'idle');
}

export function chatMessagesStreamFollowKey(sessionId: string, messages: ChatMessage[], thinking: boolean): string {
  let normalizedSessionId = sessionId.length > 0 ? sessionId : 'no-session';
  let latestMessageKey = messages.length > 0 ? chatMessageStreamFollowRenderKey(messages[messages.length - 1]) : 'empty';
  return normalizedSessionId + ':' + String(messages.length) + ':' + latestMessageKey + ':' +
    (thinking ? 'thinking' : 'idle');
}

export function buildCloudContextMessages(messages: ChatMessage[]): CloudChatMessage[] {
  let context: CloudChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    let message = messages[i];
    let content = message.content.trim();
    if (content.length === 0 || message.kind === CHAT_MESSAGE_KIND_TASK_TRACE ||
      message.kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE) {
      continue;
    }
    if (message.role === 'user' || message.role === 'assistant' || message.role === 'system') {
      context.push({
        role: message.role,
        content: content
      });
    } else if (message.kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
      context.push({
        role: 'assistant',
        content: content
      });
    }
  }
  return context;
}
