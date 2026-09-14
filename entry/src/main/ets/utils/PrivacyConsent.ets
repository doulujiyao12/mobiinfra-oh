import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';

export const PRIVACY_STATE_KEY: string = 'privacyConsentState';
export const PRIVACY_VERSION: string = '2026-09-13';
export const PRIVACY_REQUIRED_MESSAGE: string = '请先阅读并同意隐私声明，再执行任务或使用云端分析。';

export function normalizePrivacyChoice(value: string): string {
  return value === 'accepted' || value === 'rejected' ? value : 'unselected';
}

export function resolvePrivacyChoice(choice: string, version: string): string {
  return version === PRIVACY_VERSION ? normalizePrivacyChoice(choice) : 'unselected';
}

// Fail closed until the local preference has been loaded. Never infer consent from usage.
export class PrivacyConsent {
  private static store: preferences.Preferences | null = null;
  private static loading: Promise<void> | null = null;
  private static choice: string = 'unselected';
  private static saving: boolean = false;
  private static requests: http.HttpRequest[] = [];
  private static cancellers: Map<http.HttpRequest, () => void> = new Map();
  private static revokeHandler: (() => void) | null = null;

  static initialize(context: common.Context): Promise<void> {
    if (PrivacyConsent.loading === null) {
      PrivacyConsent.loading = PrivacyConsent.load(context).catch(() => {
        PrivacyConsent.loading = null;
        throw new Error('无法读取隐私选择，请稍后重试');
      });
    }
    return PrivacyConsent.loading;
  }

  private static async load(context: common.Context): Promise<void> {
    let store = await preferences.getPreferences(context, { name: 'privacy_consent' });
    let choice = await store.get('choice', 'unselected');
    let version = await store.get('version', '');
    PrivacyConsent.store = store;
    PrivacyConsent.choice = resolvePrivacyChoice(String(choice), String(version));
    AppStorage.setOrCreate(PRIVACY_STATE_KEY, PrivacyConsent.choice);
  }

  static state(): string {
    return PrivacyConsent.choice;
  }

  static isAccepted(): boolean {
    return PrivacyConsent.store !== null && !PrivacyConsent.saving && PrivacyConsent.choice === 'accepted';
  }

  static requireAccepted(): void {
    if (!PrivacyConsent.isAccepted()) {
      throw new Error(PRIVACY_REQUIRED_MESSAGE);
    }
  }

  static setRevokeHandler(handler: (() => void) | null): void {
    PrivacyConsent.revokeHandler = handler;
  }

  static async choose(accepted: boolean): Promise<void> {
    let store = PrivacyConsent.store;
    if (store === null || PrivacyConsent.saving) {
      throw new Error('隐私设置尚未就绪，请稍后重试');
    }
    PrivacyConsent.saving = true;
    // Revocation takes effect before disk I/O, including when the disk write fails.
    PrivacyConsent.choice = accepted ? 'unselected' : 'rejected';
    AppStorage.setOrCreate(PRIVACY_STATE_KEY, PrivacyConsent.choice);
    try {
      if (!accepted) {
        let pending = PrivacyConsent.requests.slice();
        pending.forEach((request: http.HttpRequest) => {
          try {
            PrivacyConsent.cancellers.get(request)?.();
          } catch (e) {
            // Continue aborting the remaining requests if a stream cleanup callback fails.
          } finally {
            PrivacyConsent.destroyHttp(request);
          }
        });
        try {
          PrivacyConsent.revokeHandler?.();
        } catch (e) {
          // A task's cleanup error must not prevent persisting the user's refusal.
        }
      }
      await store.put('choice', accepted ? 'accepted' : 'rejected');
      await store.put('version', PRIVACY_VERSION);
      await store.flush();
      PrivacyConsent.choice = accepted ? 'accepted' : 'rejected';
      AppStorage.setOrCreate(PRIVACY_STATE_KEY, PrivacyConsent.choice);
    } finally {
      PrivacyConsent.saving = false;
    }
  }

  // All user-data HTTP clients register here so revocation aborts requests across instances.
  static createHttp(): http.HttpRequest {
    PrivacyConsent.requireAccepted();
    let request = http.createHttp();
    PrivacyConsent.requests.push(request);
    return request;
  }

  static destroyHttp(request: http.HttpRequest): void {
    PrivacyConsent.cancellers.delete(request);
    if (PrivacyConsent.requests.indexOf(request) < 0) {
      return;
    }
    PrivacyConsent.requests = PrivacyConsent.requests.filter((item: http.HttpRequest) => item !== request);
    try {
      request.destroy();
    } catch (e) {
      // Already aborted by the transport; consent must still be revoked for the other requests.
    }
  }

  static onHttpCancel(request: http.HttpRequest, cancel: () => void): void {
    PrivacyConsent.requireAccepted();
    PrivacyConsent.cancellers.set(request, cancel);
  }
}
