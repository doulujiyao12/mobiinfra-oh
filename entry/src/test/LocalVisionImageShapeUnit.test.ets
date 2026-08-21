import { describe, it, expect } from '@ohos/hypium';
import {
  LOCAL_VISION_LANDSCAPE_HEIGHT,
  LOCAL_VISION_LANDSCAPE_WIDTH,
  LOCAL_VISION_PORTRAIT_HEIGHT,
  LOCAL_VISION_PORTRAIT_WIDTH,
  localVisionImageTargetSize,
  localVisionImageTargetSizeOrDefault,
  localVisionPromptHw
} from '../main/ets/utils/LocalVisionImageShape';

export default function localVisionImageShapeUnitTest() {
  describe('localVisionImageShapeUnitTest', () => {
    it('usesOneFixedPortraitOrLandscapeShape', 0, () => {
      let portrait = localVisionImageTargetSize(270, 585);
      let landscape = localVisionImageTargetSize(585, 270);

      expect(portrait.width).assertEqual(LOCAL_VISION_PORTRAIT_WIDTH);
      expect(portrait.height).assertEqual(LOCAL_VISION_PORTRAIT_HEIGHT);
      expect(landscape.width).assertEqual(LOCAL_VISION_LANDSCAPE_WIDTH);
      expect(landscape.height).assertEqual(LOCAL_VISION_LANDSCAPE_HEIGHT);
    });

    it('rejectsInvalidStrictDimensionsAndKeepsExplicitFallback', 0, () => {
      let rejected = false;
      try {
        localVisionImageTargetSize(0, 0);
      } catch (e) {
        rejected = true;
      }
      let fallback = localVisionImageTargetSizeOrDefault(0, 0);

      expect(rejected).assertTrue();
      expect(fallback.width).assertEqual(LOCAL_VISION_PORTRAIT_WIDTH);
      expect(fallback.height).assertEqual(LOCAL_VISION_PORTRAIT_HEIGHT);
    });

    it('formatsMnnHeightWidthOrderAndSafePromptFallback', 0, () => {
      expect(localVisionPromptHw(270, 585)).assertEqual('600,270');
      expect(localVisionPromptHw(585, 270)).assertEqual('270,600');
      expect(localVisionPromptHw(0, 0)).assertEqual('600,270');
    });
  });
}
