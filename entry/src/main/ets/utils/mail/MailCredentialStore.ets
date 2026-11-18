import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../AppLogger';
import { CredentialEntry, CredentialState, CredentialVault } from '../CredentialVault';

export const MAIL_CREDENTIAL_MISSING_MESSAGE: string =
  'MAIL_CREDENTIAL_MISSING: 本机未找到此邮箱配置的授权码，请到“邮箱分析”重新保存';

// Account password/authorization code is never written to settings, snapshots or logs.
export class MailCredentialStore {
  private static errorCode(error: Error): number {
    let code = (error as BusinessError).code;
    return typeof code === 'number' && Number.isFinite(code) ? code : 0;
  }
  private static query(accountKey: string): asset.AssetMap {
    if (!/^[a-f0-9]{64}$/.test(accountKey)) { throw new Error('邮箱账号标识无效'); }
    let query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('clawmate.mail.imap.v1.' + accountKey));
    return query;
  }
  static async load(accountKey: string): Promise<string> {
    MailCredentialStore.query(accountKey);
    return CredentialVault.transaction<string>('mail', async (state: CredentialState): Promise<string> => {
      const entry = state.entries.find((item: CredentialEntry): boolean => item.id === accountKey);
      if (entry !== undefined) { return entry.value || ''; }
      if (state.legacyClosed) { return ''; }
      const secret = await MailCredentialStore.loadLegacy(accountKey);
      if (secret) { state.entries.push({ id: accountKey, value: secret }); }
      return secret;
    });
  }
  private static async loadLegacy(accountKey: string): Promise<string> {
    let query = MailCredentialStore.query(accountKey);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      let results = await asset.query(query);
      if (results.length === 0) {
        AppLogger.warn('MailCredential', 'MAIL_CREDENTIAL_LOOKUP status=missing reason=empty_result');
        return '';
      }
      let secret = new util.TextDecoder().decodeToString(results[0].get(asset.Tag.SECRET) as Uint8Array);
      AppLogger.info('MailCredential', 'MAIL_CREDENTIAL_LOOKUP status=' + (secret.length > 0 ? 'present' : 'missing'));
      return secret;
    } catch (e) {
      let code = MailCredentialStore.errorCode(e as Error);
      if (code === 24000002) {
        AppLogger.warn('MailCredential', 'MAIL_CREDENTIAL_LOOKUP status=missing code=24000002');
        return '';
      }
      AppLogger.warn('MailCredential', 'MAIL_CREDENTIAL_LOOKUP status=read_failed code=' + code);
      throw new Error('MAIL_CREDENTIAL_READ_FAILED: ' + (code === 24000005 ?
        '设备锁屏状态不允许读取邮箱授权码，请解锁后重试，无需先清空配置' :
        '暂时无法读取邮箱授权码，请解锁后重试') + '（系统错误码 ' + code + '）');
    }
  }
  static async save(accountKey: string, secret: string): Promise<void> {
    let bytes = new util.TextEncoder().encodeInto(secret);
    if (bytes.length === 0 || bytes.length > 1024 || /[\x00-\x1f\x7f]/.test(secret)) {
      throw new Error('邮箱授权码为空、过长或包含控制字符');
    }
    MailCredentialStore.query(accountKey);
    await CredentialVault.transaction<void>('mail', async (state: CredentialState): Promise<void> => {
      const entry = state.entries.find((item: CredentialEntry): boolean => item.id === accountKey);
      if (entry !== undefined) { entry.value = secret; }
      else { state.entries.push({ id: accountKey, value: secret }); }
    });
    AppLogger.info('MailCredential', 'MAIL_CREDENTIAL_SAVE status=verified');
  }
  static async remove(accountKey: string = ''): Promise<void> {
    if (accountKey) { MailCredentialStore.query(accountKey); }
    await CredentialVault.transaction<void>('mail', async (state: CredentialState): Promise<void> => {
      if (!accountKey) { state.entries = []; state.legacyClosed = true; return; }
      const entry = state.entries.find((item: CredentialEntry): boolean => item.id === accountKey);
      // A tombstone prevents an old ASSET value from resurrecting a removed account.
      if (entry !== undefined) { entry.value = null; }
      else { state.entries.push({ id: accountKey, value: null }); }
    });
  }
}
