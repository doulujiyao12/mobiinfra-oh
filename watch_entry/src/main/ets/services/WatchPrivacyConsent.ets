import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { WATCH_PRIVACY_POLICY_VERSION } from '../config/WatchPrivacyPolicy';

const ACCEPTED_VERSION_KEY: string = 'accepted_policy_version';

class WatchPrivacyConsent {
  private context: common.UIAbilityContext | undefined = undefined;
  private settings: preferences.Preferences | undefined = undefined;
  private accepted: boolean = false;

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
    this.accepted = false;
    try {
      this.settings = preferences.getPreferencesSync(context, { name: 'watch_privacy' });
      this.accepted = this.settings.getSync(ACCEPTED_VERSION_KEY, '') === WATCH_PRIVACY_POLICY_VERSION;
    } catch (_) { this.settings = undefined; }
  }

  isAccepted(): boolean { return this.accepted; }

  async accept(): Promise<void> {
    if (this.accepted) { return; }
    if (this.context === undefined) { throw new Error('隐私设置尚未就绪，请重新打开应用'); }
    if (this.settings === undefined) {
      try { this.settings = preferences.getPreferencesSync(this.context, { name: 'watch_privacy' }); }
      catch (_) { throw new Error('无法保存隐私选择，请重试'); }
    }
    const settings = this.settings;
    const previous = settings.getSync(ACCEPTED_VERSION_KEY, '');
    try {
      settings.putSync(ACCEPTED_VERSION_KEY, WATCH_PRIVACY_POLICY_VERSION);
      await settings.flush();
      // No service may start until the user's explicit choice is persisted.
      this.accepted = true;
    } catch (_) {
      try { settings.putSync(ACCEPTED_VERSION_KEY, previous); } catch (_) {}
      throw new Error('无法保存隐私选择，请重试');
    }
  }
}

export const watchPrivacyConsent: WatchPrivacyConsent = new WatchPrivacyConsent();
