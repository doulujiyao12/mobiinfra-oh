import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { DataManagerFacade } from '../datamanager/DataManagerFacade';
import { AppLogger } from './AppLogger';
import { ChatSessionStorage } from './ChatSessionStorage';
import { GalleryStorage } from './gallery/GalleryStorage';
import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';
import { decodeUtf8Compat, encodeUtf8Compat } from './TextEncodingCompat';
import { WorkflowStorage } from './WorkflowStorage';
import {
  APP_BACKUP_AUTH_TAG_SIZE,
  APP_BACKUP_CIPHER,
  APP_BACKUP_CIPHER_TRANSFORMATION,
  APP_BACKUP_FORMAT,
  APP_BACKUP_IV_SIZE,
  APP_BACKUP_KDF,
  APP_BACKUP_KDF_ALG_NAME,
  APP_BACKUP_KDF_ITERATIONS,
  APP_BACKUP_KDF_SPEC_ALG_NAME,
  APP_BACKUP_KEY_ALG_NAME,
  APP_BACKUP_KEY_SIZE,
  APP_BACKUP_MIN_PASSWORD_LENGTH,
  APP_BACKUP_SALT_SIZE,
  APP_BACKUP_SCHEMA_VERSION,
  AppBackupEnvelope,
  AppBackupExportOptions,
  AppBackupExportResult,
  AppBackupFileEncoding,
  AppBackupFileEntry,
  AppBackupImportOptions,
  AppBackupImportResult,
  AppBackupPayload,
  AppBackupSettingMap,
  AppBackupSettingValue
} from './AppBackupTypes';

export {
  AppBackupEnvelope,
  AppBackupExportOptions,
  AppBackupExportResult,
  AppBackupFileEntry,
  AppBackupImportOptions,
  AppBackupImportResult,
  AppBackupPayload,
  AppBackupSettingMap
} from './AppBackupTypes';

const BACKUP_ROOTS: string[] = ['workflows', 'gallery-log', 'chat-sessions'];
const BACKUP_AAD: string = 'mobiinfra.backup.v1';
const TEXT_FILE_SUFFIXES: string[] = ['.json', '.md', '.txt', '.log', '.csv', '.yaml', '.yml'];

const SETTING_KEYS: string[] = [
  'wirelessIp',
  'serverIp',
  'hdcServerIp',
  'manualHdcServerIp',
  'cloudPlannerBaseUrl',
  'cloudDeciderBaseUrl',
  'cloudApiKey',
  'cloudDeciderModel',
  'avatarImageBaseUrl',
  'avatarImageApiKey',
  'avatarTextToImageModel',
  'avatarImageToImageModel',
  'avatarImageSize',
  'avatarImageResponseFormat',
  'avatarImageOutputFormat',
  'avatarSequentialImageGeneration',
  'avatarImageStream',
  'avatarImageWatermark',
  'avatarImageTimeoutMs',
  'galleryApiBaseUrl',
  'galleryApiKey',
  'galleryModel',
  'gallerySkipOcr',
  'galleryUseOcrKeywordFilter',
  'galleryOcrConcurrency',
  'galleryModelConcurrency',
  'galleryEmbeddingConcurrency',
  'galleryEmbeddingMode',
  'galleryEmbeddingBaseUrl',
  'galleryEmbeddingApiKey',
  'galleryEmbeddingModel',
  'galleryImageScale',
  'galleryAmapWebKey',
  'endpointDefault.serverIp',
  'endpointDefault.hdcServerIp',
  'endpointDefault.wirelessIp',
  'endpointDefault.cloudPlannerBaseUrl',
  'endpointDefault.cloudDeciderBaseUrl',
  'endpointDefault.cloudApiKey',
  'endpointDefault.cloudDeciderModel'
];

const SENSITIVE_SETTING_KEYS: string[] = [
  'wirelessIp',
  'serverIp',
  'hdcServerIp',
  'manualHdcServerIp',
  'cloudPlannerBaseUrl',
  'cloudDeciderBaseUrl',
  'cloudApiKey',
  'avatarImageBaseUrl',
  'avatarImageApiKey',
  'galleryApiBaseUrl',
  'galleryApiKey',
  'galleryEmbeddingBaseUrl',
  'galleryEmbeddingApiKey',
  'galleryAmapWebKey',
  'endpointDefault.serverIp',
  'endpointDefault.hdcServerIp',
  'endpointDefault.wirelessIp',
  'endpointDefault.cloudPlannerBaseUrl',
  'endpointDefault.cloudDeciderBaseUrl',
  'endpointDefault.cloudApiKey'
];

