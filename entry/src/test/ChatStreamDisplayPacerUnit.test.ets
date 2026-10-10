import { describe, it, expect } from '@ohos/hypium';
import {
  CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS,
  CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK,
  ChatStreamDisplayPacer,
  ChatStreamDisplaySnapshot
} from '../main/ets/pages/chat/ChatStreamDisplayPacer';

export default function chatStreamDisplayPacerUnitTest() {
  describe('chatStreamDisplayPacerUnitTest', () => {
    it('pacesUnevenTargetDeltasWithBoundedNormalSteps', 0, () => {
      let pacer: ChatStreamDisplayPacer = new ChatStreamDisplayPacer();
      pacer.setTarget('s1', 'm1', '这是一段一次性返回很多字符的模型输出内容', []);

      let first: ChatStreamDisplaySnapshot = pacer.advanceFrame();
      let firstDelta = first.visibleContent.length;
      let second: ChatStreamDisplaySnapshot = pacer.advanceFrame();
      let secondDelta = second.visibleContent.length - first.visibleContent.length;

      expect(firstDelta > 0).assertTrue();
      expect(firstDelta <= CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK).assertTrue();
      expect(secondDelta > 0).assertTrue();
      expect(secondDelta <= CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK).assertTrue();
      expect(second.visibleContent.length < first.targetContentLength).assertTrue();
    });

    it('acceleratesWhenBacklogIsLargeWithoutJumpingWholeTarget', 0, () => {
      let pacer: ChatStreamDisplayPacer = new ChatStreamDisplayPacer();
      pacer.setTarget('s1', 'm1',
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz', []);

      let first: ChatStreamDisplaySnapshot = pacer.advanceFrame();
      let second: ChatStreamDisplaySnapshot = pacer.advanceFrame();
      let firstDelta = first.visibleContent.length;
      let secondDelta = second.visibleContent.length - first.visibleContent.length;

      expect(firstDelta).assertEqual(CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK);
      expect(secondDelta).assertEqual(CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK);
      expect(second.visibleContent.length < second.targetContentLength).assertTrue();
    });

    it('finishesWithinConfiguredCatchupTicks', 0, () => {
      let pacer: ChatStreamDisplayPacer = new ChatStreamDisplayPacer();
      pacer.setTarget('s1', 'm1', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', []);
      pacer.advanceFrame();
      pacer.beginFinish('s1', 'm1', 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', []);

      for (let i = 0; i < CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS; i++) {
        pacer.advanceFrame();
      }
      let snapshot: ChatStreamDisplaySnapshot = pacer.snapshot();

      expect(snapshot.visibleContent).assertEqual('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ');
      expect(snapshot.complete).assertTrue();
      expect(snapshot.active).assertFalse();
    });

    it('resetsWhenMessageIdentityChanges', 0, () => {
      let pacer: ChatStreamDisplayPacer = new ChatStreamDisplayPacer();
      pacer.setTarget('s1', 'm1', '第一条消息内容', ['trace1']);
      pacer.advanceFrame();

      let snapshot: ChatStreamDisplaySnapshot = pacer.setTarget('s1', 'm2', '第二条消息内容', ['trace2']);

      expect(snapshot.messageId).assertEqual('m2');
      expect(snapshot.visibleContent).assertEqual('');
      expect(snapshot.visibleTrace.length).assertEqual(1);
      expect(snapshot.visibleTrace[0]).assertEqual('trace2');
      expect(snapshot.active).assertTrue();
    });

    it('preservesCommonPrefixWhenStreamingTargetIsRevised', 0, () => {
      let pacer: ChatStreamDisplayPacer = new ChatStreamDisplayPacer();
      let firstTarget = '<think>第一段思考</think>\n\n';
      pacer.beginFinish('s1', 'm1', firstTarget, []);
      for (let i = 0; i < CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS; i++) {
        pacer.advanceFrame();
      }

      let snapshot: ChatStreamDisplaySnapshot =
        pacer.setTarget('s1', 'm1', '<think>第一段思考第二段思考</think>\n\n', []);

      expect(snapshot.visibleContent).assertEqual('<think>第一段思考');
      expect(snapshot.visibleContent.length > 0).assertTrue();
      expect(snapshot.active).assertTrue();
    });
  });
}
