import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../AppLogger';

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
    let query = MailCredentialStore.query(accountKey);
    query.set(asset.Tag.SECRET, bytes);
    query.set(asset.Tag.DATA_LABEL_CRITICAL_4, new util.TextEncoder().encodeInto('clawmate.mail.imap.v1'));
    query.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    query.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    query.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    query.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(query); }
    catch (e) {
      let code = MailCredentialStore.errorCode(e as Error);
      AppLogger.warn('MailCredential', 'MAIL_CREDENTIAL_SAVE status=write_failed code=' + code);
      throw new Error('MAIL_CREDENTIAL_WRITE_FAILED: 邮箱授权码未能写入安全存储，请重试（系统错误码 ' + code + '）');
    }
    if (await MailCredentialStore.load(accountKey) !== secret) {
      AppLogger.warn('MailCredential', 'MAIL_CREDENTIAL_SAVE status=verify_failed');
      throw new Error('MAIL_CREDENTIAL_VERIFY_FAILED: 邮箱授权码保存后校验失败，本次未确认保存成功，请重试');
    }
    AppLogger.info('MailCredential', 'MAIL_CREDENTIAL_SAVE status=verified');
  }
  static async remove(accountKey: string = ''): Promise<void> {
    let query: asset.AssetMap = new Map();
    if (accountKey) { query = MailCredentialStore.query(accountKey); }
    else { query.set(asset.Tag.DATA_LABEL_CRITICAL_4, new util.TextEncoder().encodeInto('clawmate.mail.imap.v1')); }
    try { await asset.remove(query); }
    catch (e) { if ((e as BusinessError).code !== 24000002) { throw new Error('邮箱授权码未能移除，请重试'); } }
  }
}