// 本地备份只允许写回这些业务目录，避免导入包通过路径穿越覆盖沙箱内其它文件。
export class AppBackupValidator {
  static isAllowedRelativePath(path: string): boolean {
    let normalized = AppBackupValidator.normalizeRelativePath(path);
    if (normalized.length === 0 || normalized.startsWith('/')) {
      return false;
    }
    let parts = normalized.split('/');
    if (parts.length < 2) {
      return false;
    }
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length === 0 || parts[i] === '.' || parts[i] === '..') {
        return false;
      }
    }
    return BACKUP_ROOTS.indexOf(parts[0]) >= 0;
  }

  static normalizeRelativePath(path: string): string {
    return path.replace(/\\/g, '/').replace(/^\/+/g, '').replace(/\/+$/g, '');
  }

  static assertPayload(payload: AppBackupPayload): void {
    if (payload.schemaVersion !== APP_BACKUP_SCHEMA_VERSION) {
      throw new Error('备份版本不支持：' + String(payload.schemaVersion));
    }
    for (let i = 0; i < payload.files.length; i++) {
      if (!AppBackupValidator.isAllowedRelativePath(payload.files[i].path)) {
        throw new Error('备份文件路径不安全：' + payload.files[i].path);
      }
    }
  }
}

// 设置备份采用白名单采集；敏感项默认剔除，只有用户显式勾选后才进入加密 payload。
export class AppBackupSettings {
  static filterSettings(source: AppBackupSettingMap, includeSensitiveSettings: boolean): AppBackupSettingMap {
    let filtered: AppBackupSettingMap = {};
    let keys = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      let key = keys[i];
      if (!includeSensitiveSettings && AppBackupSettings.isSensitiveKey(key)) {
        continue;
      }
      filtered[key] = source[key];
    }
    return filtered;
  }

  static collect(includeSensitiveSettings: boolean): AppBackupSettingMap {
    let collected: AppBackupSettingMap = {};
    for (let i = 0; i < SETTING_KEYS.length; i++) {
      let key = SETTING_KEYS[i];
      let value = AppStorage.get(key) as AppBackupSettingValue;
      if (value !== undefined) {
        collected[key] = value;
      }
    }
    return AppBackupSettings.filterSettings(collected, includeSensitiveSettings);
  }

  static restore(settings: AppBackupSettingMap): number {
    let count = 0;
    let keys = Object.keys(settings);
    for (let i = 0; i < keys.length; i++) {
      let key = keys[i];
      AppStorage.setOrCreate(key, settings[key]);
      count++;
    }
    return count;
  }

  static isSensitiveKey(key: string): boolean {
    return SENSITIVE_SETTING_KEYS.indexOf(key) >= 0;
  }
}

// 加密层负责“明文外壳 + AES-GCM 密文 payload”，外壳只暴露算法、版本、salt、iv 和认证标签。
export class AppBackupCrypto {
  static async encryptPayload(payload: AppBackupPayload, password: string): Promise<AppBackupEnvelope> {
    AppBackupCrypto.assertPassword(password);
    AppLogger.info('Backup.Crypto', 'encrypt start');
    let salt = AppBackupCrypto.randomBytes(APP_BACKUP_SALT_SIZE);
    let iv = AppBackupCrypto.randomBytes(APP_BACKUP_IV_SIZE);
    AppLogger.info('Backup.Crypto', 'salt and iv generated');
    let key = await AppBackupCrypto.deriveKey(password, salt);
    AppLogger.info('Backup.Crypto', 'key derived');
    let plainText = stringifyJsonCompat(payload as Object);
    AppLogger.info('Backup.Crypto', 'plain payload serialized length=' + String(plainText.length));
    let plainBytes = encodeUtf8Compat(plainText);
    AppLogger.info('Backup.Crypto', 'plain payload encoded bytes=' + String(plainBytes.length));
    plainText = '';
    let encrypted = await AppBackupCrypto.encryptBytes(key, iv, plainBytes);
    let cipherBytes = encrypted.cipherText;
    let authTag = encrypted.authTag;
    AppLogger.info('Backup.Crypto', 'gcm encrypt output cipherBytes=' + String(cipherBytes.length) +
      ', authTagBytes=' + String(authTag.length));
    let envelope: AppBackupEnvelope = {
      format: APP_BACKUP_FORMAT,
      schemaVersion: APP_BACKUP_SCHEMA_VERSION,
      createdAt: payload.createdAt,
      crypto: {
        algorithm: APP_BACKUP_CIPHER,
        kdf: APP_BACKUP_KDF,
        iterations: APP_BACKUP_KDF_ITERATIONS,
        salt: AppBackupCrypto.base64Encode(salt),
        iv: AppBackupCrypto.base64Encode(iv),
        authTag: AppBackupCrypto.base64Encode(authTag)
      },
      payload: AppBackupCrypto.base64Encode(cipherBytes)
    };
    return envelope;
  }

