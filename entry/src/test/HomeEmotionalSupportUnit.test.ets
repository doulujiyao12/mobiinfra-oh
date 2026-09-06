import { describe, it, expect } from '@ohos/hypium';
import { HomeDomainViewModel, IndexedEvent } from '../main/ets/datamanager/DataManagerTypes';
import {
  HomeComfortChatMessage,
  buildHomeComfortChatMessages,
  buildHomeComfortConcernPrompt,
  parseHomeComfortConcerns,
  parseHomeComfortReply
} from '../main/ets/pages/home/HomeEmotionalSupport';

function sampleComfortEvent(): IndexedEvent {
  return {
    event_id: 'comfort-event-1',
    source_state_file: 'daily-log/2026-09-05.md',
    record_id: 1,
    event_date: '2026-09-05',
    last_seen_date: '2026-09-05',
    summary: '最近多次查看加班后的晚餐和通勤路线',
    normalized_fact: '用户最近多次查看晚间通勤路线',
    tags: ['通勤'],
    source_refs: ['record-1'],
    sources: ['地图'],
    workflow_scene_ids: [],
    image_paths: [],
    todo: {
      type: '',
      deadline: '',
      text: '',
      agent_task: ''
    },
    keywords: ['晚间', '通勤'],
    domains: ['work'],
    entity_mentions: [],
    enrichment_method: 'test',
    entities: [],
    profile_domains: ['work']
  };
}

function sampleComfortDomain(): HomeDomainViewModel {
  return {
    domain: 'work',
    icon: 'Work',
    title: '工作',
    desc: '近期晚间安排较多',
    fullDesc: '近期记录中晚间工作与通勤安排出现得比较频繁',
    claims: ['晚间安排较为集中'],
    color: '#6C72E8',
    eventCount: 2
  };
}

function validConcernResponse(): string {
  return '{"concerns":[' +
    '{"title":"可能有些疲惫","summary":"晚间通勤记录较多，也许最近节奏有些紧","opening":"这只是一个猜测。最近是不是有点累，愿意说说吗？","category":"work","evidence_refs":["record-1","profile-1"]},' +
    '{"title":"也许在平衡时间","summary":"工作与通勤安排可能挤占了自己的时间","opening":"也许我猜得不准，你最近会觉得自己的时间不太够用吗？","category":"life","evidence_refs":["record-1"]},' +
    '{"title":"可能想让节奏慢一点","summary":"近期安排看起来比较集中，也许你想稍微松口气","opening":"如果你愿意，我们可以从最近最消耗你的一件事聊起。","category":"health","evidence_refs":["profile-1"]}' +
    ']}';
}

export default function homeEmotionalSupportUnitTest() {
  describe('homeEmotionalSupportUnitTest', () => {
    it('buildsGroundedAndNonDiagnosticConcernPrompt', 0, () => {
      let prompt = buildHomeComfortConcernPrompt([sampleComfortEvent()], [sampleComfortDomain()], '2026-09-05');
      expect(prompt.includes('标题要直白、友好、容易理解')).assertTrue();
      expect(prompt.includes('不要以“可能、也许、或许、似乎、看起来”开头')).assertTrue();
      expect(prompt.includes('不要以“这只是一个猜测”')).assertTrue();
      expect(prompt.includes('不得做心理、精神或身体疾病诊断')).assertTrue();
      expect(prompt.includes('"ref": "record-1"')).assertTrue();
      expect(prompt.includes('evidence_refs')).assertTrue();
    });

    it('resolvesConcernEvidenceFromLocalContext', 0, () => {
      let concerns = parseHomeComfortConcerns(validConcernResponse(), 'batch-1', [sampleComfortEvent()],
        [sampleComfortDomain()]);
      expect(concerns.length).assertEqual(3);
      expect(concerns[0].evidence.length).assertEqual(2);
      expect(concerns[0].title).assertEqual('有些疲惫');
      expect(concerns[0].opening.includes('这只是一个猜测')).assertEqual(false);
      expect(concerns[0].evidence[0].summary).assertEqual('用户最近多次查看晚间通勤路线');
      expect(concerns[0].evidence[0].meta.includes('地图')).assertTrue();
    });

    it('buildsPlannerConversationWithSafetyAndRecentContext', 0, () => {
      let concern = parseHomeComfortConcerns(validConcernResponse(), 'batch-2', [sampleComfortEvent()],
        [sampleComfortDomain()])[0];
      let history: HomeComfortChatMessage[] = [{
        id: 'assistant-1',
        role: 'assistant',
        content: concern.opening,
        createdAt: 1
      }, {
        id: 'user-1',
        role: 'user',
        content: '最近下班确实比较晚。',
        createdAt: 2
      }];
      let messages = buildHomeComfortChatMessages(concern, history, [sampleComfortEvent()],
        [sampleComfortDomain()], '2026-09-05');
      expect(messages.length).assertEqual(3);
      expect(String(messages[0].content).includes('会一点读心术的解闷搭子')).assertTrue();
      expect(String(messages[0].content).includes('不要用免责声明打断对话')).assertTrue();
      expect(String(messages[0].content).includes('它们都是推测而不是事实')).assertTrue();
      expect(String(messages[0].content).includes('当地紧急服务')).assertTrue();
      expect(messages[2].role).assertEqual('user');
      expect(String(messages[2].content)).assertEqual('最近下班确实比较晚。');
    });

    it('rejectsInventedConcernEvidenceReferences', 0, () => {
      let invalid = validConcernResponse().replace(/record-1/g, 'record-99').replace(/profile-1/g, 'profile-99');
      let rejected = false;
      try {
        parseHomeComfortConcerns(invalid, 'batch-3', [sampleComfortEvent()], [sampleComfortDomain()]);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('rejectsDiagnosticConcernClaims', 0, () => {
      let invalid = validConcernResponse().replace('可能有些疲惫', '可能患有焦虑症');
      let rejected = false;
      try {
        parseHomeComfortConcerns(invalid, 'batch-4', [sampleComfortEvent()], [sampleComfortDomain()]);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('removesHiddenThinkingFromComfortReply', 0, () => {
      let reply = parseHomeComfortReply('<think>internal analysis</think>听起来你最近确实很累。愿意说说最累的时刻吗？');
      expect(reply).assertEqual('听起来你最近确实很累。愿意说说最累的时刻吗？');
    });
  });
}
