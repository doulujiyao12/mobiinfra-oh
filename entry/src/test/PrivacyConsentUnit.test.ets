import { describe, it, expect } from '@ohos/hypium';
import { resolvePrivacyChoice, PRIVACY_VERSION } from '../main/ets/utils/PrivacyConsent';

export default function privacyConsentUnitTest(): void {
  describe('PrivacyConsentPolicy', () => {
    it('requiresAnExplicitChoiceOnFreshInstall', 0, () => {
      expect(resolvePrivacyChoice('', '')).assertEqual('unselected');
      expect(resolvePrivacyChoice('unselected', PRIVACY_VERSION)).assertEqual('unselected');
    });

    it('restoresBothAcceptanceAndRefusalWithoutAnotherStartupPrompt', 0, () => {
      expect(resolvePrivacyChoice('accepted', PRIVACY_VERSION)).assertEqual('accepted');
      expect(resolvePrivacyChoice('rejected', PRIVACY_VERSION)).assertEqual('rejected');
    });

    it('doesNotTreatLegacyOrCorruptValuesAsConsent', 0, () => {
      expect(resolvePrivacyChoice('true', PRIVACY_VERSION)).assertEqual('unselected');
      expect(resolvePrivacyChoice('accepted ', PRIVACY_VERSION)).assertEqual('unselected');
      expect(resolvePrivacyChoice('accepted', '')).assertEqual('unselected');
    });

    it('requiresNewConsentWhenTheDeclarationVersionChanges', 0, () => {
      expect(resolvePrivacyChoice('accepted', 'previous-version')).assertEqual('unselected');
      expect(resolvePrivacyChoice('rejected', 'previous-version')).assertEqual('unselected');
    });
  });
}
