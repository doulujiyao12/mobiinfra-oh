import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { PRIVACY_VERSION } from '../utils/PrivacyConsent';

export const PERSONAL_MEMORY_A2A_STATE_KEY: string = 'personalMemoryA2aEnabled';
export const PERSONAL_MEMORY_A2A_SCOPE: string = 'all-indexed-memory-v1';

export function canExposePersonalMemory(choice: string, version: string, enabled: boolean,
  apiVersion: number, scope: string): boolean {
  return apiVersion >= 24 && choice === 'accepted' && version === PRIVACY_VERSION && enabled &&
    scope === PERSONAL_MEMORY_A2A_SCOPE;
}

// Personal memory is never exposed to an external Agent until the user opts in.
export class PersonalMemoryAccess {
  static async isEnabled(context: common.Context): Promise<boolean> {
    if (deviceInfo.sdkApiVersion < 24) {
      return false;
    }
    let privacy = await preferences.getPreferences(context, { name: 'privacy_consent' });
    let choice = String(await privacy.get('choice', 'unselected'));
    let version = String(await privacy.get('version', ''));
    let store = await preferences.getPreferences(context, { name: 'personal_memory_a2a' });
    let enabled = await store.get('enabled', false) === true;
    let scope = String(await store.get('scope', ''));
    return canExposePersonalMemory(choice, version, enabled, deviceInfo.sdkApiVersion, scope);
  }

  static async setEnabled(context: common.Context, enabled: boolean): Promise<boolean> {
    if (enabled) {
      if (deviceInfo.sdkApiVersion < 24) {
        throw new Error('当前系统暂不支持小艺端侧 A2A');
      }
      let privacy = await preferences.getPreferences(context, { name: 'privacy_consent' });
      if (String(await privacy.get('choice', 'unselected')) !== 'accepted' ||
        String(await privacy.get('version', '')) !== PRIVACY_VERSION) {
        throw new Error('请先同意隐私声明');
      }
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
