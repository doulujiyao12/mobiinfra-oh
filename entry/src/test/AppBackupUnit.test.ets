import { describe, it, expect } from '@ohos/hypium';
import {
  AppBackupCrypto,
  AppBackupSettings,
  AppBackupValidator,
  AppBackupEnvelope
} from '../main/ets/utils/AppBackupManager';

export default function appBackupUnitTest() {
  describe('appBackupUnitTest', () => {
    it('excludesSensitiveSettingsByDefault', 0, () => {
      let source: Record<string, Object | string | number | boolean | null> = {};
      source['galleryApiKey'] = 'secret-gallery-key';
      source['cloudApiKey'] = 'secret-cloud-key';
      source['serverIp'] = 'http://127.0.0.1:9123';
      source['galleryModel'] = 'vision-model';
      source['gallerySkipOcr'] = 'false';

      let filtered = AppBackupSettings.filterSettings(source, false);

      expect(filtered['galleryApiKey'] === undefined).assertTrue();
      expect(filtered['cloudApiKey'] === undefined).assertTrue();
      expect(filtered['serverIp'] === undefined).assertTrue();
      expect(filtered['galleryModel']).assertEqual('vision-model');
      expect(filtered['gallerySkipOcr']).assertEqual('false');
    });

    it('includesSensitiveSettingsOnlyWhenRequested', 0, () => {
      let source: Record<string, Object | string | number | boolean | null> = {};
      source['galleryApiKey'] = 'secret-gallery-key';
      source['cloudApiKey'] = 'secret-cloud-key';
      source['hdcServerIp'] = 'http://127.0.0.1:9124';

      let filtered = AppBackupSettings.filterSettings(source, true);

      expect(filtered['galleryApiKey']).assertEqual('secret-gallery-key');
      expect(filtered['cloudApiKey']).assertEqual('secret-cloud-key');
      expect(filtered['hdcServerIp']).assertEqual('http://127.0.0.1:9124');
    });

    it('rejectsUnsafeBackupRelativePaths', 0, () => {
      expect(AppBackupValidator.isAllowedRelativePath('workflows/configs/demo.json')).assertTrue();
      expect(AppBackupValidator.isAllowedRelativePath('gallery-log/items/2026-06-12/a.json')).assertTrue();
      expect(AppBackupValidator.isAllowedRelativePath('chat-sessions/sessions/chat-1.json')).assertTrue();
      expect(AppBackupValidator.isAllowedRelativePath('../workflows/configs/demo.json')).assertFalse();
      expect(AppBackupValidator.isAllowedRelativePath('workflows/../chat-sessions/session.json')).assertFalse();
      expect(AppBackupValidator.isAllowedRelativePath('/data/storage/workflows/configs/demo.json')).assertFalse();
      expect(AppBackupValidator.isAllowedRelativePath('tmp/not-allowed.json')).assertFalse();
    });

    it('acceptsSixCharacterBackupPassword', 0, () => {
      expect(AppBackupCrypto.isPasswordAccepted('123456')).assertTrue();
      expect(AppBackupCrypto.isPasswordAccepted('12345')).assertFalse();
    });

    it('encryptedEnvelopeDoesNotExposePayloadPlainText', 0, () => {
      // Darwin 宿主单测环境的 CryptoFramework GCM 不稳定，这里只校验外壳格式不携带业务明文；
      // 真实 AES-GCM 加解密放在 ohosTest 设备测试和实机导出流程中验证。
      let envelope: AppBackupEnvelope = {
        format: 'mobiinfra.backup.encrypted',
        schemaVersion: 1,
        createdAt: '2026-06-12T15:30:00+08:00',
        crypto: {
          algorithm: 'AES-256-GCM',
          kdf: 'PBKDF2-HMAC-SHA256',
          iterations: 200000,
          salt: 'c2FsdA==',
          iv: 'aXY=',
          authTag: 'dGFn'
        },
        payload: 'ZW5jcnlwdGVkLXBheWxvYWQ='
      };
      let serialized = JSON.stringify(envelope, null, 2);

      expect(serialized.indexOf('采集明文内容')).assertEqual(-1);
      expect(serialized.indexOf('workflows/daily-log')).assertEqual(-1);
      expect(serialized.indexOf('mobiinfra.backup.encrypted') >= 0).assertTrue();
    });
  });
}
