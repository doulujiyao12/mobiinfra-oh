import { DataManagerStorage } from './DataManagerStorage';

export interface MemorySourceChange { kind: string; path: string; revision: string; }
interface SourceChangeDocument { schema: string; changes: MemorySourceChange[]; }
const JOURNAL_SCHEMA: string = 'memory-source-changes-v1';

// Invalidate before a synchronous source write. A crash can cause a harmless
// retry, never a falsely clean source. Acknowledge only the captured revision.
export class MemoryChangeJournal {
  private root: string;
  private storage: DataManagerStorage;
  private static sequence: number = 0;
  constructor(filesDir: string, storage: DataManagerStorage) {
    this.storage = storage;
    this.root = storage.join(filesDir, 'workflows', 'profile-consolidation', 'source-changes');
  }
  mark(kind: string, path: string): void {
    if (!['daily', 'gallery', 'chat'].includes(kind) || !this.validPath(path)) { throw new Error('记忆变更路径无效'); }
    let change = this.change(kind, path);
    this.save(kind, this.pending(kind).filter((item: MemorySourceChange): boolean => item.path !== path).concat([change]));
  }
  pending(kind: string, recover: boolean = false): MemorySourceChange[] {
    let path = this.storage.join(this.root, kind + '.json');
    if (!this.storage.exists(path) && !this.ready(kind)) { return []; }
    let document = this.storage.readJson<SourceChangeDocument | null>(path, null);
    if (!document || document.schema !== JOURNAL_SCHEMA || !Array.isArray(document.changes) ||
      document.changes.some((item: MemorySourceChange): boolean => !item || item.kind !== kind ||
        typeof item.path !== 'string' || !this.validPath(item.path) || typeof item.revision !== 'string' || !item.revision)) {
      if (!recover) { throw new Error('记忆变更记录无法读取，请进行完整检查'); }
      let changes: MemorySourceChange[] = [this.change(kind, '*')];
      this.save(kind, changes); return changes;
    }
    return document.changes;
  }
  acknowledge(changes: MemorySourceChange[]): void {
    ['daily', 'gallery', 'chat'].forEach((kind: string) => {
      let captured = changes.filter((item: MemorySourceChange): boolean => item.kind === kind);
      if (captured.length === 0) { return; }
      let current = this.pending(kind);
      let remaining = current.filter((item: MemorySourceChange): boolean =>
        !captured.some((old: MemorySourceChange): boolean => old.path === item.path && old.revision === item.revision));
      if (remaining.length !== current.length) { this.save(kind, remaining); }
    });
  }
  ready(kind: string): boolean {
    return this.storage.readText(this.storage.join(this.root, kind + '-ready'), '') === JOURNAL_SCHEMA;
  }
  setReady(kind: string): void {
    if (!this.storage.exists(this.storage.join(this.root, kind + '.json'))) { this.save(kind, []); }
    this.storage.writeTextAtomic(this.storage.join(this.root, kind + '-ready'), JOURNAL_SCHEMA);
  }
  private save(kind: string, changes: MemorySourceChange[]): void {
    let document: SourceChangeDocument = { schema: JOURNAL_SCHEMA, changes: changes };
    this.storage.writeJsonAtomic(this.storage.join(this.root, kind + '.json'), document);
  }
  private change(kind: string, path: string): MemorySourceChange {
    MemoryChangeJournal.sequence++;
    return { kind: kind, path: path,
      revision: String(Date.now()) + '-' + String(MemoryChangeJournal.sequence) + '-' + String(Math.random()) };
  }
  private validPath(path: string): boolean {
    return path === '*' || (path.length > 0 && !path.startsWith('/') && !path.includes('\\') &&
      !path.split('/').some((part: string): boolean => part === '..' || part === '.' || part.length === 0));
  }
  static beforeMutation(path: string, storage: DataManagerStorage): void {
    let normalized = path.replace(/\\/g, '/');
    let gallery = normalized.indexOf('/gallery-log');
    if (gallery >= 0) {
      let relative = normalized.substring(gallery + '/gallery-log'.length);
      let date = /^\/items\/(\d{4}-\d{2}-\d{2})(?:\/[^/]+\.json)?$/.exec(relative);
      if (date) { new MemoryChangeJournal(normalized.substring(0, gallery), storage).mark('gallery', date[1]); }
      else if (relative === '' || relative === '/items') { new MemoryChangeJournal(normalized.substring(0, gallery), storage).mark('gallery', '*'); }
    }
    let chat = normalized.indexOf('/chat-sessions/sessions/');
    if (chat >= 0) {
      let id = normalized.substring(chat + '/chat-sessions/sessions/'.length);
      if (/^[^/]+\.json$/.test(id)) { new MemoryChangeJournal(normalized.substring(0, chat), storage).mark('chat', id.substring(0, id.length - 5)); }
    }
    let marker = '/workflows/daily-log'; let position = normalized.indexOf(marker);
    if (position >= 0 && (normalized.length === position + marker.length || normalized[position + marker.length] === '/')) {
      let relative = normalized.substring(position + marker.length).replace(/^\//, '');
      if (/^\d{4}-\d{2}-\d{2}\/[^/]+\.md$/.test(relative)) {
        new MemoryChangeJournal(normalized.substring(0, position), storage).mark('daily', relative);
      } else if (relative.length === 0 || /^\d{4}-\d{2}-\d{2}$/.test(relative)) {
        new MemoryChangeJournal(normalized.substring(0, position), storage).mark('daily', '*');
      }
    }
  }
}
