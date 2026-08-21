import { describe, it, expect } from '@ohos/hypium';
import {
  LOCAL_CHAT_IMAGE_LANDSCAPE_HEIGHT,
  LOCAL_CHAT_IMAGE_LANDSCAPE_WIDTH,
  LOCAL_CHAT_IMAGE_TARGET_HEIGHT,
  LOCAL_CHAT_IMAGE_TARGET_WIDTH,
  LocalChatImageSize,
  buildLocalChatMultimodalPrompt,
  localChatImageTargetSize,
  localChatResizeContentSize
} from '../main/ets/pages/chat/LocalChatImagePrompt';

export default function localChatImagePromptUnitTest() {
  describe('localChatImagePromptUnitTest', () => {
    it('selectsOrientationAwareFixedVisualShape', 0, () => {
      let landscape: LocalChatImageSize = localChatImageTargetSize(1600, 900);
      let portrait: LocalChatImageSize = localChatImageTargetSize(900, 1600);

      expect(landscape.width).assertEqual(LOCAL_CHAT_IMAGE_LANDSCAPE_WIDTH);
      expect(landscape.height).assertEqual(LOCAL_CHAT_IMAGE_LANDSCAPE_HEIGHT);
      expect(portrait.width).assertEqual(LOCAL_CHAT_IMAGE_TARGET_WIDTH);
      expect(portrait.height).assertEqual(LOCAL_CHAT_IMAGE_TARGET_HEIGHT);
    });

    it('resizesInsideVisualBoundsWithoutAddingBlackCanvas', 0, () => {
      let landscape: LocalChatImageSize = localChatResizeContentSize(1600, 900);
      let portrait: LocalChatImageSize = localChatResizeContentSize(900, 1600);
      let phoneScreenshot: LocalChatImageSize = localChatResizeContentSize(1080, 2400);

      expect(landscape.width).assertEqual(480);
      expect(landscape.height).assertEqual(LOCAL_CHAT_IMAGE_LANDSCAPE_HEIGHT);
      expect(portrait.width).assertEqual(LOCAL_CHAT_IMAGE_TARGET_WIDTH);
      expect(portrait.height).assertEqual(480);
      expect(phoneScreenshot.width).assertEqual(LOCAL_CHAT_IMAGE_TARGET_WIDTH);
      expect(phoneScreenshot.height).assertEqual(LOCAL_CHAT_IMAGE_TARGET_HEIGHT);
    });

    it('buildsCanonicalMnnImageTagWithAbsolutePathAndFixedShape', 0, () => {
      let prompt = buildLocalChatMultimodalPrompt(' 描述图片 ', ['file:///data/storage/el2/base/photo.jpg']);

      expect(prompt).assertEqual('<img><hw>600,270</hw>/data/storage/el2/base/photo.jpg</img>\n描述图片');
    });

    it('restoresLandscapeShapeFromPreparedImageFileName', 0, () => {
      let prompt = buildLocalChatMultimodalPrompt('描述图片', [
        'file:///data/storage/el2/base/local-chat-vlm-600x270-1-0-1.jpg'
      ]);

      expect(prompt).assertEqual(
        '<img><hw>270,600</hw>/data/storage/el2/base/local-chat-vlm-600x270-1-0-1.jpg</img>\n描述图片');
    });

    it('limitsLocalInferencePromptToOneImage', 0, () => {
      let prompt = buildLocalChatMultimodalPrompt('比较图片', [
        'file:///data/storage/el2/base/first.jpg',
        'file:///data/storage/el2/base/second.jpg'
      ]);

      expect(prompt).assertContain('/first.jpg');
      expect(prompt.indexOf('/second.jpg')).assertEqual(-1);
    });
  });
}
