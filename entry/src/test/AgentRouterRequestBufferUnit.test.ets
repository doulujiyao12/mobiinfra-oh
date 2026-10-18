import { describe, expect, it } from '@ohos/hypium';
import { AgentRouterRequestBuffer } from '../main/ets/utils/AgentRouterRequestBuffer';
import { encodeUtf8Compat } from '../main/ets/utils/TextEncodingCompat';

export default function agentRouterRequestBufferUnitTest(): void {
  describe('agentRouterRequestBufferUnitTest', () => {
    it('preservesChineseAndEmojiAcrossEveryPossibleTcpSplit', 0, () => {
      let payload = '{"message":"中文手机🙂任务"}';
      let bytes = encodeUtf8Compat(payload + '<<EOF>>');
      for (let split = 0; split <= bytes.length; split++) {
        let buffer = new AgentRouterRequestBuffer();
        let messages = buffer.feed(bytes.slice(0, split)).concat(buffer.feed(bytes.slice(split)));
        expect(messages.length).assertEqual(1);
        expect(messages[0]).assertEqual(payload);
      }
    });

    it('drainsCoalescedFramesAndRetainsTheTrailingPartialFrame', 0, () => {
      let buffer = new AgentRouterRequestBuffer();
      let messages = buffer.feed(encodeUtf8Compat('{"type":"poll"}<<EOF>>{"type":"clear"}<<EOF>>{"type":'));
      expect(messages.length).assertEqual(2);
      expect(messages[1]).assertEqual('{"type":"clear"}');
      let trailing = buffer.feed(encodeUtf8Compat('"error"}<<EOF>>'));
      expect(trailing.length).assertEqual(1);
      expect(trailing[0]).assertEqual('{"type":"error"}');
    });

    it('boundsCoalescedRequestQueues', 0, () => {
      let failed = false;
      try { new AgentRouterRequestBuffer().feed(encodeUtf8Compat('{}<<EOF>>'.repeat(65))); }
      catch (e) { failed = true; }
      expect(failed).assertTrue();
    });
  });
}
