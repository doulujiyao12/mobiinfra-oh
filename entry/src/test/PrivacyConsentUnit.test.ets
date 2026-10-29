import { describe, it, expect } from '@ohos/hypium';
import { privacyManager } from '@kit.AppGalleryKit';
import { platformPrivacyChoice } from '../main/ets/utils/PrivacyConsent';

function result(type: privacyManager.AppPrivacyType, value: privacyManager.AppPrivacyResultType): privacyManager.AppPrivacyResult {
  return { type: type, result: value, versionCode: 1, id: 'fixture' };
}

export default function privacyConsentUnitTest(): void {
  describe('HuaweiPrivacyConsentPolicy', () => {
    it('requiresAnActualPlatformPrivacyResult', 0, () => {
      expect(platformPrivacyChoice([])).assertEqual('unselected');
      expect(platformPrivacyChoice([result(privacyManager.AppPrivacyType.USER_AGREEMENT,
        privacyManager.AppPrivacyResultType.FULL_MODE_AGREED)])).assertEqual('unselected');
    });

    it('usesSystemAcceptanceAndRefusalWithoutAnAppDialog', 0, () => {
      expect(platformPrivacyChoice([result(privacyManager.AppPrivacyType.PRIVACY_AGREEMENT,
        privacyManager.AppPrivacyResultType.FULL_MODE_AGREED)])).assertEqual('accepted');
      expect(platformPrivacyChoice([result(privacyManager.AppPrivacyType.PRIVACY_AGREEMENT,
        privacyManager.AppPrivacyResultType.DISAGREED)])).assertEqual('rejected');
    });

    it('doesNotAcceptUnknownPlatformStatuses', 0, () => {
      expect(platformPrivacyChoice([result(privacyManager.AppPrivacyType.PRIVACY_AGREEMENT,
        99 as privacyManager.AppPrivacyResultType)])).assertEqual('unselected');
    });

    it('respectsPlatformRequestsToResignAnUpdatedPolicy', 0, () => {
      expect(platformPrivacyChoice([result(privacyManager.AppPrivacyType.PRIVACY_AGREEMENT,
        privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE)])).assertEqual('unselected');
    });
  });
}
