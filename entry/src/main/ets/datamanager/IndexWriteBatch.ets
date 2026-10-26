import { DataManagerStorage } from './DataManagerStorage';
import { StringMap, BooleanMap } from './DataManagerTypes';
import { dataManagerInfo } from './DataManagerLog';

interface IndexMutation { relative: string; file: string; sha256: string; remove: boolean; }
interface IndexCommit { schema: string; mutations: IndexMutation[]; }
const COMMIT_SCHEMA: string = 'index-commit-v1';

// Build against an in-memory overlay. Only changed files are staged. Publication
// is synchronous; a durable prepared journal is replayed before any index read
// after a process crash. Preparing/model failure never alters the live index.
export class IndexWriteBatch extends DataManagerStorage {
  private base: DataManagerStorage;
  private root: string;
  private pending: Map<string, string> = new Map<string, string>();
  private removed: Set<string> = new Set<string>();
  written: number = 0;
  reused: number = 0;
  constructor(root: string, base: DataManagerStorage) { super(); this.root = root; this.base = base; }
  private owns(path: string): boolean { return path.startsWith(this.root + '/'); }
  readText(path: string, fallback: string = ''): string {
    if (this.removed.has(path)) { return fallback; }
    let content = this.pending.get(path);
    return content !== undefined ? content : this.base.readText(path, fallback);
  }
  exists(path: string): boolean {
    if (this.removed.has(path)) { return false; }
    return this.pending.has(path) || this.base.exists(path);
  }
  ensureDir(path: string): void { this.base.ensureDir(path); }
  listDir(path: string): string[] {
    let names = this.base.listDir(path).filter((name: string): boolean => !this.removed.has(this.join(path, name)));
    this.pending.forEach((content: string, file: string) => {
      if (this.dirname(file) === path && names.indexOf(this.basename(file)) < 0) { names.push(this.basename(file)); }
    });
    return names.sort();
  }
  writeTextAtomic(path: string, content: string): void {
    if (!this.owns(path)) { this.base.writeTextAtomic(path, content); return; }
    if (this.base.exists(path) && this.base.readText(path) === content) {
      this.pending.delete(path); this.removed.delete(path); this.reused++; return;
    }
    this.pending.set(path, content); this.removed.delete(path);
  }
  removeFile(path: string): void {
    if (!this.owns(path)) { this.base.removeFile(path); return; }
    this.pending.delete(path); this.removed.add(path);
  }
  commit(): void {
    let journal = this.root + '.pending-sync';
    // A previous prepared commit must be recovered, never overwritten.
    IndexWriteBatch.recover(this.root, this.base);
    let mutations: IndexMutation[] = [];
    Array.from(this.pending.keys()).sort().forEach((target: string) => {
      let content = this.pending.get(target);
      if (content === undefined) { throw new Error('待发布索引内容缺失'); }
      let file = this.base.sha256Text(target) + '.txt';
      this.base.writeTextAtomic(this.base.join(journal, file), content);
      mutations.push({ relative: target.substring(this.root.length + 1), file: file,
        sha256: this.base.sha256Text(content), remove: false });
    });
    Array.from(this.removed.values()).sort().forEach((target: string) => {
      mutations.push({ relative: target.substring(this.root.length + 1), file: '', sha256: '', remove: true });
    });
    let manifest: IndexCommit = { schema: COMMIT_SCHEMA, mutations: mutations };
    // No live writes until every staged file and this marker are durable.
    this.base.writeJsonAtomic(this.base.join(journal, 'prepared.json'), manifest);
    IndexWriteBatch.recover(this.root, this.base);
    this.written = mutations.length;
    dataManagerInfo('SYNC_INDEX_WRITE changedFiles=' + this.written + ' reusedFiles=' + this.reused);
  }
  static recover(root: string, storage: DataManagerStorage): void {
    if (storage instanceof IndexWriteBatch) { IndexWriteBatch.recover(root, storage.base); return; }
    let journal = root + '.pending-sync'; let marker = storage.join(journal, 'prepared.json');
    if (!storage.exists(marker)) { return; }
    let manifest = storage.readJson<IndexCommit | null>(marker, null);
    if (!manifest || manifest.schema !== COMMIT_SCHEMA || !Array.isArray(manifest.mutations)) {
      throw new Error('索引恢复记录损坏，请保留数据并重试');
    }
    // Validate the whole journal before changing even one live file.
    let contents: StringMap = {};
    let seen: BooleanMap = {};
    manifest.mutations.forEach((change: IndexMutation) => {
      if (!/^[A-Za-z0-9_.\/-]+$/.test(change.relative) || change.relative.startsWith('/') ||
        change.relative.split('/').some((part: string): boolean => part === '..' || part === '.' || part.length === 0) ||
        seen[change.relative] || typeof change.remove !== 'boolean') { throw new Error('索引恢复路径无效'); }
      seen[change.relative] = true;
      if (!change.remove) {
        if (!/^[a-f0-9]{64}\.txt$/.test(change.file) || !/^[a-f0-9]{64}$/.test(change.sha256)) { throw new Error('索引恢复校验无效'); }
        let file = storage.join(journal, change.file);
        if (!storage.exists(file)) { throw new Error('索引恢复文件缺失，请保留数据并重试'); }
        let text = storage.readText(file);
        if (storage.sha256Text(text) !== change.sha256) { throw new Error('索引恢复文件校验失败'); }
        contents[change.relative] = text;
      }
    });
    manifest.mutations.forEach((change: IndexMutation) => {
      let target = storage.join(root, change.relative);
      if (change.remove) {
        storage.removeFile(target);
        if (storage.exists(target)) { throw new Error('无法移除过期索引，请重试'); }
      } else if (!storage.exists(target) || storage.readText(target) !== contents[change.relative]) {
        storage.writeTextAtomic(target, contents[change.relative]);
      }
    });
    storage.removeFile(marker);
    if (storage.exists(marker)) { throw new Error('无法完成索引恢复，请重试'); }
    // Leave a fully applied commit intact if cleanup is interrupted.
    manifest.mutations.forEach((change: IndexMutation) => {
      if (!change.remove) { storage.removeFile(storage.join(journal, change.file)); }
    });
  }
}
