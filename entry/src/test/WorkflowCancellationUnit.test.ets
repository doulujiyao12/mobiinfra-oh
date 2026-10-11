import { describe, expect, it } from '@ohos/hypium';
import { WorkflowCancellation } from '../main/ets/utils/WorkflowCancellation';
import { CancellableWorkflowHdcBridge } from '../main/ets/utils/CancellableWorkflowHdcBridge';
import { WorkflowJsonMap } from '../main/ets/utils/WorkflowTypes';

export default function workflowCancellationUnitTest(): void {
  describe('workflowCancellationUnitTest', () => {
    it('cancelsTheActiveOperationOnce', 0, () => {
      let cancellation = new WorkflowCancellation();
      let calls = 0;
      cancellation.setHandler((): void => { calls++; });
      cancellation.cancel();
      cancellation.cancel();
      expect(cancellation.isCancelled()).assertTrue();
      expect(calls).assertEqual(1);
    });

    it('keepsCancellationAcrossTaskCleanup', 0, () => {
      let cancellation = new WorkflowCancellation();
      let firstTaskCalls = 0;
      cancellation.setHandler((): void => { firstTaskCalls++; });
      cancellation.cancel();
      cancellation.setHandler(null);
      let blocked = false;
      try { cancellation.throwIfCancelled(); } catch (e) { blocked = true; }
      expect(blocked).assertTrue();
      expect(firstTaskCalls).assertEqual(1);
      expect(new WorkflowCancellation().isCancelled()).assertFalse();
    });

    it('notifiesAnOperationAttachedAfterEarlyStop', 0, () => {
      let cancellation = new WorkflowCancellation();
      cancellation.cancel();
      let notified = false;
      cancellation.setHandler((): void => { notified = true; });
      expect(notified).assertTrue();
    });

    it('doesNotCancelAFinishedOperation', 0, () => {
      let cancellation = new WorkflowCancellation();
      let calls = 0;
      cancellation.setHandler((): void => { calls++; });
      cancellation.setHandler(null);
      cancellation.cancel();
      expect(calls).assertEqual(0);
    });

    it('blocksContinuationAfterAsyncPreparation', 0, async () => {
      let cancellation = new WorkflowCancellation();
      let dispatched = false;
      let operation = async (): Promise<void> => {
        await Promise.resolve();
        cancellation.throwIfCancelled();
        dispatched = true;
      };
      let pending = operation();
      cancellation.cancel();
      let cancelled = false;
      try { await pending; } catch (e) { cancelled = true; }
      expect(cancelled).assertTrue();
      expect(dispatched).assertFalse();
    });

    it('blocksPcGuiActionsBeforeTransportDispatch', 0, async () => {
      let cancellation = new WorkflowCancellation();
      let bridge = new CancellableWorkflowHdcBridge('', (message: string): void => {}, cancellation);
      cancellation.cancel();
      let cancelled = false;
      let payload: WorkflowJsonMap = { action: 'tap', x: 100, y: 100 };
      try { await bridge.guiAction(payload); }
      catch (e) { cancelled = (e as Error).message.indexOf('用户取消') >= 0; }
      expect(cancelled).assertTrue();
    });

    it('blocksPcAppLaunchBeforeTransportDispatch', 0, async () => {
      let cancellation = new WorkflowCancellation();
      let bridge = new CancellableWorkflowHdcBridge('', (message: string): void => {}, cancellation);
      cancellation.cancel();
      let cancelled = false;
      try { await bridge.startApp('目标应用', 'com.example.target', true); }
      catch (e) { cancelled = (e as Error).message.indexOf('用户取消') >= 0; }
      expect(cancelled).assertTrue();
    });
  });
}