  static async decryptPayload(envelope: AppBackupEnvelope, password: string): Promise<AppBackupPayload> {
    AppBackupCrypto.assertEnvelope(envelope);
    AppBackupCrypto.assertPassword(password);
    AppLogger.info('Backup.Crypto', 'decrypt start');
    let salt = AppBackupCrypto.base64Decode(envelope.crypto.salt);
    let iv = AppBackupCrypto.base64Decode(envelope.crypto.iv);
    let authTag = AppBackupCrypto.base64Decode(envelope.crypto.authTag);
    AppBackupCrypto.assertAuthTag(authTag);
    let cipherBytes = AppBackupCrypto.base64Decode(envelope.payload);
    let key = await AppBackupCrypto.deriveKey(password, salt);
    AppLogger.info('Backup.Crypto', 'key derived for decrypt');
    let plainBytes = await AppBackupCrypto.decryptBytes(key, iv, authTag, cipherBytes);
    let payload = parseJsonCompat<AppBackupPayload>(decodeUtf8Compat(plainBytes));
    AppBackupValidator.assertPayload(payload);
    return payload;
  }

  static serializeEnvelope(envelope: AppBackupEnvelope): string {
    return stringifyJsonCompat(envelope as Object, 2);
  }

  static parseEnvelope(text: string): AppBackupEnvelope {
    let envelope = parseJsonCompat<AppBackupEnvelope>(text);
    AppBackupCrypto.assertEnvelope(envelope);
    return envelope;
  }

  static base64Encode(bytes: Uint8Array): string {
    let helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }

  static base64Decode(text: string): Uint8Array {
    let helper = new util.Base64Helper();
    return helper.decodeSync(text);
  }

  static createEphemeralPassword(): string {
    return 'rollback-' + AppBackupCrypto.base64Encode(AppBackupCrypto.randomBytes(32));
  }

  static isPasswordAccepted(password: string): boolean {
    return password.length >= APP_BACKUP_MIN_PASSWORD_LENGTH;
  }

  private static assertPassword(password: string): void {
    if (!AppBackupCrypto.isPasswordAccepted(password)) {
      throw new Error('备份密码至少需要 ' + String(APP_BACKUP_MIN_PASSWORD_LENGTH) + ' 位');
    }
  }

  private static assertEnvelope(envelope: AppBackupEnvelope): void {
    if (envelope.format !== APP_BACKUP_FORMAT) {
      throw new Error('不是 MobiInfer 加密备份文件');
    }
    if (envelope.schemaVersion !== APP_BACKUP_SCHEMA_VERSION) {
      throw new Error('备份版本不支持：' + String(envelope.schemaVersion));
    }
    if (envelope.crypto.algorithm !== APP_BACKUP_CIPHER || envelope.crypto.kdf !== APP_BACKUP_KDF) {
      throw new Error('备份加密算法不支持');
    }
  }

