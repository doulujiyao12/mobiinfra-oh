import { describe, it, expect } from '@ohos/hypium';
import {
  FirstLaunchOnboardingSlideKind,
  FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT,
  FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR,
  FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME,
  FIRST_LAUNCH_ONBOARDING_SLIDE_USAGE_GUIDE,
  FIRST_LAUNCH_ONBOARDING_SLIDES,
  FIRST_LAUNCH_ONBOARDING_STORAGE_KEY,
  FIRST_LAUNCH_ONBOARDING_VERSION,
  FIRST_LAUNCH_USAGE_GUIDE_ITEMS,
  clampFirstLaunchOnboardingIndex,
  firstLaunchOnboardingButtonText,
  isFirstLaunchOnboardingLastPage,
  shouldShowFirstLaunchOnboarding
} from '../main/ets/pages/onboarding/OnboardingTypes';

export default function firstLaunchOnboardingUnitTest(): void {
  describe('firstLaunchOnboardingUnitTest', () => {
    it('keepsVersionedStorageContractStable', 0, () => {
      expect(FIRST_LAUNCH_ONBOARDING_STORAGE_KEY).assertEqual('firstLaunchOnboardingVersion');
      expect(FIRST_LAUNCH_ONBOARDING_VERSION).assertEqual('2026-07-core-preview-usage-guide');
      expect(shouldShowFirstLaunchOnboarding('')).assertTrue();
      expect(shouldShowFirstLaunchOnboarding('old-version')).assertTrue();
      expect(shouldShowFirstLaunchOnboarding('2026-07-core-preview')).assertTrue();
      expect(shouldShowFirstLaunchOnboarding(FIRST_LAUNCH_ONBOARDING_VERSION)).assertFalse();
    });

    it('usesConfirmedSlideOrderAndCopy', 0, () => {
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES.length).assertEqual(4);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[0].id).assertEqual(FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[0].kind).assertEqual(FirstLaunchOnboardingSlideKind.Preview);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[0].title).assertEqual('ClawMate');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[0].mediaResourceName).assertEqual('onboarding_data_home');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[1].id).assertEqual(FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[1].kind).assertEqual(FirstLaunchOnboardingSlideKind.Preview);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[1].title).assertEqual('数字分身');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[1].mediaResourceName).assertEqual('onboarding_avatar');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[2].id).assertEqual(FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[2].kind).assertEqual(FirstLaunchOnboardingSlideKind.Preview);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[2].title).assertEqual('自动执行');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[2].mediaResourceName).assertEqual('onboarding_agent');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[3].id).assertEqual(FIRST_LAUNCH_ONBOARDING_SLIDE_USAGE_GUIDE);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[3].kind).assertEqual(FirstLaunchOnboardingSlideKind.UsageGuide);
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[3].title).assertEqual('开始使用');
      expect(FIRST_LAUNCH_ONBOARDING_SLIDES[3].mediaResourceName).assertUndefined();
    });

    it('usesConfirmedUsageGuideCards', 0, () => {
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS.length).assertEqual(3);
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].id).assertEqual('usage_data_home');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].title).assertEqual('ClawMate');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].entryLabel).assertEqual('使用入口：汇总');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].configLabel).assertEqual('配置入口：设置 > 数据采集');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].description)
        .assertEqual('同步聊天、图库和位置线索，在汇总页查看整理后的个人事件。');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].iconText).assertEqual('D');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].accentColor).assertEqual('#4F68FF');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[0].softBackgroundColor).assertEqual('#EAF1FF');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].id).assertEqual('usage_avatar');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].title).assertEqual('数字分身');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].entryLabel).assertEqual('使用入口：首页');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].configLabel)
        .assertEqual('配置入口：模型与智能体 > 云端模型 > 更多设置');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].description)
        .assertEqual('基于个人画像和头像生成数字分身，用于问答、任务执行和长期陪伴。');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].iconText).assertEqual('A');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].accentColor).assertEqual('#8066FF');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[1].softBackgroundColor).assertEqual('#F1EEFF');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].id).assertEqual('usage_agent');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].title).assertEqual('自动执行');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].entryLabel).assertEqual('使用入口：聊天 / 任务');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].configLabel).assertEqual('配置入口：设置 > 模型与智能体、任务与自动化');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].description)
        .assertEqual('配置 Planner、Decider 和 HDC 后，让 Agent 按目标规划并执行任务。');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].iconText).assertEqual('T');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].accentColor).assertEqual('#18A886');
      expect(FIRST_LAUNCH_USAGE_GUIDE_ITEMS[2].softBackgroundColor).assertEqual('#E9F8F3');
    });

    it('usesNextUntilTheFinalStartButton', 0, () => {
      expect(firstLaunchOnboardingButtonText(0)).assertEqual('下一页');
      expect(firstLaunchOnboardingButtonText(1)).assertEqual('下一页');
      expect(firstLaunchOnboardingButtonText(2)).assertEqual('下一页');
      expect(firstLaunchOnboardingButtonText(3)).assertEqual('进入首页');
      expect(isFirstLaunchOnboardingLastPage(0)).assertFalse();
      expect(isFirstLaunchOnboardingLastPage(1)).assertFalse();
      expect(isFirstLaunchOnboardingLastPage(2)).assertFalse();
      expect(isFirstLaunchOnboardingLastPage(3)).assertTrue();
    });

    it('clampsInvalidPageIndexes', 0, () => {
      expect(clampFirstLaunchOnboardingIndex(-1)).assertEqual(0);
      expect(clampFirstLaunchOnboardingIndex(0)).assertEqual(0);
      expect(clampFirstLaunchOnboardingIndex(1)).assertEqual(1);
      expect(clampFirstLaunchOnboardingIndex(1.8)).assertEqual(1);
      expect(clampFirstLaunchOnboardingIndex(2)).assertEqual(2);
      expect(clampFirstLaunchOnboardingIndex(3)).assertEqual(3);
      expect(clampFirstLaunchOnboardingIndex(4)).assertEqual(3);
    });
  });
}
