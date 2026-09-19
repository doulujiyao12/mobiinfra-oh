import { describe, it, expect } from '@ohos/hypium';
import { HomeComfortChatStore } from '../main/ets/pages/home/HomeComfortChatStore';
import { HomeComfortChatMessage, HomeComfortConcern } from '../main/ets/pages/home/HomeEmotionalSupport';

function concern(id: string): HomeComfortConcern {
  return { id: id, title: id, summary: '聊聊近况', opening: '今天想聊点什么？', category: 'life', evidence: [] };
}

class PendingReply {
  promise: Promise<string>;
  resolve: (reply: string) => void = (reply: string) => {};
  reject: (error: Error) => void = (error: Error) => {};

  constructor() {
    this.promise = new Promise<string>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

export default function homeComfortChatStoreUnitTest() {
  describe('homeComfortChatStoreUnitTest', () => {
    it('reopensSameConcernWithHistoryAndOnlyOneOpening', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('one');
      let first = store.open(item);
      await store.send(item, '最近很累', async (): Promise<string> => '愿意聊聊吗？');
      let reopened = store.open(item);
      expect(reopened.id).assertEqual(first.id);
      expect(reopened.messages.length).assertEqual(3);
      expect(reopened.messages[1].content).assertEqual('最近很累');
      expect(reopened.messages[2].content).assertEqual('愿意聊聊吗？');
      expect(store.open(item).messages.length).assertEqual(3);
    });

    it('keepsConcernHistoriesSeparateAndRestartsOnlyCurrentConcern', 0, async () => {
      let store = new HomeComfortChatStore();
      let first = concern('first');
      let second = concern('second');
      let old = store.open(first);
      store.open(second);
      await store.send(first, '第一件事', async (): Promise<string> => '第一件事的回复');
      await store.send(second, '第二件事', async (): Promise<string> => '第二件事的回复');
      let restarted = store.restart(first);
      expect(restarted.id !== old.id).assertTrue();
      expect(restarted.messages.length).assertEqual(1);
      expect(restarted.messages[0].content).assertEqual(first.opening);
      expect(restarted.sending).assertFalse();
      expect(restarted.error).assertEqual('');
      expect(store.open(second).messages.length).assertEqual(3);
    });

    it('keepsPendingReplyWhenChatIsReopenedAndPreventsDuplicateSend', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('pending');
      store.open(item);
      let reply = new PendingReply();
      let request = store.send(item, '等你回复', async (): Promise<string> => reply.promise);
      expect(store.open(item).sending).assertTrue();
      let duplicateCalls = 0;
      await store.send(item, '重复发送', async (): Promise<string> => {
        duplicateCalls++;
        return '不应发送';
      });
      expect(duplicateCalls).assertEqual(0);
      reply.resolve('回复到了');
      await request;
      expect(store.open(item).messages.length).assertEqual(3);
      expect(store.open(item).messages[2].content).assertEqual('回复到了');
      expect(store.open(item).sending).assertFalse();
    });

    it('ignoresLateReplyAfterRestartAndSendsOnlyNewSessionHistory', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('restart');
      store.open(item);
      let reply = new PendingReply();
      let oldRequest = store.send(item, '旧消息', async (): Promise<string> => reply.promise);
      store.restart(item);
      await store.send(item, '新消息', async (_item: HomeComfortConcern,
        history: HomeComfortChatMessage[]): Promise<string> => {
        expect(history.length).assertEqual(2);
        expect(history[1].content).assertEqual('新消息');
        return '新回复';
      });
      reply.resolve('旧回复');
      await oldRequest;
      let history = store.open(item).messages;
      expect(history.length).assertEqual(3);
      expect(history[2].content).assertEqual('新回复');
    });

    it('clearsAllSessionsOnRefreshAndRejectsOldCasualChatReply', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('comfort-casual-chat');
      let old = store.open(item);
      store.open(concern('old-concern'));
      let reply = new PendingReply();
      let request = store.send(item, '刷新前', async (): Promise<string> => reply.promise);
      store.clear();
      expect(store.sessions.length).assertEqual(0);
      let reopened = store.open(item);
      expect(reopened.id !== old.id).assertTrue();
      reply.resolve('过期回复');
      await request;
      expect(store.open(item).messages.length).assertEqual(1);
      expect(store.get('old-concern')).assertUndefined();
    });

    it('doesNotLetOldFailureChangeNewPendingSession', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('failure-race');
      store.open(item);
      let oldReply = new PendingReply();
      let oldRequest = store.send(item, '旧消息', async (): Promise<string> => oldReply.promise);
      store.restart(item);
      let newReply = new PendingReply();
      let newRequest = store.send(item, '新消息', async (): Promise<string> => newReply.promise);
      oldReply.reject(new Error('旧请求失败'));
      await oldRequest;
      expect(store.open(item).sending).assertTrue();
      expect(store.open(item).error).assertEqual('');
      newReply.resolve('新回复');
      await newRequest;
      expect(store.open(item).messages[2].content).assertEqual('新回复');
    });

    it('retainsUserMessageOnFailureAndRestartClearsError', 0, async () => {
      let store = new HomeComfortChatStore();
      let item = concern('failure');
      store.open(item);
      await store.send(item, '我的近况', async (): Promise<string> => {
        throw new Error('网络连接失败');
      });
      expect(store.open(item).messages.length).assertEqual(2);
      expect(store.open(item).error).assertEqual('网络连接失败');
      expect(store.open(item).sending).assertFalse();
      expect(store.restart(item).error).assertEqual('');
      expect(store.open(item).messages.length).assertEqual(1);
    });
  });
}
