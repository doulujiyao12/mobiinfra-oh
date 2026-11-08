import { UIAbility, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { recorderController } from '../services/RecorderController';
import { phoneSyncController } from '../services/PhoneSyncController';
import { backgroundTasks } from '../services/BackgroundTasks';

export default class HiWearMainAbility extends UIAbility {
  onCreate(): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    recorderController.initialize(this.context);
    phoneSyncController.initialize(this.context);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }

  onForeground(): void {
    recorderController.setForeground(true);
    phoneSyncController.connect().catch(() => {});
  }
  onBackground(): void { recorderController.setForeground(false); }
  async onDestroy(): Promise<void> {
    await Promise.allSettled([phoneSyncController.destroy(), recorderController.destroy()]);
    backgroundTasks.destroy();
  }
}
