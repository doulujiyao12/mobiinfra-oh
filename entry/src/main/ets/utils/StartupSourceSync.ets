import { DataManagerStorage } from '../datamanager/DataManagerStorage';
import { dataManagerInfo, dataManagerWarn } from '../datamanager/DataManagerLog';

export type StartupSourceKey = 'mail' | 'calendar' | 'chat';
export const STARTUP_SOURCE_SYNC_ENABLED_KEY: string = 'startupSourceSyncEnabled';
const SOURCES: StartupSourceKey[] = ['mail', 'calendar', 'chat'];
export const STARTUP_SOURCE_SYNC_INTERVAL_MS: number = 24 * 60 * 60 * 1000;
export interface StartupSourceSelection { mail: boolean; calendar: boolean; chat: boolean; }
export interface StartupSourceActions {
  mail: () => Promise<void>;
  calendar: () => Promise<void>;
  chat: () => Promise<void>;
}
interface SourceSyncStamp { successAt: number; attemptedAt: number; failedAt?: number; }
interface StartupSyncState {
  mail: SourceSyncStamp;
  calendar: SourceSyncStamp;
  chat: SourceSyncStamp;
  memoryCheckedAt?: number;
}
interface StartupSyncPreferences { enabled: boolean; }
export interface StartupSyncResult { updated: string[]; failed: string[]; }
export interface StartupSyncProgress {
  source: StartupSourceKey;
  completed: number;
  total: number;
  finished: boolean;
}
export type StartupSyncProgressCallback = (progress: StartupSyncProgress) => void;

