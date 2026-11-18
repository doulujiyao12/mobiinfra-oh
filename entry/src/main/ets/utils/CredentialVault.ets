import fs from '@ohos.file.fs';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';

export interface CredentialEntry {
  id: string;
  value: string | null;
}

export interface CredentialState {
  version: number;
  legacyClosed: boolean;
  entries: CredentialEntry[];
}

interface CredentialEnvelope {
  version: number;
  iv: string;
  ciphertext: string;
}

// The random key and encrypted records live in the app-private sandbox, excluded
// from backup. They survive a data-preserving install without depending on appId.
// This deliberately relies on sandbox protection, not ASSET's signing identity.
export class CredentialVault {
  private static root: string = '';
  private static queue: Promise<void> = Promise.resolve();

  static initialize(filesDir: string): void {
    CredentialVault.root = filesDir + '/private-credentials';
  }

  static async transaction<T>(scope: string, action: (state: CredentialState) => Promise<T>): Promise<T> {
    if (scope !== 'mail' && scope !== 'codex') { throw new Error('凭据存储类型无效'); }
    const previous = CredentialVault.queue;
    let release: () => void = (): void => {};
    CredentialVault.queue = new Promise<void>((resolve: () => void): void => { release = resolve; });
    await previous;
    try {
      if (!CredentialVault.root) { throw new Error('凭据存储尚未初始化'); }
      const path = CredentialVault.root + '/' + scope + '.json';
      const state = CredentialVault.read(path, scope);
      const before = ArkJSON.stringify(state);
      const result = await action(state);
      const after = ArkJSON.stringify(state);
      if (after !== before) { CredentialVault.write(path, scope, after); }
      return result;
    } finally { release(); }
  }

  private static key(create: boolean): cryptoFramework.SymKey {
    const path = CredentialVault.root + '/key';
    const base64 = new util.Base64Helper();
    let bytes: Uint8Array;
    if (fs.accessSync(path)) {
      bytes = base64.decodeSync(fs.readTextSync(path));
    } else {
      // Never replace a missing key when encrypted records already exist.
      if (!create || fs.accessSync(CredentialVault.root + '/mail.json') ||
        fs.accessSync(CredentialVault.root + '/codex.json')) {
        throw new Error('本机凭据密钥无法读取，请重新保存配置');
      }
      bytes = cryptoFramework.createRandom().generateRandomSync(32).data;
      CredentialVault.atomicWrite(path, base64.encodeToStringSync(bytes));
    }
    if (bytes.length !== 32) { throw new Error('本机凭据密钥无效，请重新保存配置'); }
    return cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: bytes });
  }

  private static params(scope: string, iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: iv },
      aad: { data: new util.TextEncoder().encodeInto('clawmate.credentials.v1.' + scope) },
      authTag: { data: tag }
    };
    return params;
  }

  private static read(path: string, scope: string): CredentialState {
    if (!fs.accessSync(path)) { return { version: 1, legacyClosed: false, entries: [] }; }
    try {
      const envelope = ArkJSON.parse(fs.readTextSync(path)) as CredentialEnvelope;
      if (envelope.version !== 1 || typeof envelope.iv !== 'string' || typeof envelope.ciphertext !== 'string') {
        throw new Error('Invalid envelope');
      }
      const base64 = new util.Base64Helper();
      const iv = base64.decodeSync(envelope.iv);
      const bytes = base64.decodeSync(envelope.ciphertext);
      if (iv.length !== 12 || bytes.length < 16) { throw new Error('Invalid cipher'); }
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, CredentialVault.key(false),
        CredentialVault.params(scope, iv, bytes.slice(bytes.length - 16)));
      const plaintext = cipher.doFinalSync({ data: bytes.slice(0, bytes.length - 16) });
      const state = ArkJSON.parse(new util.TextDecoder().decodeToString(plaintext.data)) as CredentialState;
      if (state.version !== 1 || typeof state.legacyClosed !== 'boolean' || !Array.isArray(state.entries)) {
        throw new Error('Invalid state');
      }
      const ids: Set<string> = new Set<string>();
      for (const entry of state.entries) {
        if (!entry || typeof entry.id !== 'string' || ids.has(entry.id) ||
          (entry.value !== null && typeof entry.value !== 'string')) { throw new Error('Invalid entry'); }
        ids.add(entry.id);
      }
      return state;
    } catch (e) {
      // A corrupt/newer-format vault must never silently fall back to stale ASSET.
      throw new Error('本机凭据存储读取失败，请重试；已保存配置未被覆盖');
    }
  }

  private static write(path: string, scope: string, plaintext: string): void {
    try {
      if (!fs.accessSync(CredentialVault.root)) { fs.mkdirSync(CredentialVault.root); }
      const key = CredentialVault.key(true);
      const iv = cryptoFramework.createRandom().generateRandomSync(12).data;
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key,
        CredentialVault.params(scope, iv, new Uint8Array(16)));
      const encrypted = cipher.doFinalSync({ data: new util.TextEncoder().encodeInto(plaintext) });
      const base64 = new util.Base64Helper();
      const envelope: CredentialEnvelope = {
        version: 1, iv: base64.encodeToStringSync(iv), ciphertext: base64.encodeToStringSync(encrypted.data)
      };
      CredentialVault.atomicWrite(path, ArkJSON.stringify(envelope));
    } catch (e) { throw new Error('本机凭据未能保存，请重试'); }
  }

  private static atomicWrite(path: string, value: string): void {
    const temporary = path + '.tmp';
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const bytes = new util.TextEncoder().encodeInto(value);
      let offset = 0;
      while (offset < bytes.length) {
        const count = fs.writeSync(file.fd, bytes.slice(offset).buffer);
        if (count <= 0) { throw new Error('Incomplete credential write'); }
        offset += count;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    if (fs.readTextSync(temporary) !== value) { throw new Error('Credential write verification failed'); }
    // POSIX rename replaces the destination atomically. Never unlink it first.
    fs.renameSync(temporary, path);
  }
}
