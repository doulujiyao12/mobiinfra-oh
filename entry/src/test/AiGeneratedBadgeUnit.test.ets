import { describe, it, expect } from '@ohos/hypium';
import {
  AI_GENERATED_TEXT_NOTICE,
  createAiGeneratedContentMetadata,
  ensureAiGeneratedTextNotice,
  isAiGeneratedChatMessage
} from '../main/ets/utils/AiGeneratedContent';

export default function aiGeneratedBadgeUnitTest() {
  describe('aiGeneratedBadgeUnitTest', () => {
    it('labelsAssistantAndTaskGeneratedMessages', 0, () => {
      expect(isAiGeneratedChatMessage('assistant', 'chat')).assertTrue();
      expect(isAiGeneratedChatMessage('task', 'task_result')).assertTrue();
      expect(isAiGeneratedChatMessage('task', 'task_trace')).assertTrue();
      expect(isAiGeneratedChatMessage('user', 'chat')).assertFalse();
      expect(isAiGeneratedChatMessage('system', 'context_notice')).assertFalse();
    });

    it('addsExportNoticeOnce', 0, () => {
      let labeled = ensureAiGeneratedTextNotice('画像摘要');
      expect(labeled).assertEqual(AI_GENERATED_TEXT_NOTICE + '\n画像摘要');
      expect(ensureAiGeneratedTextNotice(labeled)).assertEqual(labeled);
      expect(ensureAiGeneratedTextNotice('   ')).assertEqual('');
    });

    it('buildsImplicitMetadataForExportedContent', 0, () => {
      let metadata = createAiGeneratedContentMetadata('profile-1', '2026-09-02T10:00:00.000Z');
      expect(metadata.generatedContent).assertTrue();
      expect(metadata.contentProperty).assertEqual('ai_generated');
      expect(metadata.serviceProvider).assertEqual('MobiInfer LLM Chat');
      expect(metadata.contentId).assertEqual('profile-1');
      expect(metadata.explicitLabel).assertEqual(AI_GENERATED_TEXT_NOTICE);
    });
  });
}
