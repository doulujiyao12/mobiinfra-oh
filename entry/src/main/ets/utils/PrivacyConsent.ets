import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { http } from '@kit.NetworkKit';

export const PRIVACY_STATE_KEY: string = 'privacyConsentState';
export const PERSONAL_MEMORY_SHARING_UNAVAILABLE_MESSAGE: string = '暂时无法确认小艺个人记忆共享授权，请稍后重试。';

export function platformPrivacyChoice(results: privacyManager.AppPrivacyResult[]): string {
  let policies = results.filter((item: privacyManager.AppPrivacyResult): boolean =>
    item.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT);
  if (policies.length === 0) { return 'unselected'; }
  if (policies.some((item: privacyManager.AppPrivacyResult): boolean =>
    item.result === privacyManager.AppPrivacyResultType.DISAGREED)) { return 'rejected'; }
  return policies.every((item: privacyManager.AppPrivacyResult): boolean =>
    item.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED) ? 'accepted' : 'unselected';
}

// External personal-memory sharing only. Foreground app features do not call
// this guard; their requests use AppRequests without an app-wide consent gate.
// The external API still validates actual platform consent and its own opt-in.
export class PrivacyConsent {
  private static choice: string = 'unselected';
  private static requests: http.HttpRequest[] = [];
  private static cancellers: Map<http.HttpRequest, () => void> = new Map();
  private static externalRequests: Map<number, () => void> = new Map();
  private static externalSequence: number = 0;
  private static revokeHandler: (() => void) | null = null;

  static async initialize(_context: common.Context): Promise<void> {
    PrivacyConsent.refreshPlatformState();
  }

  private static refreshPlatformState(): void {
    let next: string;
    try { next = platformPrivacyChoice(privacyManager.getAppPrivacyResult()); }
    catch (e) { next = 'unavailable'; }
    let previous = PrivacyConsent.choice;
    PrivacyConsent.choice = next;
    if (AppStorage.get<string>(PRIVACY_STATE_KEY) !== next) {
      AppStorage.setOrCreate(PRIVACY_STATE_KEY, next);
    }
    if (previous === 'accepted' && next !== 'accepted') { PrivacyConsent.cancelForPlatformRevocation(); }
  }

  static state(): string {
    return PrivacyConsent.choice;
  }

  static isAccepted(): boolean {
    PrivacyConsent.refreshPlatformState();
    return PrivacyConsent.choice === 'accepted';
  }

  static requireAccepted(): void {
    if (!PrivacyConsent.isAccepted()) {
      throw new Error(PERSONAL_MEMORY_SHARING_UNAVAILABLE_MESSAGE);
    }
  }

  static setRevokeHandler(handler: (() => void) | null): void {
    PrivacyConsent.revokeHandler = handler;
  }

  private static cancelForPlatformRevocation(): void {
    const external = Array.from(PrivacyConsent.externalRequests.values());
    PrivacyConsent.externalRequests.clear();
    external.forEach((cancel: () => void): void => { try { cancel(); } catch (e) { } });
    let pending = PrivacyConsent.requests.slice();
    pending.forEach((request: http.HttpRequest): void => {
      try { PrivacyConsent.cancellers.get(request)?.(); }
      catch (e) { }
      finally { PrivacyConsent.destroyHttp(request); }
    });
    try { PrivacyConsent.revokeHandler?.(); } catch (e) { }
  }

  static async openStatement(context: common.UIAbilityContext): Promise<void> {
    let info = privacyManager.getAppPrivacyMgmtInfo();
    let statement = info.privacyInfo.find((item: privacyManager.AppPrivacyLink): boolean =>
      item.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK);
    if (statement === undefined || !/^https?:\/\//i.test(statement.url)) {
      throw new Error('未找到华为托管的隐私政策，请检查应用市场配置');
    }
    await context.openLink(statement.url);
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

  // RCP and other transports participate in the same immediate consent revocation.
  static registerExternalRequest(cancel: () => void): () => void {
    PrivacyConsent.requireAccepted();
    const id = ++PrivacyConsent.externalSequence;
    PrivacyConsent.externalRequests.set(id, cancel);
    return () => { PrivacyConsent.externalRequests.delete(id); };
  }
}
