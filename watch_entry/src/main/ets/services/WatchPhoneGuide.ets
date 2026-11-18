import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const HIDDEN_KEY: string = 'phone_guide_hidden';

export class WatchPhoneGuide {
  private settings: preferences.Preferences;

  constructor(context: common.UIAbilityContext) {
    this.settings = preferences.getPreferencesSync(context, { name: 'watch_onboarding' });
  }

  shouldShow(): boolean {
    return this.settings.getSync(HIDDEN_KEY, false) !== true;
  }

  async dismissPermanently(): Promise<void> {
    const previous = this.settings.getSync(HIDDEN_KEY, false);
    try {
      this.settings.putSync(HIDDEN_KEY, true);
      await this.settings.flush();
    } catch (_) {
      this.settings.putSync(HIDDEN_KEY, previous);
      throw new Error('未能保存选择，请重试');
    }
  }
}