// Foreground-only daily refresh. Neither a timer nor an HDC task scheduler.
export class StartupSourceSync {
  private storage: DataManagerStorage = new DataManagerStorage();
  private path: string;
  private preferencesPath: string;
  private static running: boolean = false;
  constructor(filesDir: string) {
    this.path = this.storage.join(filesDir, 'workflows', 'startup-source-sync.json');
    this.preferencesPath = this.storage.join(filesDir, 'workflows', 'startup-source-settings.json');
  }
  isEnabled(): boolean {
    if (!this.storage.exists(this.preferencesPath)) { return true; }
    let saved = this.storage.readJson<StartupSyncPreferences | null>(this.preferencesPath, null);
    return saved !== null && saved.enabled === true;
  }
  setEnabled(enabled: boolean): void {
    let settings: StartupSyncPreferences = { enabled: enabled };
    this.storage.writeJsonAtomic(this.preferencesPath, settings);
  }
  private stamp(state: StartupSyncState, source: StartupSourceKey): SourceSyncStamp {
    return source === 'mail' ? state.mail : source === 'calendar' ? state.calendar : state.chat;
  }
  private enabled(selection: StartupSourceSelection, source: StartupSourceKey): boolean {
    return source === 'mail' ? selection.mail : source === 'calendar' ? selection.calendar : selection.chat;
  }
  private async execute(actions: StartupSourceActions, source: StartupSourceKey): Promise<void> {
    if (source === 'mail') { await actions.mail(); }
    else if (source === 'calendar') { await actions.calendar(); }
    else { await actions.chat(); }
  }
  private state(): StartupSyncState {
    let fallback: StartupSyncState = { mail: { successAt: 0, attemptedAt: 0 },
      calendar: { successAt: 0, attemptedAt: 0 }, chat: { successAt: 0, attemptedAt: 0 } };
    let saved = this.storage.readJson<StartupSyncState>(this.path, fallback);
    if (!saved) { return fallback; }
    const checkedAt = saved.memoryCheckedAt || 0;
    fallback.memoryCheckedAt = Number.isFinite(checkedAt) && checkedAt >= 0 ? checkedAt : 0;
    for (let source of SOURCES) {
      let stamp = this.stamp(saved, source);
      if (!stamp) { continue; }
      let normalized = this.stamp(fallback, source);
      normalized.successAt = Number.isFinite(stamp.successAt) && stamp.successAt >= 0 ? stamp.successAt : 0;
      normalized.attemptedAt = Number.isFinite(stamp.attemptedAt) && stamp.attemptedAt >= 0 ? stamp.attemptedAt : 0;
      let failed = stamp.failedAt || 0;
      normalized.failedAt = Number.isFinite(failed) && failed >= 0 ? failed : 0;
    }
    return fallback;
  }
  // Presentation/reminder history, independent of per-source scheduling and
  // the full daily-log snapshot used to discover unprocessed task/gallery data.
  latestSuccessfulSyncAt(): number {
    const state = this.state();
    return Math.max(state.memoryCheckedAt || 0, state.mail.successAt, state.calendar.successAt, state.chat.successAt);
  }
  markMemoryChecked(now: number = Date.now()): void {
    if (!Number.isFinite(now) || now <= 0) { throw new Error('同步完成时间无效'); }
    const state = this.state(); state.memoryCheckedAt = now;
    this.storage.writeJsonAtomic(this.path, state);
  }
  markSynced(source: StartupSourceKey, now: number = Date.now()): void {
    if (source !== 'mail' && source !== 'calendar' && source !== 'chat') { throw new Error('同步来源无效'); }
    let state = this.state();
    let stamp = this.stamp(state, source); stamp.successAt = now; stamp.attemptedAt = now; stamp.failedAt = 0;
    this.storage.writeJsonAtomic(this.path, state);
  }
  markAttempted(source: StartupSourceKey, now: number = Date.now()): void {
    let state = this.state(); this.stamp(state, source).attemptedAt = now;
    this.storage.writeJsonAtomic(this.path, state);
  }
  markFailed(source: StartupSourceKey, now: number = Date.now()): void {
    let state = this.state(); this.stamp(state, source).failedAt = now;
    // Attempt was persisted before work started. Failure bookkeeping must not
    // mask the original error or hide its UI if storage itself is failing.
    try { this.storage.writeJsonAtomic(this.path, state); }
    catch (e) { dataManagerWarn('SYNC_FAILURE_STATE_WRITE_FAILED source=' + source); }
  }
  private due(stamp: SourceSyncStamp, now: number, retryFailed: boolean = false): boolean {
    let success = Number.isFinite(stamp.successAt) ? stamp.successAt : 0;
    let attempt = Number.isFinite(stamp.attemptedAt) ? stamp.attemptedAt : 0;
    if (retryFailed) { return (stamp.failedAt || 0) > success; }
    // A failed/interrupted attempt consumes this automatic window too. Only
    // an explicit retry may restart it sooner; foregrounding is not a retry.
    let reference = Math.max(success, attempt, stamp.failedAt || 0);
    return reference === 0 || now - reference >= STARTUP_SOURCE_SYNC_INTERVAL_MS;
  }
  hasDue(selection: StartupSourceSelection, now: number = Date.now(), retryFailed: boolean = false): boolean {
    let pending = this.pendingSelection(selection, now, retryFailed);
    return pending.mail || pending.calendar || pending.chat;
  }
  pendingSelection(selection: StartupSourceSelection, now: number = Date.now(), retryFailed: boolean = false): StartupSourceSelection {
    let active = retryFailed || this.isEnabled();
    let state = this.state();
    let pending: StartupSourceSelection = { mail: active && selection.mail && this.due(state.mail, now, retryFailed),
      calendar: active && selection.calendar && this.due(state.calendar, now, retryFailed),
      chat: active && selection.chat && this.due(state.chat, now, retryFailed) };
    return pending;
  }
  async run(selection: StartupSourceSelection, actions: StartupSourceActions,
    now: number = Date.now(), progress?: StartupSyncProgressCallback, retryFailed: boolean = false): Promise<StartupSyncResult> {
    let result: StartupSyncResult = { updated: [], failed: [] };
    if ((!retryFailed && !this.isEnabled()) || StartupSourceSync.running) { return result; }
    StartupSourceSync.running = true;
    let runStarted = Date.now();
    let clockNow = (): number => now + Math.max(0, Date.now() - runStarted);
    try {
      let pending = this.pendingSelection(selection, now, retryFailed);
      let sources = SOURCES.filter((source: StartupSourceKey): boolean => this.enabled(pending, source));
      for (let source of sources) {
        if (!retryFailed && !this.isEnabled()) { break; }
        if (!this.enabled(selection, source) || !this.due(this.stamp(this.state(), source), clockNow(), retryFailed)) { continue; }
        let attemptedAt = clockNow();
        this.markAttempted(source, attemptedAt);
        let started = Date.now();
        let begin: StartupSyncProgress = { source: source, completed: result.updated.length + result.failed.length,
          total: sources.length, finished: false };
        if (progress) { progress(begin); }
        dataManagerInfo('STARTUP_SYNC_BEGIN source=' + source + ' total=' + sources.length);
        try {
          await this.execute(actions, source);
          this.markSynced(source, clockNow()); result.updated.push(source);
          dataManagerInfo('STARTUP_SYNC success source=' + source + ' elapsedMs=' + (Date.now() - started));
        } catch (e) {
          this.markFailed(source, Math.max(attemptedAt + 1, clockNow()));
          result.failed.push(source);
          dataManagerWarn('STARTUP_SYNC failed source=' + source + ' elapsedMs=' + (Date.now() - started) + '; content omitted');
        }
        let end: StartupSyncProgress = { source: source, completed: result.updated.length + result.failed.length,
          total: sources.length, finished: true };
        if (progress) { progress(end); }
      }
      return result;
    } finally { StartupSourceSync.running = false; }
  }
}
