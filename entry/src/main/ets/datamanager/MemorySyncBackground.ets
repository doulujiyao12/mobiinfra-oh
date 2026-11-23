import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AppLogger } from '../utils/AppLogger';

class MemorySyncBackground {
  private active: boolean = false;
  private foreground: boolean = true;
  private requestId: number = -1;
  private requestEpoch: number = 0;
  private pauseCount: number = 0;
  private foregroundWait: Promise<void> | null = null;
  private resume: (() => void) | null = null;

  begin(): void {
    this.active = true;
    this.pauseCount = 0;
    if (!this.foreground) { this.requestTime(); }
  }

  finish(): void {
    this.active = false;
    this.releaseTime();
    this.resumeWaiters();
  }

  onBackground(): void {
    this.foreground = false;
    if (this.active) { this.requestTime(); }
  }

  onForeground(): void {
    this.foreground = true;
    this.releaseTime();
    this.resumeWaiters();
  }

  onDestroy(): void {
    this.foreground = false;
    if (this.active) { this.pauseCount++; }
    this.releaseTime();
  }

  suspensionCount(): number { return this.pauseCount; }

  async waitIfPaused(): Promise<void> {
    while (this.active && !this.foreground && this.requestId < 0) {
      if (this.foregroundWait === null) {
        this.foregroundWait = new Promise<void>((resolve): void => { this.resume = resolve; });
      }
      await this.foregroundWait;
    }
  }

  private requestTime(): void {
    if (this.requestId >= 0) { return; }
    const epoch = ++this.requestEpoch;
    try {
      const delay = backgroundTaskManager.requestSuspendDelay('同步个人记忆', (): void => {
        if (epoch !== this.requestEpoch) { return; }
        this.pauseCount++;
        this.releaseTime();
        AppLogger.info('MemorySync', 'Background time expired');
      });
      this.requestId = delay.requestId;
      if (delay.actualDelayTime <= 0) {
        this.pauseCount++;
        this.releaseTime();
      }
    } catch (error) {
      this.pauseCount++;
      AppLogger.warnCause('MemorySync', 'Background time unavailable', error as Error);
    }
  }

  private releaseTime(): void {
    this.requestEpoch++;
    const id = this.requestId;
    this.requestId = -1;
    if (id < 0) { return; }
    try { backgroundTaskManager.cancelSuspendDelay(id); }
    catch (error) { AppLogger.warnCause('MemorySync', 'Release background time failed', error as Error); }
  }

  private resumeWaiters(): void {
    const resume = this.resume;
    this.resume = null;
    this.foregroundWait = null;
    resume?.();
  }
}

export const memorySyncBackground: MemorySyncBackground = new MemorySyncBackground();