  private static async deriveKey(password: string, salt: Uint8Array): Promise<cryptoFramework.SymKey> {
    AppLogger.info('Backup.Crypto', 'derive key start kdf=' + APP_BACKUP_KDF_ALG_NAME +
      ', iterations=' + String(APP_BACKUP_KDF_ITERATIONS));
    let kdf = cryptoFramework.createKdf(APP_BACKUP_KDF_ALG_NAME);
    let spec: cryptoFramework.PBKDF2Spec = {
      algName: APP_BACKUP_KDF_SPEC_ALG_NAME,
      password: encodeUtf8Compat(password),
      salt: salt,
      iterations: APP_BACKUP_KDF_ITERATIONS,
      keySize: APP_BACKUP_KEY_SIZE
    };
    let keyBlob = await kdf.generateSecret(spec);
    AppLogger.info('Backup.Crypto', 'kdf generateSecret ok keyBytes=' + String(keyBlob.data.length));
    let generator = cryptoFramework.createSymKeyGenerator(APP_BACKUP_KEY_ALG_NAME);
    AppLogger.info('Backup.Crypto', 'sym key generator created alg=' + APP_BACKUP_KEY_ALG_NAME);
    return await generator.convertKey(keyBlob);
  }

  private static randomBytes(length: number): Uint8Array {
    let random = cryptoFramework.createRandom();
    return random.generateRandomSync(length).data;
  }

