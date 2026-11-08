import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { WATCH_BUNDLE_NAME, WATCH_ABILITY_NAME } from '../config/PhonePeer';

type CancelListener = () => void;

/** One shared task: ending file transfer must not cancel an ongoing microphone session. */
class BackgroundTasks {
  private context: common.UIAbilityContext | undefined = undefined;
  private modes: string[] = [];
  private active: boolean = false;
  private queue: Promise<void> = Promise.resolve();
  private listeners: CancelListener[] = [];
  private registered: boolean = false;
  private cancelled = (): void => {
    this.active = false;
    this.modes = [];
    this.listeners.forEach((listener: CancelListener) => listener());
  };

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
    if (!this.registered && canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelled);
      this.registered = true;
    }
  }
  onCancel(listener: CancelListener): void { this.listeners.push(listener); }
  offCancel(listener: CancelListener): void { this.listeners = this.listeners.filter((item: CancelListener) => item !== listener); }

  setMode(mode: string, enabled: boolean): Promise<void> {
    const operation: Promise<void> = this.queue.then(async () => {
      if (this.context === undefined) { throw new Error('后台任务上下文不可用'); }
      let next: string[] = this.modes.filter((value: string) => value !== mode);
      if (enabled) { next.push(mode); }
      next.sort();
      if (next.join(',') === this.modes.join(',') && this.active === (next.length > 0)) { return; }
      if (next.length === 0) {
        if (this.active) { await backgroundTaskManager.stopBackgroundRunning(this.context); }
        this.active = false;
      } else if (this.active) {
        await backgroundTaskManager.updateBackgroundRunning(this.context, next);
      } else {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: WATCH_BUNDLE_NAME, abilityName: WATCH_ABILITY_NAME }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        await backgroundTaskManager.startBackgroundRunning(this.context, next, agent);
        this.active = true;
      }
      this.modes = next;
    });
    this.queue = operation.catch(() => {});
    return operation;
  }

  destroy(): void {
    if (this.registered) { backgroundTaskManager.off('continuousTaskCancel', this.cancelled); }
    this.registered = false;
    this.listeners = [];
  }
}
export const backgroundTasks: BackgroundTasks = new BackgroundTasks();
