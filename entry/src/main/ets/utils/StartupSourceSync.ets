import { DataManagerStorage } from '../datamanager/DataManagerStorage';
import { dataManagerInfo, dataManagerWarn } from '../datamanager/DataManagerLog';
import { mailDay } from './mail/MailTypes';

export type StartupSourceKey = 'mail' | 'calendar' | 'chat';
export const STARTUP_SOURCE_SYNC_ENABLED_KEY: string = 'startupSourceSyncEnabled';
const SOURCES: StartupSourceKey[] = ['mail', 'calendar', 'chat'];
export interface StartupSourceSelection { mail: boolean; calendar: boolean; chat: boolean; }
export interface StartupSourceActions {
  mail: () => Promise<void>;
  calendar: () => Promise<void>;
  chat: () => Promise<void>;
}
interface SourceSyncStamp { successAt: number; attemptedAt: number; }
interface StartupSyncState { mail: SourceSyncStamp; calendar: SourceSyncStamp; chat: SourceSyncStamp; }
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
    if (!saved || !saved.mail || !saved.calendar || !saved.chat) { return fallback; }
    for (let source of SOURCES) {
      let stamp = this.stamp(saved, source);
      if (!Number.isFinite(stamp.successAt) || !Number.isFinite(stamp.attemptedAt) ||
        stamp.successAt < 0 || stamp.attemptedAt < 0) { return fallback; }
    }
    return saved;
  }
  markSynced(source: StartupSourceKey, now: number = Date.now()): void {
    if (source !== 'mail' && source !== 'calendar' && source !== 'chat') { throw new Error('同步来源无效'); }
    let state = this.state();
    let stamp = this.stamp(state, source); stamp.successAt = now; stamp.attemptedAt = now;
    this.storage.writeJsonAtomic(this.path, state);
  }
  private due(stamp: SourceSyncStamp, now: number): boolean {
    let success = Number.isFinite(stamp.successAt) ? stamp.successAt : 0;
    let attempt = Number.isFinite(stamp.attemptedAt) ? stamp.attemptedAt : 0;
    return (success === 0 || (now > success && mailDay(success) !== mailDay(now))) &&
      (attempt === 0 || now - attempt >= 10 * 60 * 1000);
  }
  hasDue(selection: StartupSourceSelection, now: number = Date.now()): boolean {
    let pending = this.pendingSelection(selection, now);
    return pending.mail || pending.calendar || pending.chat;
  }
  pendingSelection(selection: StartupSourceSelection, now: number = Date.now()): StartupSourceSelection {
    let active = this.isEnabled();
    let state = this.state();
    let pending: StartupSourceSelection = { mail: active && selection.mail && this.due(state.mail, now),
      calendar: active && selection.calendar && this.due(state.calendar, now),
      chat: active && selection.chat && this.due(state.chat, now) };
    return pending;
  }
  async run(selection: StartupSourceSelection, actions: StartupSourceActions,
    now: number = Date.now(), progress?: StartupSyncProgressCallback): Promise<StartupSyncResult> {
    let result: StartupSyncResult = { updated: [], failed: [] };
    if (!this.isEnabled() || StartupSourceSync.running) { return result; }
    StartupSourceSync.running = true;
    try {
      let pending = this.pendingSelection(selection, now);
      let sources = SOURCES.filter((source: StartupSourceKey): boolean => this.enabled(pending, source));
      for (let source of sources) {
        if (!this.isEnabled()) { break; }
        if (!this.enabled(selection, source) || !this.due(this.stamp(this.state(), source), now)) { continue; }
        let state = this.state(); this.stamp(state, source).attemptedAt = now;
        this.storage.writeJsonAtomic(this.path, state);
        let started = Date.now();
        let begin: StartupSyncProgress = { source: source, completed: result.updated.length + result.failed.length,
          total: sources.length, finished: false };
        if (progress) { progress(begin); }
        dataManagerInfo('STARTUP_SYNC_BEGIN source=' + source + ' total=' + sources.length);
        try {
          await this.execute(actions, source);
          this.markSynced(source, now); result.updated.push(source);
          dataManagerInfo('STARTUP_SYNC success source=' + source + ' elapsedMs=' + (Date.now() - started));
        } catch (e) {
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
