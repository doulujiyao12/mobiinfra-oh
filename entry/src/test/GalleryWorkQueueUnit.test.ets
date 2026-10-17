import { describe, expect, it } from '@ohos/hypium';
import { runGalleryWorkQueue } from '../main/ets/utils/gallery/GalleryWorkQueue';

export default function galleryWorkQueueUnitTest(): void {
  describe('GalleryWorkQueueUnitTest', (): void => {
    it('drainsStartedWorkersAndDoesNotDispatchAfterFailure', 0, async (): Promise<void> => {
      let release: () => void = (): void => {};
      let held = new Promise<void>((resolve): void => { release = resolve; });
      let started: number[] = [];
      let settled = false;
      let message = '';
      let pending = runGalleryWorkQueue(5, 2, async (index: number): Promise<boolean> => {
        started.push(index);
        if (index === 0) { await Promise.resolve(); throw new Error('write failed'); }
        await held;
        return true;
      }).then((): void => { settled = true; }, (error: Error): void => {
        settled = true; message = error.message;
      });
      await new Promise<void>((resolve): void => { setTimeout(resolve, 0); });
      let settledBeforeDrain = settled;
      release();
      await pending;
      expect(settledBeforeDrain).assertFalse();
      expect(started.join(',')).assertEqual('0,1');
      expect(message).assertEqual('write failed');
    });

    it('stopsTheQueueWhenAWorkerRequestsPause', 0, async (): Promise<void> => {
      let started: number[] = [];
      await runGalleryWorkQueue(5, 1, async (index: number): Promise<boolean> => {
        started.push(index);
        return false;
      });
      expect(started.join(',')).assertEqual('0');
    });

    it('finishesEveryItemWithinTheConcurrencyLimit', 0, async (): Promise<void> => {
      let active = 0;
      let peak = 0;
      let done: number[] = [];
      await runGalleryWorkQueue(5, 2, async (index: number): Promise<boolean> => {
        active++;
        peak = Math.max(peak, active);
        await Promise.resolve();
        done.push(index);
        active--;
        return true;
      });
      expect(done.join(',')).assertEqual('0,1,2,3,4');
      expect(peak).assertEqual(2);
      expect(active).assertEqual(0);
    });
  });
}
