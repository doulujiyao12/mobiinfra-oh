import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { CodexConnection, normalizeCodexOrigin, validCodexToken } from './CodexTypes';

// Store the origin and token together to prevent sending a saved token to an edited host.
export class CodexCredentialStore {
  private static query(): asset.AssetMap {
    let query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('clawmate.codex.connection.v1'));
    return query;
  }

  static async load(): Promise<CodexConnection | null> {
    let query = CodexCredentialStore.query();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      if (results.length === 0) { return null; }
      const bytes = results[0].get(asset.Tag.SECRET) as Uint8Array;
      const saved = JSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as CodexConnection;
      if (normalizeCodexOrigin(saved.origin) !== saved.origin || !validCodexToken(saved.token)) {
        throw new Error('已保存的 Codex 连接信息无效，请忘记连接后重新配置');
      }
      return saved;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 24000002) { return null; }
      throw new Error('无法读取安全连接信息，请解锁设备后重试');
    }
  }

  static async save(connection: CodexConnection): Promise<void> {
    let attributes = CodexCredentialStore.query();
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify(connection)));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  static async forget(): Promise<void> {
    try { await asset.remove(CodexCredentialStore.query()); }
    catch (e) { if ((e as BusinessError).code !== 24000002) { throw e; } }
  }
}
