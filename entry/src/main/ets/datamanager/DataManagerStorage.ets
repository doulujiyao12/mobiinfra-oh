import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import fs from '@ohos.file.fs';
import { parseJsonCompat, stringifyJsonCompat } from '../utils/JsonCompat';
import { decodeUtf8Compat, encodeUtf8Compat } from '../utils/TextEncodingCompat';
import { MemoryChangeJournal } from './MemoryChangeJournal';

const EMPTY_SHA256: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
type ListFileEntry = string | Record<string, Object | string | number | boolean | null>;

export class DataManagerStorage {
  private readPrefix: string = '';
  private readCache: Map<string, string> = new Map<string, string>();
  private readBytes: number = 0;
  private readHits: number = 0;
  beginReadSession(prefix: string): void {
    this.readPrefix = prefix + '/'; this.readCache.clear(); this.readBytes = 0; this.readHits = 0;
  }
  endReadSession(): number {
    let hits = this.readHits; this.readPrefix = ''; this.readCache.clear(); this.readBytes = 0; return hits;
  }
  private invalidateRead(path: string): void {
    let cached = this.readCache.get(path);
    if (cached !== undefined) { this.readBytes -= cached.length * 2; this.readCache.delete(path); }
  }
  join(...parts: string[]): string {
    let filtered = parts
      .filter((part: string) => part.length > 0)
      .map((part: string, index: number) => {
        let value = part.replace(/\\/g, '/');
        if (index === 0) {
          return value.replace(/\/+$/g, '');
        }
        return value.replace(/^\/+/g, '').replace(/\/+$/g, '');
      });
    return filtered.join('/');
  }

  dirname(path: string): string {
    let normalized = path.replace(/\\/g, '/');
    let index = normalized.lastIndexOf('/');
    return index > 0 ? normalized.substring(0, index) : '';
  }

  basename(path: string): string {
    let normalized = path.replace(/\\/g, '/');
    let index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }

  exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  isDirectory(path: string): boolean {
    try {
      if (!this.exists(path)) {
        return false;
      }
      return fs.statSync(path).isDirectory();
    } catch (e) {
      return false;
    }
  }

  ensureDir(path: string): void {
    if (path.length === 0 || this.exists(path)) {
      return;
    }
    let normalized = path.replace(/\\/g, '/');
    let parts = normalized.split('/').filter((part: string) => part.length > 0);
    let current = normalized.startsWith('/') ? '' : '';
    for (let part of parts) {
      current = current.length === 0 ? (normalized.startsWith('/') ? '/' + part : part) : current + '/' + part;
      if (!this.exists(current)) {
        try {
          fs.mkdirSync(current);
        } catch (e) {
        }
      }
    }
  }

  listDir(path: string): string[] {
    try {
      if (!this.isDirectory(path)) {
        return [];
      }
      return (fs.listFileSync(path) as ListFileEntry[])
        .map((entry: ListFileEntry) => this.normalizeListFileEntry(entry))
        .filter((name: string) => name.length > 0)
        .sort();
    } catch (e) {
      return [];
    }
  }

  readText(path: string, fallback: string = ''): string {
    let cached = this.readCache.get(path);
    if (this.readPrefix.length > 0 && path.startsWith(this.readPrefix) && cached !== undefined) {
      this.readHits++; return cached;
    }
    try {
      if (!this.exists(path)) {
        return fallback;
      }
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let stat = fs.statSync(path);
        let buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        let text = this.decodeText(new Uint8Array(buf));
        if (this.readPrefix.length > 0 && path.startsWith(this.readPrefix) && this.readBytes + text.length * 2 <= 16 * 1024 * 1024) {
          this.readCache.set(path, text); this.readBytes += text.length * 2;
        }
        return text;
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return fallback;
    }
  }

