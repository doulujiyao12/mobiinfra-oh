import { describe, it, expect } from '@ohos/hypium';
import {
  AppBackupCrypto,
  AppBackupEnvelope,
  AppBackupPayload
} from '../../../main/ets/utils/AppBackupManager';

export default function appBackupCryptoDeviceTest() {
  describe('AppBackupCryptoDeviceTest', () => {
    it('encryptDecryptWithDeviceCrypto', 0, async () => {
      // 设备测试使用真实 CryptoFramework，覆盖 Darwin 宿主单测无法稳定验证的 AES-GCM 行为。
      let payload: AppBackupPayload = {
        schemaVersion: 1,
        createdAt: '2026-06-12T15:30:00+08:00',
        includeSensitiveSettings: false,
        settings: {},
        files: [
          {
            path: 'workflows/daily-log/2026-06-12/device.md',
            encoding: 'utf8',
            content: '设备端采集明文内容',
            size: 27,
            modifiedTime: 100
          }
        ]
      };

      let envelope: AppBackupEnvelope = await AppBackupCrypto.encryptPayload(payload, 'strong-password');
      let serialized = AppBackupCrypto.serializeEnvelope(envelope);
      expect(serialized.indexOf('设备端采集明文内容')).assertEqual(-1);
      expect(serialized.indexOf('workflows/daily-log')).assertEqual(-1);

      let restored = await AppBackupCrypto.decryptPayload(envelope, 'strong-password');
      expect(restored.files.length).assertEqual(1);
      expect(restored.files[0].content).assertEqual('设备端采集明文内容');

      let failed = false;
      try {
        await AppBackupCrypto.decryptPayload(envelope, 'wrong-password');
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
    });
  });
}
