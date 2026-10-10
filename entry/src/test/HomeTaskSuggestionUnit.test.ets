import { describe, it, expect } from '@ohos/hypium';
import { HomeDomainViewModel, IndexedEvent } from '../main/ets/datamanager/DataManagerTypes';
import {
  buildHomeTaskSuggestionPrompt,
  homeTaskSuggestionCategoryLabel,
  parseHomeTaskSuggestions
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
      expect(prompt.includes('支付或发送前停下等待用户确认')).assertTrue();
      expect(prompt.includes('"ref": "record-1"')).assertTrue();
      expect(prompt.includes('"ref": "profile-1"')).assertTrue();
      expect(prompt.includes('evidence_refs')).assertTrue();
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
      expect(suggestions[0].task.includes('等待用户确认')).assertTrue();
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
  });
}
