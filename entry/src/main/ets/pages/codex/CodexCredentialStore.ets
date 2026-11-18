import { asset } from '@kit.AssetStoreKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { CredentialEntry, CredentialState, CredentialVault } from '../../utils/CredentialVault';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CodexConnection, CodexSavedConnection, codexConnectionLabel, normalizeCodexOrigin, validCodexToken, validCodexCa
} from './CodexTypes';

const CONNECTION_GROUP: string = 'clawmate.codex.connections.v2';

interface StoredCodexConnection {
  info: CodexSavedConnection;
  connection: CodexConnection;
}

// Import ASSET V1/V2 once, preserving connection IDs used by saved sessions.
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
    const item = ArkJSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as CodexSavedConnection;
    if (item === null || typeof item.id !== 'string' || !/^[a-zA-Z0-9-]{32,36}$/.test(item.id) ||
      typeof item.origin !== 'string' || normalizeCodexOrigin(item.origin) !== item.origin ||
      typeof item.name !== 'string' || item.name.length > 80 ||
      typeof item.updatedAt !== 'number' || !Number.isFinite(item.updatedAt)) {
      throw new Error('已保存的连接信息无效');
    }
    return item;
  }

  private static async legacyList(): Promise<CodexSavedConnection[]> {
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
    const legacy = await CodexCredentialStore.readLegacy('legacy');
    if (legacy !== null && !items.some((item: CodexSavedConnection) => item.origin === legacy.origin)) {
      items.push({ id: 'legacy', name: codexConnectionLabel(legacy.origin), origin: legacy.origin, updatedAt: 0 });
    }
    return items.sort((a: CodexSavedConnection, b: CodexSavedConnection) => b.updatedAt - a.updatedAt);
  }

  private static async records(state: CredentialState): Promise<StoredCodexConnection[]> {
    if (!state.legacyClosed) {
      const legacyItems = await CodexCredentialStore.legacyList();
      for (const info of legacyItems) {
        if (state.entries.some((entry: CredentialEntry): boolean => entry.id === info.id)) { continue; }
        const connection = await CodexCredentialStore.readLegacy(info.id);
        if (connection === null) { throw new Error('连接配置在迁移期间发生变化，请重试'); }
        const record: StoredCodexConnection = { info: info, connection: connection };
        state.entries.push({ id: info.id, value: ArkJSON.stringify(record) });
      }
      state.legacyClosed = true;
    }
    const records: StoredCodexConnection[] = [];
    for (const entry of state.entries) {
      if (entry.value === null) { continue; }
      const record = ArkJSON.parse(entry.value) as StoredCodexConnection;
      if (!record || !record.info || !record.connection || record.info.id !== entry.id ||
        typeof record.info.name !== 'string' || record.info.name.length > 80 ||
        typeof record.info.updatedAt !== 'number' || !Number.isFinite(record.info.updatedAt) ||
        record.info.origin !== record.connection.origin ||
        normalizeCodexOrigin(record.connection.origin) !== record.connection.origin ||
        !validCodexToken(record.connection.token) ||
        (record.connection.caCertificate && !validCodexCa(record.connection.caCertificate))) {
        throw new Error('本机连接配置无法读取，请重试');
      }
      records.push(record);
    }
    return records.sort((a: StoredCodexConnection, b: StoredCodexConnection): number =>
      b.info.updatedAt - a.info.updatedAt);
  }

  static async list(): Promise<CodexSavedConnection[]> {
    return CredentialVault.transaction<CodexSavedConnection[]>('codex',
      async (state: CredentialState): Promise<CodexSavedConnection[]> => {
        const records = await CodexCredentialStore.records(state);
        return records.map((record: StoredCodexConnection): CodexSavedConnection => record.info);
      });
  }

  static async load(id: string = ''): Promise<CodexConnection | null> {
    if (id) { CodexCredentialStore.query(id); }
    return CredentialVault.transaction<CodexConnection | null>('codex',
      async (state: CredentialState): Promise<CodexConnection | null> => {
        const records = await CodexCredentialStore.records(state);
        const record = id ? records.find((item: StoredCodexConnection): boolean => item.info.id === id) : records[0];
        return record === undefined ? null : record.connection;
      });
  }

  private static async readLegacy(id: string): Promise<CodexConnection | null> {
    let query = CodexCredentialStore.query(id);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      if (results.length === 0) { return null; }
      const bytes = results[0].get(asset.Tag.SECRET) as Uint8Array;
      const saved = ArkJSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as CodexConnection;
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
    const ca = connection.caCertificate || 'system';
    if (ca !== 'system' && !validCodexCa(ca)) {
      throw new Error('配对证书格式无效');
    }
    const saved: CodexConnection = { origin: origin, token: connection.token };
    if (ca !== 'system') { saved.caCertificate = ca; }
    return CredentialVault.transaction<CodexSavedConnection>('codex',
      async (state: CredentialState): Promise<CodexSavedConnection> => {
        const records = await CodexCredentialStore.records(state);
        const existing = records.find((item: StoredCodexConnection): boolean => item.info.origin === origin);
        const info: CodexSavedConnection = {
          id: existing === undefined ? util.generateRandomUUID(true) : existing.info.id,
          origin: origin, name: (name.trim() || existing?.info.name || codexConnectionLabel(origin)).slice(0, 80),
          updatedAt: Date.now()
        };
        const record: StoredCodexConnection = { info: info, connection: saved };
        const value = ArkJSON.stringify(record);
        const entry = state.entries.find((item: CredentialEntry): boolean => item.id === info.id);
        if (entry === undefined) { state.entries.push({ id: info.id, value: value }); }
        else { entry.value = value; }
        return info;
      });
  }

  static async forget(id: string = ''): Promise<void> {
    if (id) { CodexCredentialStore.query(id); }
    await CredentialVault.transaction<void>('codex', async (state: CredentialState): Promise<void> => {
      const records = await CodexCredentialStore.records(state);
      const target = id || records[0]?.info.id || '';
      state.entries = state.entries.filter((entry: CredentialEntry): boolean => entry.id !== target);
    });
  }
}
