// 本地手动备份格式定义：外层 JSON 可识别，业务 payload 始终以用户密码派生密钥加密。
export const APP_BACKUP_FORMAT: string = 'mobiinfra.backup.encrypted';
export const APP_BACKUP_SCHEMA_VERSION: number = 1;
export const APP_BACKUP_KDF: string = 'PBKDF2-HMAC-SHA256';
export const APP_BACKUP_KDF_ALG_NAME: string = 'PBKDF2|SHA256';
export const APP_BACKUP_KDF_SPEC_ALG_NAME: string = 'PBKDF2';
export const APP_BACKUP_CIPHER: string = 'AES-256-GCM';
export const APP_BACKUP_CIPHER_TRANSFORMATION: string = 'AES256|GCM|PKCS7';
export const APP_BACKUP_KEY_ALG_NAME: string = 'AES256';
export const APP_BACKUP_KDF_ITERATIONS: number = 200000;
export const APP_BACKUP_KEY_SIZE: number = 32;
export const APP_BACKUP_SALT_SIZE: number = 16;
export const APP_BACKUP_IV_SIZE: number = 12;
export const APP_BACKUP_AUTH_TAG_SIZE: number = 16;
export const APP_BACKUP_MIN_PASSWORD_LENGTH: number = 6;

export type AppBackupSettingValue = Object | string | number | boolean | null;
export type AppBackupSettingMap = Record<string, AppBackupSettingValue>;
export type AppBackupFileEncoding = 'utf8' | 'base64';

export interface AppBackupCryptoInfo {
  algorithm: string;
  kdf: string;
  iterations: number;
  salt: string;
  iv: string;
  authTag: string;
}

export interface AppBackupEnvelope {
  format: string;
  schemaVersion: number;
  createdAt: string;
  crypto: AppBackupCryptoInfo;
  payload: string;
}

export interface AppBackupFileEntry {
  path: string;
  encoding: AppBackupFileEncoding;
  content: string;
  size: number;
  modifiedTime: number;
}

export interface AppBackupPayload {
  schemaVersion: number;
  createdAt: string;
  includeSensitiveSettings: boolean;
  settings: AppBackupSettingMap;
  files: AppBackupFileEntry[];
}

export interface AppBackupExportOptions {
  password: string;
  includeSensitiveSettings: boolean;
  targetUri: string;
}

export interface AppBackupImportOptions {
  password: string;
  sourceUri: string;
  overwrite: boolean;
}

export interface AppBackupExportResult {
  fileCount: number;
  totalBytes: number;
  targetUri: string;
  createdAt: string;
}

export interface AppBackupImportResult {
  fileCount: number;
  restoredSettings: number;
}