  private static gcmParams(iv: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    let params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: encodeUtf8Compat(BACKUP_AAD) },
      authTag: { data: authTag }
    };
    return params;
  }

  private static async encryptBytes(key: cryptoFramework.SymKey, iv: Uint8Array,
    plainBytes: Uint8Array): Promise<AppBackupCipherSplit> {
    let params = AppBackupCrypto.gcmParams(iv, new Uint8Array(APP_BACKUP_AUTH_TAG_SIZE));
    let cipher = cryptoFramework.createCipher(APP_BACKUP_CIPHER_TRANSFORMATION);
    AppLogger.info('Backup.Crypto', 'cipher created transformation=' + APP_BACKUP_CIPHER_TRANSFORMATION);
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    AppLogger.info('Backup.Crypto', 'cipher init encrypt ok');
    let encrypted = await cipher.doFinal({ data: plainBytes });
    AppLogger.info('Backup.Crypto', 'cipher doFinal encrypt bytes=' + String(encrypted.data.length));
    if (encrypted.data.length > APP_BACKUP_AUTH_TAG_SIZE) {
      return AppBackupCrypto.splitCipherAndTag(encrypted.data);
    }
    if (encrypted.data.length === APP_BACKUP_AUTH_TAG_SIZE) {
      AppLogger.info('Backup.Crypto', 'doFinal returned authTag only, fallback to update ciphertext');
      let cipherText = await AppBackupCrypto.encryptCipherTextWithUpdate(key, iv, plainBytes);
      return { cipherText: cipherText, authTag: encrypted.data };
    }
    throw new Error('GCM 加密输出长度异常：' + String(encrypted.data.length));
  }

  private static async encryptCipherTextWithUpdate(key: cryptoFramework.SymKey, iv: Uint8Array,
    plainBytes: Uint8Array): Promise<Uint8Array> {
    let params = AppBackupCrypto.gcmParams(iv, new Uint8Array(APP_BACKUP_AUTH_TAG_SIZE));
    let cipher = cryptoFramework.createCipher(APP_BACKUP_CIPHER_TRANSFORMATION);
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    let encrypted = await cipher.update({ data: plainBytes });
    let finalBlob = await cipher.doFinal(null);
    AppLogger.info('Backup.Crypto', 'fallback update encrypt cipherBytes=' + String(encrypted.data.length) +
      ', finalBytes=' + String(finalBlob.data.length));
    if (finalBlob.data.length > APP_BACKUP_AUTH_TAG_SIZE) {
      let finalSplit = AppBackupCrypto.splitCipherAndTag(finalBlob.data);
      return AppBackupCrypto.concatBytes(encrypted.data, finalSplit.cipherText);
    }
    if (finalBlob.data.length > 0 && finalBlob.data.length < APP_BACKUP_AUTH_TAG_SIZE) {
      return AppBackupCrypto.concatBytes(encrypted.data, finalBlob.data);
    }
    if (encrypted.data.length === 0) {
      throw new Error('GCM 加密未生成密文');
    }
    return encrypted.data;
  }

  private static async decryptBytes(key: cryptoFramework.SymKey, iv: Uint8Array, authTag: Uint8Array,
    cipherBytes: Uint8Array): Promise<Uint8Array> {
    let params = AppBackupCrypto.gcmParams(iv, authTag);
    let cipher = cryptoFramework.createCipher(APP_BACKUP_CIPHER_TRANSFORMATION);
    AppLogger.info('Backup.Crypto', 'cipher created for decrypt transformation=' + APP_BACKUP_CIPHER_TRANSFORMATION);
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    AppLogger.info('Backup.Crypto', 'cipher init decrypt ok');
    let plain = await cipher.doFinal({ data: cipherBytes });
    AppLogger.info('Backup.Crypto', 'cipher doFinal decrypt bytes=' + String(plain.data.length));
    if (plain.data.length > 0) {
      return plain.data;
    }
    AppLogger.info('Backup.Crypto', 'doFinal decrypt returned empty, fallback to update decrypt');
    return await AppBackupCrypto.decryptBytesWithUpdate(key, iv, authTag, cipherBytes);
  }

  private static async decryptBytesWithUpdate(key: cryptoFramework.SymKey, iv: Uint8Array, authTag: Uint8Array,
    cipherBytes: Uint8Array): Promise<Uint8Array> {
    let params = AppBackupCrypto.gcmParams(iv, authTag);
    let cipher = cryptoFramework.createCipher(APP_BACKUP_CIPHER_TRANSFORMATION);
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    let plainUpdate = await cipher.update({ data: cipherBytes });
    let plainFinal = await cipher.doFinal(null);
    AppLogger.info('Backup.Crypto', 'fallback update decrypt plainBytes=' + String(plainUpdate.data.length) +
      ', finalBytes=' + String(plainFinal.data.length));
    return AppBackupCrypto.concatBytes(plainUpdate.data, plainFinal.data);
  }

  private static assertAuthTag(authTag: Uint8Array): void {
    if (authTag.length !== APP_BACKUP_AUTH_TAG_SIZE) {
      throw new Error('GCM 认证标签长度异常：' + String(authTag.length));
    }
  }

  private static splitCipherAndTag(bytes: Uint8Array): AppBackupCipherSplit {
    if (bytes.length <= APP_BACKUP_AUTH_TAG_SIZE) {
      throw new Error('GCM 加密输出长度异常：' + String(bytes.length));
    }
    let cipherLength = bytes.length - APP_BACKUP_AUTH_TAG_SIZE;
    let cipherText = new Uint8Array(cipherLength);
    let authTag = new Uint8Array(APP_BACKUP_AUTH_TAG_SIZE);
    for (let i = 0; i < cipherLength; i++) {
      cipherText[i] = bytes[i];
    }
    for (let i = 0; i < APP_BACKUP_AUTH_TAG_SIZE; i++) {
      authTag[i] = bytes[cipherLength + i];
    }
    return { cipherText: cipherText, authTag: authTag };
  }

  private static concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
    if (second.length === 0) {
      return first;
    }
    if (first.length === 0) {
      return second;
    }
    let result = new Uint8Array(first.length + second.length);
    for (let i = 0; i < first.length; i++) {
      result[i] = first[i];
    }
    for (let i = 0; i < second.length; i++) {
      result[first.length + i] = second[i];
    }
    return result;
  }
}

interface AppBackupCipherSplit {
  cipherText: Uint8Array;
  authTag: Uint8Array;
}

interface AppBackupRollbackSnapshot {
  path: string;
  password: string;
}

export class AppBackupManager {
  static async exportBackup(filesDir: string, options: AppBackupExportOptions): Promise<AppBackupExportResult> {
    AppLogger.info('Backup.Manager', 'export start includeSensitive=' + String(options.includeSensitiveSettings));
    let payload = AppBackupManager.buildPayload(filesDir, options.includeSensitiveSettings);
    AppLogger.info('Backup.Manager', 'payload built fileCount=' + String(payload.files.length) +
      ', settingCount=' + String(Object.keys(payload.settings).length));
    let envelope = await AppBackupCrypto.encryptPayload(payload, options.password);
    AppLogger.info('Backup.Manager', 'payload encrypted');
    await AppBackupManager.writeExternalText(options.targetUri, AppBackupCrypto.serializeEnvelope(envelope));
    AppLogger.info('Backup.Manager', 'envelope written');
    return {
      fileCount: payload.files.length,
      totalBytes: AppBackupManager.totalBytes(payload.files),
      targetUri: options.targetUri,
      createdAt: payload.createdAt
    };
  }

