import { describe, expect, it } from '@ohos/hypium';
import { LocalPlannerFastPath, LocalPlannerFastPathMatch } from '../main/ets/utils/LocalPlannerFastPath';

const TEST_PLANNER_PROMPT: string = `## 可用应用列表
- 饿了么: me.ele.eleme
- 淘宝闪购: me.ele.eleme
- 淘宝: com.taobao.taobao4hmos
- 飞猪: com.fliggy.hmos
- 飞猪旅行: com.fliggy.hmos
- 信息: com.ohos.mms
- 爱奇艺  com.qiyi.video.hmy
- 去哪旅行:com.qunar.hos

## 任务要求
- 请访问 example.com`;

function requiredMatch(task: string): LocalPlannerFastPathMatch {
  let result = LocalPlannerFastPath.match(task, TEST_PLANNER_PROMPT);
  expect(result === null).assertFalse();
  return result as LocalPlannerFastPathMatch;
}

export default function localPlannerFastPathUnitTest(): void {
  describe('localPlannerFastPathUnitTest', () => {
    it('matchesAppNameFromTaskWithoutCallingPlanner', 0, () => {
      let result = requiredMatch('帮我查询一下淘宝中的订单信息');
      expect(result.appName).assertEqual('淘宝');
      expect(result.packageName).assertEqual('com.taobao.taobao4hmos');
      expect(result.matchedBy).assertEqual('app_name');
    });

    it('prefersLongerOverlappingAppName', 0, () => {
      let shoppingResult = requiredMatch('打开淘宝闪购查看订单');
      expect(shoppingResult.appName).assertEqual('淘宝闪购');
      expect(shoppingResult.packageName).assertEqual('me.ele.eleme');

      let travelResult = requiredMatch('去飞猪旅行查询机票');
      expect(travelResult.appName).assertEqual('飞猪旅行');
      expect(travelResult.packageName).assertEqual('com.fliggy.hmos');
    });

    it('prefersEarlierSameLengthAppNameMention', 0, () => {
      let result = requiredMatch('帮我查询一下淘宝中的订单信息');
      expect(result.appName).assertEqual('淘宝');
    });

    it('doesNotTreatGenericWordsAsExplicitAppNames', 0, () => {
      let shoppingResult = requiredMatch('帮我设置淘宝的收货地址');
      expect(shoppingResult.appName).assertEqual('淘宝');

      let genericResult = LocalPlannerFastPath.match('帮我查询订单信息', TEST_PLANNER_PROMPT);
      expect(genericResult === null).assertTrue();
    });

    it('acceptsAmbiguousAppNameWithExplicitContext', 0, () => {
      let result = requiredMatch('打开信息查看短信');
      expect(result.appName).assertEqual('信息');
      expect(result.packageName).assertEqual('com.ohos.mms');
    });

    it('matchesPackageNameCaseInsensitively', 0, () => {
      let result = requiredMatch('请启动 COM.QUNAR.HOS 并查询订单');
      expect(result.appName).assertEqual('去哪旅行');
      expect(result.packageName).assertEqual('com.qunar.hos');
      expect(result.matchedBy).assertEqual('package_name');
    });

    it('parsesPromptLineWithoutColon', 0, () => {
      let result = requiredMatch('在爱奇艺里搜索电影');
      expect(result.appName).assertEqual('爱奇艺');
      expect(result.packageName).assertEqual('com.qiyi.video.hmy');
    });

    it('fallsBackWhenTaskDoesNotMentionKnownApp', 0, () => {
      let result = LocalPlannerFastPath.match('帮我找一个可以买书的应用', TEST_PLANNER_PROMPT);
      expect(result === null).assertTrue();
    });

    it('ignoresPackageLikeTextOutsideAppList', 0, () => {
      let result = LocalPlannerFastPath.match('请访问 example.com', TEST_PLANNER_PROMPT);
      expect(result === null).assertTrue();
    });
  });
}
