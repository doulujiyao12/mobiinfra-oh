import { describe, it, expect } from '@ohos/hypium';
import { WorkflowJsonMap } from '../main/ets/utils/WorkflowTypes';
import { PhoneHdcActions } from '../main/ets/utils/selfhdc/PhoneHdcActions';
import { WechatAutoSummaryConversation, WechatAutoSummaryResponse } from '../main/ets/utils/wechat/WechatAutoSummaryTypes';
import { wechatAutoSummaryDailyEntries } from '../main/ets/utils/wechat/WechatAutoSummaryStorage';
import {
  extractPhoneWechatMessagesForTest,
  mergePhoneWechatSnapshotsForTest,
  parsePhoneWechatChatTimeForTest,
  phoneWechatTestNode
} from '../main/ets/utils/wechat/PhoneWechatCollector';

// 显式声明动作形状，确保新注册的用例满足 ArkTS 对对象字面量的限制。
interface SwipeTestPayload {
  action: string;
  start_x: number;
  start_y: number;
  end_x: number;
  end_y: number;
  swipe_speed: number;
}

function uiText(value: string, bounds: string): Object {
  return phoneWechatTestNode('Text', value, bounds);
}

function chatRoot(items: Object[]): Object {
  let list = phoneWechatTestNode('List', '', '[0,0][1080,1000]', items, true);
  return phoneWechatTestNode('Root', '', '[0,0][1080,1000]', [list]);
}

function chatItem(value: string, itemBounds: string, textBounds: string): Object {
  return phoneWechatTestNode('ListItem', '', itemBounds, [uiText(value, textBounds)]);
}

export default function phoneWechatCollectorUnitTest() {
  describe('phoneWechatCollectorUnitTest', () => {
    // 覆盖相对时间、显式日期及非法日期，避免日期截止逻辑接收错误锚点。
    it('parsesWechatRelativeAndExplicitTimes', 0, () => {
      let referenceIso = new Date(2026, 5, 11, 12).toISOString();
      expect(parsePhoneWechatChatTimeForTest('昨天下午 07:39', referenceIso))
        .assertEqual(new Date(2026, 5, 10, 19, 39).toISOString());
      expect(parsePhoneWechatChatTimeForTest('2025年12月31日 20:55', referenceIso))
        .assertEqual(new Date(2025, 11, 31, 20, 55).toISOString());
      expect(parsePhoneWechatChatTimeForTest('2025年13月40日 20:55', '2026-06-11T12:00:00+08:00'))
        .assertEqual('');
    });

    // 只保留请求日期窗口内的消息，过期页不会污染采集结果。
    it('filtersMessagesBeforeCutoffDate', 0, () => {
      let oldRoot = chatRoot([
        chatItem('2026年6月1日 10:00', '[0,80][1080,140]', '[450,90][630,130]'),
        chatItem('过期消息', '[0,180][1080,260]', '[80,190][300,240]')
      ]);
      let currentRoot = chatRoot([
        chatItem('2026年6月10日 10:00', '[0,80][1080,140]', '[450,90][630,130]'),
        chatItem('有效消息', '[0,180][1080,260]', '[80,190][300,240]')
      ]);
      let messages = mergePhoneWechatSnapshotsForTest([currentRoot, oldRoot], '张三', 7,
        '2026-06-10T12:00:00+08:00');
      expect(messages.some((message) => message.text === '过期消息')).assertFalse();
      expect(messages.some((message) => message.text === '有效消息')).assertTrue();
    });

    // 相邻快照中重复出现的边界消息只输出一次。
    it('deduplicatesOverlappingSnapshotBoundaryMessages', 0, () => {
      let oldRoot = chatRoot([
        chatItem('2026年6月9日 10:00', '[0,80][1080,140]', '[450,90][630,130]'),
        chatItem('重复消息', '[0,820][1080,950]', '[80,830][300,900]')
      ]);
      let currentRoot = chatRoot([
        chatItem('2026年6月10日 10:00', '[0,80][1080,140]', '[450,90][630,130]'),
        chatItem('重复消息', '[0,40][1080,160]', '[80,50][300,120]')
      ]);
      let messages = mergePhoneWechatSnapshotsForTest([currentRoot, oldRoot], '张三', 7,
        '2026-06-10T12:00:00+08:00');
      let duplicateCount = messages.filter((message) => message.text === '重复消息').length;
      expect(duplicateCount).assertEqual(1);
    });

    // 手机侧滑动需把速度值传入 HDC 命令，不能只保留界面设置。
    it('passesSwipeSpeedToHdcCommand', 0, () => {
      let actions = new PhoneHdcActions();
      actions.setScreen(1080, 2340);
      let payload: SwipeTestPayload = {
        action: 'swipe_with_coords', start_x: 540, start_y: 1800, end_x: 540, end_y: 700, swipe_speed: 1350
      };
      let plan = actions.plan(payload as Object as WorkflowJsonMap);
      expect(plan.commands[0].command).assertEqual('uitest uiInput swipe 540 1800 540 700 1350');
    });

    // 同一会话中本人与联系人消息同时出现时，导出身份和判断依据必须保持独立。
    it('keepsSelfAndOtherMessageRolesDistinct', 0, () => {
      let selfItem = phoneWechatTestNode('ListItem', '', '[0,100][1080,260]', [
        phoneWechatTestNode('Image', '', '[1000,120][1080,200]'),
        uiText('本人发送的内容', '[720,130][980,190]')
      ]);
      let otherItem = phoneWechatTestNode('ListItem', '', '[0,300][1080,460]', [
        phoneWechatTestNode('Image', '', '[80,320][160,400]'),
        uiText('联系人发送的内容', '[180,330][520,390]')
      ]);
      let messages = extractPhoneWechatMessagesForTest(chatRoot([selfItem, otherItem]), '联系人');
      expect(messages.length).assertEqual(2);
      expect(messages[0].sender).assertEqual('self');
      expect(messages[0].sender_role).assertEqual('self');
      expect(messages[1].sender).assertEqual('联系人');
      expect(messages[1].sender_role).assertEqual('other');
      expect(messages[0].sender_basis).assertEqual('avatar');
      expect(messages[1].sender_basis).assertEqual('avatar');
    });

    // 最终与增量保存都使用此渲染入口，不能把本人内容展示成联系人发言。
    it('rendersSelfAndUnknownSendersWithoutAttributingToContact', 0, () => {
      let selfItem = phoneWechatTestNode('ListItem', '', '[0,100][1080,260]', [
        phoneWechatTestNode('Image', '', '[1000,120][1080,200]'),
        uiText('本人内容', '[720,130][980,190]')
      ]);
      let unknownMedia = phoneWechatTestNode('ListItem', '', '[0,300][1080,600]', [
        phoneWechatTestNode('Image', '', '[350,330][730,560]')
      ]);
      let conversation: WechatAutoSummaryConversation = { title: '联系人',
        messages: extractPhoneWechatMessagesForTest(chatRoot([selfItem, unknownMedia]), '联系人') };
      let response: WechatAutoSummaryResponse = { status: 'partial', conversations: [conversation] };
      let entry = wechatAutoSummaryDailyEntries(response)[0];
      expect(entry.indexOf('本人: 本人内容') >= 0).assertTrue();
      expect(entry.indexOf('发送方未确认: [图片]') >= 0).assertTrue();
      expect(entry.indexOf('联系人: 本人内容') >= 0).assertFalse();
    });
  });
}
