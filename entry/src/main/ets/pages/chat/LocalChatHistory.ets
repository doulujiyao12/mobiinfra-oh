import {
  CHAT_MESSAGE_KIND_CHAT,
  ChatMessage,
  buildAssistantStreamingRenderContent,
  chatMessageImagePaths
} from './ChatSessionTypes';
import { buildLocalChatMultimodalPrompt } from './LocalChatImagePrompt';

const LOCAL_CHAT_PENDING_MESSAGE = '思考中...';
const LOCAL_CHAT_LOADING_MESSAGE = '首次加载本地模型中...';
const LOCAL_CHAT_ERROR_PREFIX = '[错误]';

function restorableAssistantContent(message: ChatMessage): string {
  if (message.streamingActive === true) {
    return '';
  }
  let content = buildAssistantStreamingRenderContent(message.content, message.thinkingContent).trim();
  if (content.length === 0 || content === LOCAL_CHAT_PENDING_MESSAGE || content === LOCAL_CHAT_LOADING_MESSAGE ||
    content.startsWith(LOCAL_CHAT_ERROR_PREFIX)) {
    return '';
  }
  return content;
}

// Native history is an alternating user/assistant content array. Only complete
// turns are restored so a placeholder or failed response cannot corrupt the
// next local model prompt.
export function buildNativeLocalChatHistoryContents(messages: ChatMessage[]): string[] {
  let history: string[] = [];
  let pendingUserPrompt = '';
  let hasPendingUser = false;
  for (let i = 0; i < messages.length; i++) {
    let message = messages[i];
    if (message.kind !== CHAT_MESSAGE_KIND_CHAT) {
      continue;
    }
    if (message.role === 'user') {
      pendingUserPrompt = buildLocalChatMultimodalPrompt(message.content, chatMessageImagePaths(message));
      hasPendingUser = pendingUserPrompt.length > 0;
      continue;
    }
    if (message.role !== 'assistant' || !hasPendingUser) {
      continue;
    }
    let assistantContent = restorableAssistantContent(message);
    if (assistantContent.length === 0) {
      pendingUserPrompt = '';
      hasPendingUser = false;
      continue;
    }
    history.push(pendingUserPrompt);
    history.push(assistantContent);
    pendingUserPrompt = '';
    hasPendingUser = false;
  }
  return history;
}
