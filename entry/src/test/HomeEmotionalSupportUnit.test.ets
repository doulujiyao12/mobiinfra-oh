import { describe, it, expect } from '@ohos/hypium';
import { IndexedEvent } from '../main/ets/datamanager/DataManagerTypes';
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
    summary: '用户在聊天中说最近连续加班，感到疲惫和压力很大',
    normalized_fact: '用户告诉朋友最近连续加班，感到疲惫和压力很大',
    tags: ['聊天', '压力'],
    source_refs: ['record-1'],
    sources: ['微信'],
    workflow_scene_ids: [3],
    image_paths: [],
    todo: {
      type: '',
      deadline: '',
      text: '',
      agent_task: ''
    },
    keywords: ['加班', '疲惫', '压力'],
    domains: ['work'],
    entity_mentions: [],
    enrichment_method: 'test',
    entities: [],
    profile_domains: ['work']
  };
}

function validConcernResponse(): string {
  return '{"concerns":[' +
    '{"title":"可能有些疲惫","summary":"聊天里提到连续加班带来的疲惫和压力","opening":"这只是一个猜测。最近是不是有点累，愿意说说吗？","category":"work","evidence_refs":["record-1"]},' +
    '{"title":"也许在平衡时间","summary":"聊天中表达了连续加班带来的压力","opening":"也许我猜得不准，你最近会觉得自己的时间不太够用吗？","category":"life","evidence_refs":["record-1"]},' +
    '{"title":"可能想让节奏慢一点","summary":"聊天中直接表达了疲惫，也许你想稍微松口气","opening":"如果你愿意，我们可以从最近最消耗你的一件事聊起。","category":"health","evidence_refs":["record-1"]}' +
    ']}';
}

export default function homeEmotionalSupportUnitTest() {
  describe('homeEmotionalSupportUnitTest', () => {
    it('buildsGroundedAndNonDiagnosticConcernPrompt', 0, () => {
      let prompt = buildHomeComfortConcernPrompt([sampleComfortEvent()], '2026-09-05');
      expect(prompt.includes('只能根据用户近 7 天的聊天记录')).assertTrue();
      expect(prompt.includes('待办、日程、提醒')).assertTrue();
      expect(prompt.includes('没有明确烦恼线索时返回空数组')).assertTrue();
      expect(prompt.includes('标题要直白、友好、容易理解')).assertTrue();
      expect(prompt.includes('不要以“可能、也许、或许、似乎、看起来”开头')).assertTrue();
      expect(prompt.includes('不要以“这只是一个猜测”')).assertTrue();
      expect(prompt.includes('不得做心理、精神或身体疾病诊断')).assertTrue();
      expect(prompt.includes('"ref": "record-1"')).assertTrue();
      expect(prompt.includes('profile_summary')).assertEqual(false);
      expect(prompt.includes('"sources"')).assertEqual(false);
      expect(prompt.includes('"domains"')).assertEqual(false);
      expect(prompt.includes('"keywords"')).assertEqual(false);
      expect(prompt.includes('evidence_refs')).assertTrue();
    });

    it('resolvesConcernEvidenceFromLocalContext', 0, () => {
      let concerns = parseHomeComfortConcerns(validConcernResponse(), 'batch-1', [sampleComfortEvent()]);
      expect(concerns.length).assertEqual(3);
      expect(concerns[0].evidence.length).assertEqual(1);
      expect(concerns[0].title).assertEqual('有些疲惫');
      expect(concerns[0].opening.includes('这只是一个猜测')).assertEqual(false);
      expect(concerns[0].evidence[0].summary).assertEqual('用户告诉朋友最近连续加班，感到疲惫和压力很大');
      expect(concerns[0].evidence[0].meta.includes('微信')).assertTrue();
    });

    it('buildsPlannerConversationWithSafetyAndRecentContext', 0, () => {
      let concern = parseHomeComfortConcerns(validConcernResponse(), 'batch-2', [sampleComfortEvent()])[0];
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
      let messages = buildHomeComfortChatMessages(concern, history, [sampleComfortEvent()], '2026-09-05');
      expect(messages.length).assertEqual(3);
      expect(String(messages[0].content).includes('会一点读心术的解闷搭子')).assertTrue();
      expect(String(messages[0].content).includes('不要用免责声明打断对话')).assertTrue();
      expect(String(messages[0].content).includes('它们都是推测而不是事实')).assertTrue();
      expect(String(messages[0].content).includes('不要把对话变成待办清单')).assertTrue();
      expect(String(messages[0].content).includes('profile_summary')).assertEqual(false);
      expect(String(messages[0].content).includes('当地紧急服务')).assertTrue();
      expect(messages[2].role).assertEqual('user');
      expect(String(messages[2].content)).assertEqual('最近下班确实比较晚。');
    });

    it('rejectsInventedConcernEvidenceReferences', 0, () => {
      let invalid = validConcernResponse().replace(/record-1/g, 'record-99').replace(/profile-1/g, 'profile-99');
      let rejected = false;
      try {
        parseHomeComfortConcerns(invalid, 'batch-3', [sampleComfortEvent()]);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('allowsFewerConcernsWhenChatHasLimitedEmotionalEvidence', 0, () => {
      let single = '{"concerns":[' +
        '{"title":"最近有点累，一起松口气","summary":"聊天中直接提到了疲惫和压力",' +
        '"opening":"最近辛苦了，最让你觉得累的是哪一部分？","category":"work",' +
        '"evidence_refs":["record-1"]}]}';
      let concerns = parseHomeComfortConcerns(single, 'batch-limited', [sampleComfortEvent()]);
      expect(concerns.length).assertEqual(1);
    });

    it('allowsNoConcernWhenChatHasNoClearWorry', 0, () => {
      let concerns = parseHomeComfortConcerns('{"concerns":[]}', 'batch-empty', [sampleComfortEvent()]);
      expect(concerns.length).assertEqual(0);
    });

    it('rejectsDiagnosticConcernClaims', 0, () => {
      let invalid = validConcernResponse().replace('可能有些疲惫', '可能患有焦虑症');
      let rejected = false;
      try {
        parseHomeComfortConcerns(invalid, 'batch-4', [sampleComfortEvent()]);
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
