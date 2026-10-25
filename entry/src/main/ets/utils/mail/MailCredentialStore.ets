import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

// Account password/authorization code is never written to settings, snapshots or logs.
export class MailCredentialStore {
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
      return results.length === 0 ? '' : new util.TextDecoder().decodeToString(results[0].get(asset.Tag.SECRET) as Uint8Array);
    } catch (e) {
      if ((e as BusinessError).code === 24000002) { return ''; }
      throw new Error('无法读取邮箱授权码，请解锁设备后重试');
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
    await asset.add(query);
  }
  static async remove(accountKey: string = ''): Promise<void> {
    let query: asset.AssetMap = new Map();
    if (accountKey) { query = MailCredentialStore.query(accountKey); }
    else { query.set(asset.Tag.DATA_LABEL_CRITICAL_4, new util.TextEncoder().encodeInto('clawmate.mail.imap.v1')); }
    try { await asset.remove(query); }
    catch (e) { if ((e as BusinessError).code !== 24000002) { throw new Error('邮箱授权码未能移除，请重试'); } }
  }
}
