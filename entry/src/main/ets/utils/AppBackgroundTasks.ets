import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { getAppBundleName } from './AppIdentity';

// One system task per ability, shared by Agent transfer and microphone recording.
class AppBackgroundTasks {
  private owners: Map<string, string> = new Map();
  private active: boolean = false;
  private queue: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext | null = null;
  private subscribed: boolean = false;
  private generation: number = 0;
  private cancelled = (): void => {
    this.generation++; this.owners.clear(); this.active = false;
    this.context?.eventHub.emit('recording-background-cancelled');
  };
  set(context: common.UIAbilityContext, owner: string, mode: string, enabled: boolean): Promise<void> {
    this.context = context;
    if (!this.subscribed) {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelled); this.subscribed = true;
    }
    let operation = this.queue.then(async (): Promise<void> => {
      let generation = this.generation;
      let next = new Map<string, string>(this.owners);
      if (enabled) { next.set(owner, mode); } else { next.delete(owner); }
      let modes: string[] = [];
      next.forEach((value: string): void => { if (modes.indexOf(value) < 0) { modes.push(value); } });
      if (modes.length === 0) {
        if (this.active) { await backgroundTaskManager.stopBackgroundRunning(context); }
        this.active = false;
      } else if (this.active) { await backgroundTaskManager.updateBackgroundRunning(context, modes); }
      else {
        let agent = await wantAgent.getWantAgent({ wants: [{ bundleName: getAppBundleName(), abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
        await backgroundTaskManager.startBackgroundRunning(context, modes, agent); this.active = true;
      }
      if (generation !== this.generation && modes.length > 0) {
        this.active = false; throw new Error('系统结束了后台任务，请重新开始录音');
      }
      this.owners = next;
    });
    this.queue = operation.catch((): void => {});
    return operation;
  }
}
export const appBackgroundTasks: AppBackgroundTasks = new AppBackgroundTasks();
