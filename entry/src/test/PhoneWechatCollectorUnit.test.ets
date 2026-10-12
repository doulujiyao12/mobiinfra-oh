import { describe, it, expect } from '@ohos/hypium';
import { WorkflowJsonMap } from '../main/ets/utils/WorkflowTypes';
import { PhoneHdcActions } from '../main/ets/utils/selfhdc/PhoneHdcActions';
import {
  mergePhoneWechatSnapshotsForTest,
  parsePhoneWechatChatTimeForTest,
  phoneWechatTestNode
} from '../main/ets/utils/wechat/PhoneWechatCollector';

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
    it('parsesWechatRelativeAndExplicitTimes', 0, () => {
      expect(parsePhoneWechatChatTimeForTest('昨天下午 07:39', '2026-06-11T12:00:00+08:00').indexOf('2026-06-10') >= 0)
        .assertTrue();
      expect(parsePhoneWechatChatTimeForTest('2025年12月31日 20:55', '2026-06-11T12:00:00+08:00').indexOf('2025-12-31') >= 0)
        .assertTrue();
      expect(parsePhoneWechatChatTimeForTest('2025年13月40日 20:55', '2026-06-11T12:00:00+08:00'))
        .assertEqual('');
    });

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

    it('passesSwipeSpeedToHdcCommand', 0, () => {
      let actions = new PhoneHdcActions();
      actions.setScreen(1080, 2340);
      let payload: WorkflowJsonMap = {
        action: 'swipe_with_coords', start_x: 540, start_y: 1800, end_x: 540, end_y: 700, swipe_speed: 1350
      } as Object as WorkflowJsonMap;
      let plan = actions.plan(payload);
      expect(plan.commands[0].command).assertEqual('uitest uiInput swipe 540 1800 540 700 1350');
    });
  });
}
