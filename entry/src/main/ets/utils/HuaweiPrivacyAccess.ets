import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { PrivacyConsent } from './PrivacyConsent';
import { showToastSafely } from './PromptSafe';

// Optional policy link only. Agreement presentation belongs to Huawei's app
// entry; this helper must never become a prerequisite for an in-app feature.
export class HuaweiPrivacyAccess {
  static async openPolicy(uiContext: UIContext): Promise<void> {
    let context = uiContext.getHostContext();
    if (context === undefined) { return; }
    try { await PrivacyConsent.openStatement(context as common.UIAbilityContext); }
    catch (e) { showToastSafely('暂时无法打开隐私政策，请稍后重试', 2000); }
  }
}
