import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CodexConnection, CodexSavedConnection, codexConnectionLabel, normalizeCodexOrigin, validCodexToken, validCodexCa
} from './CodexTypes';

const CONNECTION_GROUP: string = 'clawmate.codex.connections.v2';

// V2 list queries use attributes only. The legacy credential is read for compatibility until migrated.
export class CodexCredentialStore {
  private static query(id: string = 'legacy'): asset.AssetMap {
    if (id !== 'legacy' && !/^[a-zA-Z0-9-]{32,36}$/.test(id)) { throw new Error('连接编号无效'); }
    let query: asset.AssetMap = new Map();
    const alias = id === 'legacy' ? 'clawmate.codex.connection.v1' : CONNECTION_GROUP + '.' + id;
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    return query;
  }

  private static metadata(attributes: asset.AssetMap): CodexSavedConnection | null {
    const bytes = attributes.get(asset.Tag.DATA_LABEL_CRITICAL_2) as Uint8Array | undefined;
    if (bytes === undefined) { return null; }
    const item = JSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as CodexSavedConnection;
    if (item === null || typeof item.id !== 'string' || !/^[a-zA-Z0-9-]{32,36}$/.test(item.id) ||
      typeof item.origin !== 'string' || normalizeCodexOrigin(item.origin) !== item.origin ||
      typeof item.name !== 'string' || item.name.length > 80 ||
      typeof item.updatedAt !== 'number' || !Number.isFinite(item.updatedAt)) {
      throw new Error('已保存的连接信息无效');
    }
    return item;
  }

  static async list(): Promise<CodexSavedConnection[]> {
    let query: asset.AssetMap = new Map();
    query.set(asset.Tag.DATA_LABEL_CRITICAL_4, new util.TextEncoder().encodeInto(CONNECTION_GROUP));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    let results: asset.AssetMap[] = [];
    try { results = await asset.query(query); }
    catch (e) {
      if ((e as BusinessError).code !== 24000002) { throw new Error('无法读取连接列表，请解锁设备后重试'); }
    }
    let items: CodexSavedConnection[] = [];
    for (let i = 0; i < results.length; i++) {
      const item = CodexCredentialStore.metadata(results[i]);
      if (item !== null) { items.push(item); }
    }
    const legacy = await CodexCredentialStore.read('legacy');
    if (legacy !== null && !items.some((item: CodexSavedConnection) => item.origin === legacy.origin)) {
      items.push({ id: 'legacy', name: codexConnectionLabel(legacy.origin), origin: legacy.origin, updatedAt: 0 });
    }
    return items.sort((a: CodexSavedConnection, b: CodexSavedConnection) => b.updatedAt - a.updatedAt);
  }

  static async load(id: string = ''): Promise<CodexConnection | null> {
    if (id.length === 0) {
      const items = await CodexCredentialStore.list();
      if (items.length === 0) { return null; }
      id = items[0].id;
    }
    return CodexCredentialStore.read(id);
  }

  private static async read(id: string): Promise<CodexConnection | null> {
    let query = CodexCredentialStore.query(id);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      if (results.length === 0) { return null; }
      const bytes = results[0].get(asset.Tag.SECRET) as Uint8Array;
      const saved = JSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as CodexConnection;
      const ca = results[0].get(asset.Tag.DATA_LABEL_CRITICAL_1) as Uint8Array | undefined;
      if (ca !== undefined) {
        const value = new util.TextDecoder().decodeWithStream(ca);
        if (value !== 'system') {
          if (!validCodexCa(value)) { throw new Error('配对证书无效'); }
          saved.caCertificate = value;
        }
      }
      if (normalizeCodexOrigin(saved.origin) !== saved.origin || !validCodexToken(saved.token)) {
        throw new Error('已保存的 Codex 连接信息无效，请删除后重新配对');
      }
      if (id !== 'legacy') {
        const info = CodexCredentialStore.metadata(results[0]);
        if (info === null || info.id !== id || info.origin !== saved.origin) { throw new Error('连接身份不匹配'); }
      }
      return saved;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 24000002) { return null; }
      throw new Error('无法读取安全连接信息，请解锁设备后重试');
    }
  }

  static async save(connection: CodexConnection, name: string = ''): Promise<CodexSavedConnection> {
    const origin = normalizeCodexOrigin(connection.origin);
    if (!validCodexToken(connection.token)) { throw new Error('桥接令牌格式无效'); }
    const items = await CodexCredentialStore.list();
    const existing = items.find((item: CodexSavedConnection) => item.origin === origin);
    const id = existing !== undefined && existing.id !== 'legacy' ? existing.id : util.generateRandomUUID(true);
    const info: CodexSavedConnection = {
      id: id, origin: origin, name: (name.trim() || existing?.name || codexConnectionLabel(origin)).slice(0, 80),
      updatedAt: Date.now()
    };
    let attributes = CodexCredentialStore.query(id);
    // SECRET is limited to 1024 bytes; the public certificate uses a separate protected label.
    const secret: CodexConnection = { origin: origin, token: connection.token };
    const secretBytes = new util.TextEncoder().encodeInto(JSON.stringify(secret));
    if (secretBytes.byteLength > 1024) { throw new Error('连接地址或令牌过长'); }
    attributes.set(asset.Tag.SECRET, secretBytes);
    const ca = connection.caCertificate || 'system';
    if (ca !== 'system' && !validCodexCa(ca)) { throw new Error('配对证书格式无效'); }
    attributes.set(asset.Tag.DATA_LABEL_CRITICAL_1, new util.TextEncoder().encodeInto(ca));
    attributes.set(asset.Tag.DATA_LABEL_CRITICAL_2, new util.TextEncoder().encodeInto(JSON.stringify(info)));
    attributes.set(asset.Tag.DATA_LABEL_CRITICAL_4, new util.TextEncoder().encodeInto(CONNECTION_GROUP));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
    const legacy = await CodexCredentialStore.read('legacy');
    if (legacy !== null && legacy.origin === origin) { await CodexCredentialStore.remove('legacy'); }
    return info;
  }

  private static async remove(id: string): Promise<void> {
    try { await asset.remove(CodexCredentialStore.query(id)); }
    catch (e) { if ((e as BusinessError).code !== 24000002) { throw e as Error; } }
  }

  static async forget(id: string = ''): Promise<void> {
    if (id.length === 0) {
      const items = await CodexCredentialStore.list();
      if (items.length === 0) { return; }
      id = items[0].id;
    }
    await CodexCredentialStore.remove(id);
  }
}
