import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { REQUIRE_LOGIN_FOR_AI } from '../main/ets/config/AiAccessConfig';
import {
  aiServiceLoginAllowed,
  AiServiceAccess,
  AI_LOGIN_REQUIRED_MESSAGE,
  HUAWEI_ACCOUNT_SESSION_KEY
} from '../main/ets/utils/AiServiceAccess';

export default function aiServiceAccessUnitTest(): void {
  describe('AiServiceAccess', () => {
    let previousSession: boolean | undefined = undefined;

    beforeEach(() => {
      previousSession = AppStorage.get<boolean>(HUAWEI_ACCOUNT_SESSION_KEY);
    });

    afterEach(() => {
      if (previousSession === undefined) {
        AppStorage.delete(HUAWEI_ACCOUNT_SESSION_KEY);
      } else {
        AppStorage.setOrCreate(HUAWEI_ACCOUNT_SESSION_KEY, previousSession);
      }
    });

    it('enabledSwitchBlocksGuestsAndUninitializedSessions', 0, () => {
      expect(aiServiceLoginAllowed(true, false)).assertFalse();
      expect(aiServiceLoginAllowed(true, undefined)).assertFalse();
    });

    it('enabledSwitchAllowsLoggedInUsers', 0, () => {
      expect(aiServiceLoginAllowed(true, true)).assertTrue();
    });

    it('disabledSwitchAllowsBothGuestsAndLoggedInUsers', 0, () => {
      expect(aiServiceLoginAllowed(false, undefined)).assertTrue();
      expect(aiServiceLoginAllowed(false, false)).assertTrue();
      expect(aiServiceLoginAllowed(false, true)).assertTrue();
    });

    it('readsLiveSharedStateAfterLoginAndLogout', 0, () => {
      AppStorage.setOrCreate(HUAWEI_ACCOUNT_SESSION_KEY, false);
      expect(AiServiceAccess.isAllowed()).assertEqual(!REQUIRE_LOGIN_FOR_AI);
      AppStorage.setOrCreate(HUAWEI_ACCOUNT_SESSION_KEY, true);
      expect(AiServiceAccess.isAllowed()).assertTrue();
      AiServiceAccess.requireAllowed();
      AppStorage.setOrCreate(HUAWEI_ACCOUNT_SESSION_KEY, false);
      expect(AiServiceAccess.isAllowed()).assertEqual(!REQUIRE_LOGIN_FOR_AI);
    });

    it('serviceBoundaryUsesTheSameSwitchAndLoginMessage', 0, () => {
      AppStorage.setOrCreate(HUAWEI_ACCOUNT_SESSION_KEY, false);
      let message = '';
      try {
        AiServiceAccess.requireAllowed();
      } catch (e) {
        message = (e as Error).message;
      }
      expect(message).assertEqual(REQUIRE_LOGIN_FOR_AI ? AI_LOGIN_REQUIRED_MESSAGE : '');
    });
  });
}