  static async importBackup(filesDir: string, options: AppBackupImportOptions): Promise<AppBackupImportResult> {
    AppLogger.info('Backup.Manager', 'import start overwrite=' + String(options.overwrite));
    if (!options.overwrite) {
      throw new Error('当前版本仅支持覆盖式恢复');
    }
    let text = await AppBackupManager.readExternalText(options.sourceUri);
    AppLogger.info('Backup.Manager', 'external envelope read length=' + String(text.length));
    let envelope = AppBackupCrypto.parseEnvelope(text);
    let payload = await AppBackupCrypto.decryptPayload(envelope, options.password);
    AppBackupValidator.assertPayload(payload);
    AppLogger.info('Backup.Manager', 'payload decrypted fileCount=' + String(payload.files.length) +
      ', settingCount=' + String(Object.keys(payload.settings).length));
    // 覆盖恢复前先生成沙箱内临时加密快照，恢复失败时解密回滚，避免落盘明文临时包。
    let rollbackSnapshot = await AppBackupManager.createRollbackSnapshot(filesDir);
    try {
      AppBackupManager.restorePayload(filesDir, payload);
      AppLogger.info('Backup.Manager', 'payload restored');
    } catch (e) {
      let err = e as Error;
      AppLogger.errorCause('Backup.Manager', 'restore failed, rollback start', err);
      try {
        let rollbackPayload = await AppBackupManager.readRollbackSnapshot(rollbackSnapshot);
        AppBackupManager.restorePayload(filesDir, rollbackPayload);
      } catch (rollbackError) {
        let rollbackErr = rollbackError as Error;
        throw new Error('恢复失败，回滚也失败：' + err.message + '；回滚错误：' + rollbackErr.message);
      }
      throw new Error('恢复失败，已尝试回滚：' + err.message);
    } finally {
      AppBackupManager.deleteRollbackSnapshot(rollbackSnapshot);
    }
    return {
      fileCount: payload.files.length,
      restoredSettings: Object.keys(payload.settings).length
    };
  }

  static buildPayload(filesDir: string, includeSensitiveSettings: boolean): AppBackupPayload {
    AppLogger.info('Backup.Manager', 'build payload start');
    let payload: AppBackupPayload = {
      schemaVersion: APP_BACKUP_SCHEMA_VERSION,
      createdAt: AppBackupManager.nowIsoLocal(),
      includeSensitiveSettings: includeSensitiveSettings,
      settings: AppBackupSettings.collect(includeSensitiveSettings),
      files: AppBackupManager.collectFiles(filesDir)
    };
    AppLogger.info('Backup.Manager', 'build payload finished fileCount=' + String(payload.files.length));
    return payload;
  }

  private static async createRollbackSnapshot(filesDir: string): Promise<AppBackupRollbackSnapshot> {
    AppLogger.info('Backup.Manager', 'create rollback snapshot start');
    let payload = AppBackupManager.buildPayload(filesDir, true);
    let password = AppBackupCrypto.createEphemeralPassword();
    let envelope = await AppBackupCrypto.encryptPayload(payload, password);
    let dir = AppBackupManager.normalizeFilesDir(filesDir) + '/.app-backup-rollback';
    AppBackupManager.ensureDirectory(dir);
    let path = dir + '/rollback-' + String(new Date().getTime()) + '.mibak';
    AppBackupManager.writeText(path, AppBackupCrypto.serializeEnvelope(envelope));
    AppLogger.info('Backup.Manager', 'rollback snapshot created');
    return {
      path: path,
      password: password
    };
  }

  private static async readRollbackSnapshot(snapshot: AppBackupRollbackSnapshot): Promise<AppBackupPayload> {
    let text = AppBackupManager.readText(snapshot.path);
    let envelope = AppBackupCrypto.parseEnvelope(text);
    return await AppBackupCrypto.decryptPayload(envelope, snapshot.password);
  }