  writeText(path: string, content: string): void {
    MemoryChangeJournal.beforeMutation(path, this);
    this.invalidateRead(path);
    try {
      let parent = this.dirname(path);
      if (parent.length > 0) {
        this.ensureDir(parent);
      }
      let encoded = this.encodeText(content);
      let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, encoded.buffer);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  writeBytes(path: string, bytes: Uint8Array): void {
    this.invalidateRead(path);
    try {
      let parent = this.dirname(path);
      if (parent.length > 0) {
        this.ensureDir(parent);
      }
      let buffer = this.exactArrayBuffer(bytes);
      let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  writeBytesAtomic(path: string, bytes: Uint8Array): void {
    this.invalidateRead(path);
    let temporary = path + '.tmp';
    this.writeBytes(temporary, bytes);
    try {
      if (this.exists(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
    }
    try {
      fs.renameSync(temporary, path);
    } catch (e) {
      this.writeBytes(path, bytes);
      try {
        fs.unlinkSync(temporary);
      } catch (err) {
      }
    }
  }

  writeTextAtomic(path: string, content: string): void {
    MemoryChangeJournal.beforeMutation(path, this);
    this.invalidateRead(path);
    let temporary = path + '.tmp';
    this.writeText(temporary, content);
    try {
      if (this.exists(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
    }
    try {
      fs.renameSync(temporary, path);
    } catch (e) {
      this.writeText(path, content);
      try {
        fs.unlinkSync(temporary);
      } catch (err) {
      }
    }
  }

  readJson<T>(path: string, fallback: T): T {
    let content = this.readText(path, '');
    if (content.length === 0) {
      return fallback;
    }
    try {
      return parseJsonCompat<T>(content);
    } catch (e) {
      return fallback;
    }
  }

  writeJsonAtomic(path: string, payload: Object): void {
    this.writeTextAtomic(path, stringifyJsonCompat(payload, 2) + '\n');
  }

  removeFile(path: string): void {
    MemoryChangeJournal.beforeMutation(path, this);
    this.invalidateRead(path);
    try {
      if (this.exists(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
    }
  }

  removeTree(path: string): void {
    MemoryChangeJournal.beforeMutation(path, this);
    if (!this.exists(path)) {
      return;
    }
    if (!this.isDirectory(path)) {
      this.removeFile(path);
      return;
    }
    let children = this.listDir(path);
    for (let child of children) {
      this.removeTree(this.join(path, child));
    }
    try {
      fs.unlinkSync(path);
      return;
    } catch (e) {
    }
    try {
      fs.rmdirSync(path);
    } catch (e) {
    }
  }

  syncJsonDirectory(directory: string, desired: Record<string, Object>): void {
    this.ensureDir(directory);
    Object.keys(desired).forEach((name: string) => {
      this.writeJsonAtomic(this.join(directory, name), desired[name]);
    });
    this.listDir(directory).forEach((name: string) => {
      if (name.endsWith('.json') && desired[name] === undefined) {
        this.removeFile(this.join(directory, name));
      }
    });
  }

  findFiles(root: string, suffix: string): string[] {
    let result: string[] = [];
    this.findFilesInner(root, suffix, result);
    return result.sort();
  }

  private findFilesInner(path: string, suffix: string, out: string[]): void {
    if (!this.exists(path)) {
      return;
    }
    if (!this.isDirectory(path)) {
      if (path.endsWith(suffix)) {
        out.push(path);
      }
      return;
    }
    let children = this.listDir(path);
    for (let child of children) {
      let childPath = this.join(path, child);
      if (this.isDirectory(childPath)) {
        this.findFilesInner(childPath, suffix, out);
      } else if (child.endsWith(suffix)) {
        out.push(childPath);
      }
    }
  }

  relativePath(root: string, path: string): string {
    let normalizedRoot = root.replace(/\\/g, '/').replace(/\/+$/g, '');
    let normalizedPath = path.replace(/\\/g, '/');
    if (normalizedPath.startsWith(normalizedRoot + '/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    return normalizedPath;
  }

  sha256Text(value: string): string {
    if (value.length === 0) {
      return EMPTY_SHA256;
    }
    let bytes = this.encodeText(value);
    try {
      let md = cryptoFramework.createMd('SHA256');
      let blob: cryptoFramework.DataBlob = { data: bytes };
      md.updateSync(blob);
      let digest = this.bytesToHex(md.digestSync().data);
      if (digest.length > 0 && digest !== EMPTY_SHA256) {
        return digest;
      }
    } catch (e) {
    }
    return this.stableFallbackHash(bytes);
  }

  private bytesToHex(bytes: Uint8Array): string {
    let parts: string[] = [];
    for (let index = 0; index < bytes.length; index++) {
      parts.push(bytes[index].toString(16).padStart(2, '0'));
    }
    return parts.join('');
  }

  private normalizeListFileEntry(entry: ListFileEntry): string {
    if (typeof entry === 'string') {
      return this.basename(entry);
    }
    let record = entry as Record<string, Object | string | number | boolean | null>;
    let keys: string[] = ['fileName', 'filename', 'name', 'path', 'uri'];
    for (let key of keys) {
      let value = record[key];
      if (typeof value === 'string' && value.length > 0) {
        return this.basename(value);
      }
    }
    let text = String(entry);
    if (text.length === 0 || text === '[object Object]') {
      return '';
    }
    return this.basename(text);
  }

  private exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
      return bytes.buffer as ArrayBuffer;
    }
    let output = new ArrayBuffer(bytes.byteLength);
    let view = new Uint8Array(output);
    for (let index = 0; index < bytes.byteLength; index++) {
      view[index] = bytes[index];
    }
    return output;
  }

  private decodeText(bytes: Uint8Array): string {
    return decodeUtf8Compat(bytes);
  }

  private encodeText(value: string): Uint8Array {
    return encodeUtf8Compat(value);
  }

  private stableFallbackHash(bytes: Uint8Array): string {
    let hashA = 2166136261;
    let hashB = 16777619;
    for (let index = 0; index < bytes.length; index++) {
      hashA ^= bytes[index];
      hashA = Math.imul(hashA, 16777619);
      hashB ^= bytes[index];
      hashB = Math.imul(hashB, 2246822519);
    }
    let a = this.uint32Hex(hashA);
    let b = this.uint32Hex(hashB);
    let length = this.uint32Hex(bytes.length);
    return a + b + length + a + b + length + a + b;
  }

  private uint32Hex(value: number): string {
    return (value >>> 0).toString(16).padStart(8, '0');
  }
}
