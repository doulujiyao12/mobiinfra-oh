import { UIAbility, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { recorderController } from '../services/RecorderController';
import { phoneSyncController } from '../services/PhoneSyncController';
import { backgroundTasks } from '../services/BackgroundTasks';
import { watchPrivacyConsent } from '../services/WatchPrivacyConsent';
import { WATCH_PRIVACY_ACCEPTED_EVENT } from '../config/WatchPrivacyPolicy';

export default class HiWearMainAbility extends UIAbility {
  private servicesStarted: boolean = false;
  private foreground: boolean = false;
  private destroyed: boolean = false;
  private privacyAccepted = (): void => { this.startServices(); };

  onCreate(): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    watchPrivacyConsent.initialize(this.context);
    this.context.eventHub.on(WATCH_PRIVACY_ACCEPTED_EVENT, this.privacyAccepted);
  }

  private startServices(): void {
    if (this.destroyed || !this.foreground || this.servicesStarted || !watchPrivacyConsent.isAccepted()) { return; }
    this.servicesStarted = true;
    recorderController.initialize(this.context);
    recorderController.setForeground(true);
    phoneSyncController.initialize(this.context);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }

  onForeground(): void {
    this.foreground = true;
    this.startServices();
    if (this.servicesStarted) {
      recorderController.setForeground(true);
      phoneSyncController.connect().catch(() => {});
    }
  }
  onBackground(): void {
    this.foreground = false;
    if (this.servicesStarted) { recorderController.setForeground(false); }
  }
  async onDestroy(): Promise<void> {
    this.destroyed = true;
    this.context.eventHub.off(WATCH_PRIVACY_ACCEPTED_EVENT, this.privacyAccepted);
    if (this.servicesStarted) {
      await Promise.allSettled([phoneSyncController.destroy(), recorderController.destroy()]);
      backgroundTasks.destroy();
    }
  }
}
