import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { MailSettings, MailSnapshot, MailItem, defaultMailSettings, emptyMailSnapshot, mailDay,
  mailDayBounds, MAIL_RETENTION_DAYS } from './MailTypes';

export class MailStore {
  private storage: DataManagerStorage = new DataManagerStorage();
  private root: string;
  constructor(filesDir: string) { this.root = this.storage.join(filesDir, 'mail-reminders'); }
  settings(): MailSettings {
    let saved = this.storage.readJson<MailSettings>(this.root + '/settings.json', defaultMailSettings());
    if (saved === null || typeof saved.enabled !== 'boolean' || typeof saved.host !== 'string' ||
      typeof saved.port !== 'number' || typeof saved.username !== 'string' || typeof saved.aiAllowed !== 'boolean' ||
      typeof saved.interested !== 'string' || typeof saved.ignored !== 'string' || typeof saved.maxMessages !== 'number') {
      return defaultMailSettings();
    }
    return saved;
  }
  saveSettings(settings: MailSettings): void { this.storage.writeJsonAtomic(this.root + '/settings.json', settings); }
  snapshot(): MailSnapshot {
    let saved = this.storage.readJson<MailSnapshot>(this.root + '/snapshot.json', emptyMailSnapshot());
    if (saved === null || typeof saved.day !== 'string' || typeof saved.accountKey !== 'string' ||
      typeof saved.uidValidity !== 'string' || typeof saved.syncedAt !== 'string' || typeof saved.error !== 'string' ||
      typeof saved.notice !== 'string' || !Array.isArray(saved.items) || saved.items.length > 100 * MAIL_RETENTION_DAYS ||
      saved.items.some((item: MailItem): boolean => item === null || typeof item.id !== 'string' ||
        !item.id.startsWith('mail:') || !Number.isFinite(item.receivedAt) || typeof item.subject !== 'string' ||
        typeof item.from !== 'string' || typeof item.body !== 'string' || item.body.length > 32000 ||
        typeof item.bodyError !== 'string' || typeof item.summary !== 'string' || typeof item.reason !== 'string' ||
        typeof item.analysisKey !== 'string' || typeof item.relevant !== 'boolean' || typeof item.completed !== 'boolean')) {
      let fallback = emptyMailSnapshot();
      fallback.day = mailDay(); fallback.accountKey = this.accountKey(); fallback.error = '邮件缓存无法读取，请重新同步';
      return fallback;
    }
    return saved;
  }
  save(snapshot: MailSnapshot): void { this.storage.writeJsonAtomic(this.root + '/snapshot.json', snapshot); }
  accountKey(settings: MailSettings = this.settings()): string {
    return this.storage.sha256Text(settings.host.toLowerCase() + ':' + settings.port + ':' + settings.username);
  }
  analysisKey(item: MailItem, settings: MailSettings, model: string): string {
    return this.storage.sha256Text('mail-analysis-v1:' + item.subject + item.from + item.body +
      JSON.stringify([settings.interested, settings.ignored, settings.aiAllowed, model]));
  }
  current(now: number = Date.now()): MailSnapshot {
    let saved = this.snapshot();
    if (saved.accountKey !== this.accountKey()) { return emptyMailSnapshot(); }
    let bounds = mailDayBounds(now, MAIL_RETENTION_DAYS);
    saved.items = saved.items.filter((item: MailItem): boolean => item.receivedAt >= bounds[0] && item.receivedAt < bounds[1]);
    saved.stale = saved.stale || saved.day !== mailDay(now);
    return saved;
  }
  setCompleted(id: string, completed: boolean): boolean {
    let saved = this.current();
    let item = saved.items.find((value: MailItem): boolean => value.id === id);
    if (item === undefined) { return false; }
    item.completed = completed;
    this.save(saved);
    return true;
  }
  clear(): void { this.save(emptyMailSnapshot()); }
}
