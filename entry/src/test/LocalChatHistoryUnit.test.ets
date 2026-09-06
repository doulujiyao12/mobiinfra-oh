import { describe, it, expect } from '@ohos/hypium';
import { buildNativeLocalChatHistoryContents } from '../main/ets/pages/chat/LocalChatHistory';
import {
  CHAT_MESSAGE_KIND_CHAT,
  ChatMessage,
  createChatMessage
} from '../main/ets/pages/chat/ChatSessionTypes';

function message(id: string, role: 'user' | 'assistant', content: string, imagePath: string = ''): ChatMessage {
  return createChatMessage(id, role, CHAT_MESSAGE_KIND_CHAT, content, 1, [], imagePath);
}

export default function localChatHistoryUnitTest() {
  describe('localChatHistoryUnitTest', () => {
    it('restoresOnlyCompleteUserAssistantPairs', 0, () => {
      let messages: ChatMessage[] = [
        message('user-1', 'user', 'hello'),
        message('assistant-1', 'assistant', 'hi'),
        message('user-2', 'user', 'unfinished'),
        message('assistant-2', 'assistant', '思考中...')
      ];

      let history = buildNativeLocalChatHistoryContents(messages);

      expect(history.length).assertEqual(2);
      expect(history[0]).assertEqual('hello');
      expect(history[1]).assertEqual('hi');
    });

    it('restoresThinkingAndImagePromptContent', 0, () => {
      let messages: ChatMessage[] = [
        message('user-1', 'user', 'describe', 'file:///data/storage/el2/base/photo.jpg'),
        message('assistant-1', 'assistant', '<think>inspect image</think>answer')
      ];

      let history = buildNativeLocalChatHistoryContents(messages);

      expect(history[0]).assertContain('<img><hw>600,270</hw>/data/storage/el2/base/photo.jpg</img>');
      expect(history[0]).assertContain('describe');
      expect(history[1]).assertEqual('<think>inspect image</think>\n\nanswer');
    });

    it('dropsFailedAssistantTurns', 0, () => {
      let messages: ChatMessage[] = [
        message('user-1', 'user', 'first'),
        message('assistant-1', 'assistant', '[错误] model failed'),
        message('assistant-stray', 'assistant', 'must not attach to the failed turn'),
        message('user-2', 'user', 'second'),
        message('assistant-2', 'assistant', 'done')
      ];

      let history = buildNativeLocalChatHistoryContents(messages);

      expect(history.length).assertEqual(2);
      expect(history[0]).assertEqual('second');
      expect(history[1]).assertEqual('done');
    });
  });
}
