import { describe, it, expect } from '@ohos/hypium';
import { MAIN_TAB_ITEMS, MainTabIndex, centerTabIndex, mainTabIcon, mainTabLabel } from '../main/ets/pages/main/MainTabConfig';

export default function mainTabConfigUnitTest() {
  describe('mainTabConfigUnitTest', () => {
    it('usesConfirmedTabOrderAndLabels', 0, () => {
      expect(MAIN_TAB_ITEMS.length).assertEqual(5);
      expect(MAIN_TAB_ITEMS[0].label).assertEqual('首页');
      expect(MAIN_TAB_ITEMS[1].label).assertEqual('汇总');
      expect(MAIN_TAB_ITEMS[2].label).assertEqual('聊天');
      expect(MAIN_TAB_ITEMS[3].label).assertEqual('任务');
      expect(MAIN_TAB_ITEMS[4].label).assertEqual('我的');
    });

    it('keepsChatAsCenterTab', 0, () => {
      expect(centerTabIndex()).assertEqual(MainTabIndex.Chat);
      expect(mainTabLabel(MainTabIndex.Chat)).assertEqual('聊天');
      expect(mainTabLabel(MainTabIndex.Summary)).assertEqual('汇总');
    });

    it('exposesAsciiSemanticIconResources', 0, () => {
      expect(mainTabIcon(MainTabIndex.Home)).assertEqual('tab_home');
      expect(mainTabIcon(MainTabIndex.Summary)).assertEqual('tab_summary');
      expect(mainTabIcon(MainTabIndex.Chat)).assertEqual('tab_chat');
      expect(mainTabIcon(MainTabIndex.Task)).assertEqual('tab_task');
      expect(mainTabIcon(MainTabIndex.Mine)).assertEqual('tab_mine');
    });
  });
}
