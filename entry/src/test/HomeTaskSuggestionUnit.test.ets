import { describe, it, expect } from '@ohos/hypium';
import { HomeDomainViewModel, IndexedEvent } from '../main/ets/datamanager/DataManagerTypes';
import {
  buildHomeTaskSuggestionPrompt,
  homeTaskSuggestionCategoryLabel,
  parseHomeTaskSuggestions,
  HomeTaskSuggestion,
  homeTaskSupportsQwen,
  homeTaskQwenDescription,
  buildHomeTaskExecutionRequest,
  buildQwenTaskHandoff,
  homeTaskShortDraft,
  homeTaskExecutionDescription,
  HOME_TASK_DESCRIPTION_LIMIT
} from '../main/ets/pages/home/HomeTaskSuggestion';
import { homeRecommendationGridHeight } from '../main/ets/pages/home/HomeRecommendationLayout';

function sampleRecentEvent(): IndexedEvent {
  return {
    event_id: 'event-1',
    source_state_file: 'daily-log/2026-09-05.md',
    record_id: 1,
    event_date: '2026-09-05',
    last_seen_date: '2026-09-05',
    summary: '最近查看了几家川菜外卖店',
    normalized_fact: '用户最近浏览了川菜外卖商家',
    tags: ['餐饮'],
    source_refs: ['record-1'],
    sources: ['美团'],
    workflow_scene_ids: [],
    image_paths: [],
    todo: {
      type: '',
      deadline: '',
      text: '',
      agent_task: ''
    },
    keywords: ['川菜', '外卖'],
    domains: ['eat'],
    entity_mentions: [],
    enrichment_method: 'test',
    entities: [],
    profile_domains: ['eat']
  };
}

function sampleDomain(): HomeDomainViewModel {
  return {
    domain: 'eat',
    icon: 'Eat',
    title: '吃',
    desc: '偏好川菜',
    fullDesc: '近期更常浏览川菜和便捷外卖',
    claims: ['偏好微辣口味'],
    color: '#39C2A2',
    eventCount: 1
  };
}

function shoppingSuggestion(): HomeTaskSuggestion {
  return { id: 'shopping-1', title: '挑选通勤背包', task: '打开淘宝搜索300元以内的通勤背包',
    reason: '近期购物需求', category: 'shopping', evidence: [], qwenSupported: true,
    qwenTask: '帮我找300元以内的通勤背包' };
}

function rejectsExecution(item: HomeTaskSuggestion, method: string, draft: string): boolean {
  try { buildHomeTaskExecutionRequest(item, method, draft); return false; } catch (e) { return true; }
}

