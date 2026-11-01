import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { PrivacyConsent } from '../utils/PrivacyConsent';

export const PERSONAL_MEMORY_A2A_STATE_KEY: string = 'personalMemoryA2aEnabled';
export const PERSONAL_MEMORY_A2A_SCOPE: string = 'all-indexed-memory-v1';

export function canExposePersonalMemory(platformAccepted: boolean, enabled: boolean,
  apiVersion: number, scope: string): boolean {
  return apiVersion >= 24 && platformAccepted && enabled &&
    scope === PERSONAL_MEMORY_A2A_SCOPE;
}

// Personal memory is never exposed to an external Agent until the user opts in.
export class PersonalMemoryAccess {
  static async isEnabled(context: common.Context): Promise<boolean> {
    if (deviceInfo.sdkApiVersion < 24) {
      return false;
    }
    await PrivacyConsent.initialize(context);
    let store = await preferences.getPreferences(context, { name: 'personal_memory_a2a' });
    let enabled = await store.get('enabled', false) === true;
    let scope = String(await store.get('scope', ''));
    return canExposePersonalMemory(PrivacyConsent.isAccepted(), enabled, deviceInfo.sdkApiVersion, scope);
  }

  static async setEnabled(context: common.Context, enabled: boolean): Promise<boolean> {
    if (enabled) {
      if (deviceInfo.sdkApiVersion < 24) {
        throw new Error('当前系统暂不支持小艺端侧 A2A');
      }
      await PrivacyConsent.initialize(context);
      PrivacyConsent.requireAccepted();
    }
    let store = await preferences.getPreferences(context, { name: 'personal_memory_a2a' });
    await store.put('enabled', enabled);
    if (enabled) {
      await store.put('scope', PERSONAL_MEMORY_A2A_SCOPE);
    }
    await store.flush();
    AppStorage.setOrCreate(PERSONAL_MEMORY_A2A_STATE_KEY, enabled);
    return enabled;
  }
}