  private static deleteRollbackSnapshot(snapshot: AppBackupRollbackSnapshot): void {
    AppBackupManager.deletePathRecursively(snapshot.path);
    try {
      fs.rmdirSync(AppBackupManager.parentPath(snapshot.path));
    } catch (e) {
    }
    AppLogger.info('Backup.Manager', 'rollback snapshot cleaned');
  }

  static restorePayload(filesDir: string, payload: AppBackupPayload): void {
    AppLogger.info('Backup.Manager', 'restore payload start fileCount=' + String(payload.files.length));
    AppBackupValidator.assertPayload(payload);
    AppBackupManager.clearBackupRoots(filesDir);
    for (let i = 0; i < payload.files.length; i++) {
      AppBackupManager.restoreFile(filesDir, payload.files[i]);
    }
    AppBackupSettings.restore(payload.settings);
    AppBackupManager.ensureKnownWorkspaces(filesDir);
    AppLogger.info('Backup.Manager', 'restore payload finished');
  }

  private static collectFiles(filesDir: string): AppBackupFileEntry[] {
    AppLogger.info('Backup.Manager', 'collect files start');
    let files: AppBackupFileEntry[] = [];
    let root = AppBackupManager.normalizeFilesDir(filesDir);
    for (let i = 0; i < BACKUP_ROOTS.length; i++) {
      AppBackupManager.collectPath(root + '/' + BACKUP_ROOTS[i], BACKUP_ROOTS[i], files);
    }
    files.sort((left: AppBackupFileEntry, right: AppBackupFileEntry) => {
      if (left.path === right.path) {
        return 0;
      }
      return left.path > right.path ? 1 : -1;
    });
    AppLogger.info('Backup.Manager', 'collect files finished count=' + String(files.length));
    return files;
  }

  private static collectPath(path: string, relativePath: string, out: AppBackupFileEntry[]): void {
    try {
      let stat = fs.statSync(path);
      if (stat.isDirectory()) {
        let children = fs.listFileSync(path);
        for (let i = 0; i < children.length; i++) {
          AppBackupManager.collectPath(path + '/' + children[i], relativePath + '/' + children[i], out);
        }
        return;
      }
      if (!AppBackupValidator.isAllowedRelativePath(relativePath)) {
        return;
      }
      let encoding = AppBackupManager.fileEncoding(relativePath);
      let entry: AppBackupFileEntry = {
        path: AppBackupValidator.normalizeRelativePath(relativePath),
        encoding: encoding,
        content: encoding === 'utf8' ? AppBackupManager.readText(path) :
        AppBackupCrypto.base64Encode(new Uint8Array(AppBackupManager.readBytes(path))),
        size: stat.size,
        modifiedTime: stat.mtime
      };
      out.push(entry);
    } catch (e) {
    }
  }

  private static restoreFile(filesDir: string, entry: AppBackupFileEntry): void {
    let normalized = AppBackupValidator.normalizeRelativePath(entry.path);
    if (!AppBackupValidator.isAllowedRelativePath(normalized)) {
      throw new Error('备份文件路径不安全：' + entry.path);
    }
    let path = AppBackupManager.normalizeFilesDir(filesDir) + '/' + normalized;
    AppBackupManager.ensureParentDirectory(path);
    if (entry.encoding === 'utf8') {
      AppBackupManager.writeText(path, entry.content);
      return;
    }
    AppBackupManager.writeBytes(path, AppBackupCrypto.base64Decode(entry.content).buffer as ArrayBuffer);
  }

  private static clearBackupRoots(filesDir: string): void {
    let root = AppBackupManager.normalizeFilesDir(filesDir);
    for (let i = 0; i < BACKUP_ROOTS.length; i++) {
      AppBackupManager.deletePathRecursively(root + '/' + BACKUP_ROOTS[i]);
    }
  }

  private static ensureKnownWorkspaces(filesDir: string): void {
    WorkflowStorage.ensureWorkspace(filesDir);
    GalleryStorage.ensureWorkspace(filesDir);
    ChatSessionStorage.ensureWorkspace(filesDir);
    let facade = new DataManagerFacade(filesDir);
    facade.ensureReady();
    WorkflowStorage.loadTasks(filesDir);
  }