export default function homeTaskSuggestionUnitTest() {
  describe('homeTaskSuggestionUnitTest', () => {
    it('usesOnlyTheRowsRequiredByTheCurrentRecommendationPage', 0, () => {
      expect(homeRecommendationGridHeight(1)).assertEqual(178);
      expect(homeRecommendationGridHeight(2)).assertEqual(178);
      expect(homeRecommendationGridHeight(3)).assertEqual(368);
      expect(homeRecommendationGridHeight(4)).assertEqual(368);
    });

    it('buildsPromptFromRecentRecordsAndDisablesReasoningOutput', 0, () => {
      let prompt = buildHomeTaskSuggestionPrompt([sampleRecentEvent()], [sampleDomain()],
        ['打开新闻应用查看科技资讯'], '2026-09-05');
      expect(prompt.includes('用户最近浏览了川菜外卖商家')).assertTrue();
      expect(prompt.includes('打开新闻应用查看科技资讯')).assertTrue();
      expect(prompt.includes('不要输出思考过程')).assertTrue();
      expect(prompt.includes('40字以内的一句话')).assertTrue();
      expect(prompt.includes('根据已有记录和偏好选定一个具体目标')).assertTrue();
      expect(prompt.includes('不要求执行中提问')).assertTrue();
      expect(prompt.includes('"ref": "record-1"')).assertTrue();
      expect(prompt.includes('"ref": "profile-1"')).assertTrue();
      expect(prompt.includes('evidence_refs')).assertTrue();
      expect(prompt.includes('qwen_supported')).assertTrue();
      expect(prompt.includes('qwen_task')).assertTrue();
      expect(prompt.includes('不得擅自改动平台、日期或预算')).assertTrue();
    });

    it('parsesExactlyThreeExecutableSuggestions', 0, () => {
      let response = '```json\n{"suggestions":[' +
        '{"title":"选一份川菜晚餐","task":"打开外卖应用，筛选三家川菜店并选择一份晚餐","reason":"近期浏览过川菜","category":"food","evidence_refs":["record-1","profile-1"]},' +
        '{"title":"看看科技资讯","task":"打开新闻应用，查找今天的三条科技资讯并浏览摘要","reason":"保持信息更新","category":"news","evidence_refs":["record-1"]},' +
        '{"title":"问候一位朋友","task":"打开微信，找到最近联系的一位朋友，拟好一句问候但在发送前等待用户确认","reason":"延续近期联系","category":"social","evidence_refs":["profile-1"]}' +
        ']}\n```';
      let suggestions = parseHomeTaskSuggestions(response, 'batch-1', [], [sampleRecentEvent()], [sampleDomain()]);
      expect(suggestions.length).assertEqual(3);
      expect(suggestions[0].title).assertEqual('选一份川菜晚餐');
      expect(suggestions[0].category).assertEqual('food');
      expect(suggestions[0].task.includes('不下单')).assertTrue();
      expect(suggestions.every((item: HomeTaskSuggestion): boolean =>
        item.task.length <= HOME_TASK_DESCRIPTION_LIMIT && !/询问|用户确认/.test(item.task))).assertTrue();
      expect(suggestions[0].evidence.length).assertEqual(2);
      expect(suggestions[0].evidence[0].summary).assertEqual('用户最近浏览了川菜外卖商家');
      expect(suggestions[0].evidence[0].meta.includes('美团')).assertTrue();
      expect(homeTaskSuggestionCategoryLabel(suggestions[2].category)).assertEqual('社交');
    });

    it('rejectsIncompleteOrRepeatedBatches', 0, () => {
      let response = '{"suggestions":[' +
        '{"title":"旧任务","task":"打开新闻应用查看科技资讯","reason":"重复","category":"news"},' +
        '{"title":"只有一条新任务","task":"打开地图查看附近公园","reason":"放松一下","category":"travel"}' +
        ']}';
      let rejected = false;
      try {
        parseHomeTaskSuggestions(response, 'batch-2', ['打开新闻应用查看科技资讯']);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('rejectsSuggestionsWithInventedEvidenceReferences', 0, () => {
      let response = '{"suggestions":[' +
        '{"title":"任务一","task":"打开外卖应用查看附近餐厅","reason":"近期记录","category":"food","evidence_refs":["record-99"]},' +
        '{"title":"任务二","task":"打开新闻应用查看资讯","reason":"近期记录","category":"news","evidence_refs":["record-99"]},' +
        '{"title":"任务三","task":"打开地图查看路线","reason":"近期记录","category":"travel","evidence_refs":["profile-99"]}' +
        ']}';
      let rejected = false;
      try {
        parseHomeTaskSuggestions(response, 'batch-3', [], [sampleRecentEvent()], [sampleDomain()]);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('buildsDistinctPhoneAndQwenTasksAndStopsAfterTheHandoff', 0, () => {
      let item = shoppingSuggestion();
      let phone = buildHomeTaskExecutionRequest(item, 'phone', item.task);
      let message = homeTaskQwenDescription(item);
      let qwen = buildHomeTaskExecutionRequest(item, 'qwen', message);
      expect(phone.taskDescription.includes('打开淘宝')).assertTrue();
      expect(phone.taskDescription.includes('用户确认')).assertFalse();
      expect(phone.keepTargetAppAfterFinish).assertFalse();
      expect(message.includes('300元')).assertTrue();
      expect(message.length <= HOME_TASK_DESCRIPTION_LIMIT).assertTrue();
      expect(message.includes('打开淘宝')).assertFalse();
      expect(message.includes('帮我帮我')).assertFalse();
      expect(qwen.taskDescription.includes('在千问')).assertTrue();
      expect(qwen.taskDescription.includes('确认发出后结束手机操作')).assertTrue();
      expect(qwen.taskDescription.length < 160).assertTrue();
      expect(/[。！？!?；;\n]/.test(qwen.taskDescription)).assertFalse();
      expect(qwen.keepTargetAppAfterFinish).assertTrue();
    });

    it('supportsAlibabaAndGenericServiceGoalsWithoutUsingEvidenceAsAPlatformConstraint', 0, () => {
      let item = shoppingSuggestion();
      expect(homeTaskSupportsQwen(item)).assertTrue();
      item.title = '比较晚餐选择'; item.task = '找几家微辣的川菜外卖，对比价格和配送时间'; item.category = 'food';
      item.evidence = [{ ref: 'record-1', kind: 'record', title: '美团记录', summary: '曾在美团点过川菜', meta: '美团' }];
      expect(homeTaskSupportsQwen(item)).assertTrue();
      item.title = '规划周末旅行'; item.task = '规划两个人周末去杭州的行程，预算2000元'; item.category = 'travel';
      expect(homeTaskSupportsQwen(item)).assertTrue();
      item.title = '查找外卖'; item.task = '在美团对比三家川菜外卖';
      expect(homeTaskSupportsQwen(item)).assertFalse();
      expect(rejectsExecution(item, 'qwen', '请帮我找川菜外卖')).assertTrue();
    });

    it('doesNotTurnPrivateDeviceTasksOrExplicitOtherPlatformsIntoQwenRequests', 0, () => {
      let item = shoppingSuggestion();
      for (let task of ['打开京东购买背包', '在携程查看酒店', '打开微信给朋友发送行程', '读取相册里的截图', '导出支付宝账单']) {
        item.task = task;
        expect(homeTaskSupportsQwen(item)).assertFalse();
      }
      item = shoppingSuggestion(); item.qwenSupported = false;
      expect(homeTaskSupportsQwen(item)).assertFalse();
    });

    it('doesNotMistakeTheGenericSafetySuffixForAPrivateAccountTask', 0, () => {
      let item = shoppingSuggestion();
      item.task += '；在提交订单、支付、转账或发送消息前停下等待用户确认';
      expect(homeTaskSupportsQwen(item)).assertTrue();
      item.qwenTask = '在淘宝购买300元以内的通勤背包';
      let description = homeTaskQwenDescription(item);
      expect(description.includes('不下单')).assertTrue();
      expect(description.includes('用户确认')).assertFalse();
      expect(buildHomeTaskExecutionRequest(item, 'qwen', description).keepTargetAppAfterFinish).assertTrue();
    });

    it('keepsLegacySuggestionsUsableAndRemovesGestureClausesFromTheirAgentDescription', 0, () => {
      let item = shoppingSuggestion();
      item.qwenSupported = undefined; item.qwenTask = undefined;
      item.task = '打开淘宝，搜索通勤背包，预算300元以内，点击输入框，滑动页面';
      let description = homeTaskQwenDescription(item);
      expect(description.includes('淘宝')).assertTrue();
      expect(description.includes('300元')).assertTrue();
      expect(description.includes('点击')).assertFalse();
      expect(description.includes('输入框')).assertFalse();
      expect(description.includes('滑动')).assertFalse();
      expect(buildHomeTaskExecutionRequest(item, 'qwen', description).keepTargetAppAfterFinish).assertTrue();
    });

    it('rejectsLongOrMultipleTasksInsteadOfTruncatingEditedConstraints', 0, () => {
      let item = shoppingSuggestion();
      expect(rejectsExecution(item, 'qwen', '点击淘宝搜索框并滑动页面')).assertTrue();
      expect(rejectsExecution(item, 'qwen', '改为在京东购买背包')).assertTrue();
      expect(rejectsExecution(item, 'qwen', '读取验证码')).assertTrue();
      expect(rejectsExecution(item, 'phone', '')).assertTrue();
      expect(rejectsExecution(item, 'other', '购买背包')).assertTrue();
      expect(rejectsExecution(item, 'phone', '条件'.repeat(31))).assertTrue();
      expect(rejectsExecution(item, 'phone', '打开淘宝搜索背包。打开高德查询路线')).assertTrue();
      expect(rejectsExecution(item, 'phone', '搜索背包；对比店铺')).assertTrue();
      expect(rejectsExecution(item, 'qwen', '查看手机价格，然后分析配置')).assertTrue();
      expect(rejectsExecution(item, 'phone', '搜索手机并分析配置')).assertTrue();
      let boundary = '查看' + '背包'.repeat(29);
      expect(buildHomeTaskExecutionRequest(item, 'phone', boundary).taskDescription).assertEqual(boundary);
      expect(rejectsExecution(item, 'phone', boundary + '包')).assertTrue();
      expect(homeTaskExecutionDescription('在淘宝搜索300元以内的背包。')).assertEqual('在淘宝搜索300元以内的背包');
    });

    it('neverSendsUserQuestionsAndEndsAtTheSubmissionBoundary', 0, () => {
      let item = shoppingSuggestion();
      for (let draft of ['先询问用户预算', '请用户选择一家店', '等我确认后下单', '选择商品后问用户']) {
        expect(rejectsExecution(item, 'phone', draft)).assertTrue();
      }
      let task = buildHomeTaskExecutionRequest(item, 'phone', '在淘宝挑选300元以内的通勤背包').taskDescription;
      expect(task).assertEqual('在淘宝挑选300元以内的通勤背包');
      expect(homeTaskExecutionDescription('在淘宝购买背包')).assertEqual('在淘宝购买背包，不下单');
      expect(homeTaskExecutionDescription('给小王拟好问候')).assertEqual('给小王拟好问候，不发送');
      expect(homeTaskExecutionDescription('打开支付宝查看余额')).assertEqual('打开支付宝查看余额');
      expect(homeTaskExecutionDescription('购买背包；在提交订单、支付、转账或发送消息前停下等待用户确认'))
        .assertEqual('购买背包，不提交');
    });

    it('usesAnEditableShortTitleForLegacyLongOrQuestionBasedTasks', 0, () => {
      let draft = homeTaskShortDraft('打开淘宝，' + '复杂条件，'.repeat(20), '搜索通勤背包');
      expect(draft).assertEqual('在淘宝搜索通勤背包');
      expect(draft.length <= HOME_TASK_DESCRIPTION_LIMIT).assertTrue();
      let question = homeTaskShortDraft('在淘宝找背包并询问用户喜欢哪个', '查看背包');
      expect(question).assertEqual('在淘宝查看背包');
      expect(homeTaskShortDraft('', '不能用标题代替缺失任务')).assertEqual('');
    });

    it('quotesTheHandoffMessageAndDoesNotRequireAFixedSendIcon', 0, () => {
      let task = '查找名为"通勤背包"的商品，预算300元以内';
      let command = buildQwenTaskHandoff(task);
      expect(command.includes('\\"通勤背包\\"')).assertTrue();
      expect(command.includes('\n')).assertFalse();
      expect(command.includes('黑色向上箭头')).assertFalse();
      expect(command.includes('不重复发送')).assertTrue();
      expect(command.length < 160).assertTrue();
    });

    it('parsesIndependentQwenDescriptionsAndKeepsPhoneTasksForUnsupportedCases', 0, () => {
      let response = '{"suggestions":[' +
        '{"title":"背包","task":"打开淘宝搜索背包","qwen_supported":true,"qwen_task":"帮我在淘宝比较三款300元以内的背包","category":"shopping"},' +
        '{"title":"行程","task":"打开飞猪规划周末行程","qwen_supported":true,"qwen_task":"为两个人规划周末杭州两日游","category":"invalid"},' +
        '{"title":"聊天","task":"打开微信拟好问候","qwen_supported":true,"qwen_task":"帮我发微信消息","category":"social"}]}';
      let items = parseHomeTaskSuggestions(response, 'dual-route');
      expect(items.length).assertEqual(3);
      expect(items[0].task.includes('打开淘宝')).assertTrue();
      expect(items[0].qwenTask).assertEqual('帮我在淘宝比较三款300元以内的背包');
      expect(homeTaskSupportsQwen(items[1])).assertTrue();
      expect(items[1].category).assertEqual('travel');
      expect(homeTaskSupportsQwen(items[2])).assertFalse();
      expect(items[2].qwenTask).assertEqual('');
    });
  });
}
