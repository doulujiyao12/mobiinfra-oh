import { describe, expect, it } from '@ohos/hypium';
import { authentication } from '@kit.AccountKit';
import { HuaweiAccountSessionRecord, verifyHuaweiAccountSession } from '../main/ets/utils/HuaweiAccountSession';

export default function huaweiAccountSessionUnitTest() {
  describe('huaweiAccountSessionUnitTest', () => {
    it('restoresAnAuthorizedAccountWithoutAnAppStorageFlag', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let queriedId = '';
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (openId: string): Promise<authentication.State> => {
          queriedId = openId;
          return authentication.State.AUTHORIZED;
        }
      );
      expect(allowed).assertTrue();
      expect(queriedId).assertEqual('test-account');
    });

    it('doesNotTreatDeviceLoginAsAppLoginWithoutASavedSession', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: '', revision: '' };
      let calls = 0;
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => {
          calls += 1;
          return authentication.State.AUTHORIZED;
        }
      );
      expect(allowed).assertFalse();
      expect(calls).assertEqual(0);
    });

    it('requiresASessionRevision', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: '' };
      let calls = 0;
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => {
          calls += 1;
          return authentication.State.AUTHORIZED;
        }
      );
      expect(allowed).assertFalse();
      expect(calls).assertEqual(0);
    });

    it('rejectsAnAccountSignedOutOfTheDevice', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => authentication.State.UNLOGGED_IN
      );
      expect(allowed).assertFalse();
    });

    it('rejectsRevokedHuaweiAuthorization', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => authentication.State.UNAUTHORIZED
      );
      expect(allowed).assertFalse();
    });

    it('doesNotRestoreAReplyThatArrivesAfterLocalLogout', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => {
          record = { openId: '', revision: 'logout-2' };
          return authentication.State.AUTHORIZED;
        }
      );
      expect(allowed).assertFalse();
    });

    it('rejectsAStaleReplyEvenAfterTheSameAccountLogsInAgain', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => record,
        async (_openId: string): Promise<authentication.State> => {
          record = { openId: 'test-account', revision: 'login-3' };
          return authentication.State.AUTHORIZED;
        }
      );
      expect(allowed).assertFalse();
    });

    it('keepsStateCheckFailuresDistinctFromASignedOutResult', 0, async () => {
      let record: HuaweiAccountSessionRecord = { openId: 'test-account', revision: 'login-1' };
      let failure = '';
      try {
        await verifyHuaweiAccountSession(
          (): HuaweiAccountSessionRecord => record,
          async (_openId: string): Promise<authentication.State> => { throw new Error('state service unavailable'); }
        );
      } catch (e) {
        let error = e as Error;
        failure = error.message;
      }
      expect(failure).assertEqual('state service unavailable');
    });
  });
}