  private static async readExternalText(uri: string): Promise<string> {
    let file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      let stat = await fileIo.stat(file.fd);
      let buffer = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, buffer);
      return decodeUtf8Compat(new Uint8Array(buffer));
    } finally {
      await fileIo.close(file);
    }
  }

  private static async writeExternalText(uri: string, text: string): Promise<void> {
    let file = await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, text);
    } finally {
      await fileIo.close(file);
    }
  }

  private static totalBytes(files: AppBackupFileEntry[]): number {
    let total = 0;
    for (let i = 0; i < files.length; i++) {
      total += files[i].size;
    }
    return total;
  }

  private static fileEncoding(path: string): AppBackupFileEncoding {
    let lower = path.toLowerCase();
    for (let i = 0; i < TEXT_FILE_SUFFIXES.length; i++) {
      if (lower.endsWith(TEXT_FILE_SUFFIXES[i])) {
        return 'utf8';
      }
    }
    return 'base64';
  }

  private static normalizeFilesDir(filesDir: string): string {
    return filesDir.replace(/\\/g, '/').replace(/\/+$/g, '');
  }

  private static ensureParentDirectory(path: string): void {
    let parent = AppBackupManager.parentPath(path);
    if (parent.length > 0) {
      AppBackupManager.ensureDirectory(parent);
    }
  }

  private static ensureDirectory(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(path)) {
        return;
      }
    } catch (e) {
    }
    let parent = AppBackupManager.parentPath(path);
    if (parent.length > 0 && parent !== path) {
      AppBackupManager.ensureDirectory(parent);
    }
    try {
      fs.mkdirSync(path);
    } catch (e) {
    }
  }

  private static parentPath(path: string): string {
    let normalized = path.replace(/\\/g, '/').replace(/\/+$/g, '');
    let index = normalized.lastIndexOf('/');
    return index > 0 ? normalized.substring(0, index) : '';
  }

  private static readText(path: string): string {
    return decodeUtf8Compat(new Uint8Array(AppBackupManager.readBytes(path)));
  }

  private static readBytes(path: string): ArrayBuffer {
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let stat = fs.statSync(path);
      let buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      return buffer;
    } finally {
      fs.closeSync(file);
    }
  }

  private static writeText(path: string, content: string): void {
    AppBackupManager.writeBytes(path, AppBackupManager.exactArrayBuffer(encodeUtf8Compat(content)));
  }

  private static writeBytes(path: string, data: ArrayBuffer): void {
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
  }

  private static exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    let buffer = new ArrayBuffer(bytes.length);
    let target = new Uint8Array(buffer);
    for (let i = 0; i < bytes.length; i++) {
      target[i] = bytes[i];
    }
    return buffer;
  }

  private static deletePathRecursively(path: string): void {
    try {
      let stat = fs.statSync(path);
      if (stat.isDirectory()) {
        let children = fs.listFileSync(path);
        for (let i = 0; i < children.length; i++) {
          AppBackupManager.deletePathRecursively(path + '/' + children[i]);
        }
        try {
          fs.rmdirSync(path);
        } catch (err) {
        }
        return;
      }
      fs.unlinkSync(path);
    } catch (e) {
    }
  }

  private static nowIsoLocal(): string {
    let date = new Date();
    let offsetMinutes = -date.getTimezoneOffset();
    let sign = offsetMinutes >= 0 ? '+' : '-';
    let abs = Math.abs(offsetMinutes);
    return AppBackupManager.pad(date.getFullYear(), 4) + '-' +
    AppBackupManager.pad(date.getMonth() + 1, 2) + '-' +
    AppBackupManager.pad(date.getDate(), 2) + 'T' +
    AppBackupManager.pad(date.getHours(), 2) + ':' +
    AppBackupManager.pad(date.getMinutes(), 2) + ':' +
    AppBackupManager.pad(date.getSeconds(), 2) +
      sign + AppBackupManager.pad(Math.floor(abs / 60), 2) + ':' + AppBackupManager.pad(abs % 60, 2);
  }

  private static pad(value: number, length: number): string {
    let text = String(value);
    while (text.length < length) {
      text = '0' + text;
    }
    return text;
  }
}
