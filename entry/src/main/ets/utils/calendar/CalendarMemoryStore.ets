import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { stringifyJsonCompat } from '../JsonCompat';
import { CalendarConsentChoice, shouldOfferCalendarConsent, CalendarMemorySettings, CalendarMemorySnapshot, calendarIndexedEvents, calendarReminders,
  defaultCalendarSettings, emptyCalendarSnapshot } from './CalendarMemoryPolicy';
import { HomeRecommendationViewModel, IndexedEvent } from '../../datamanager/DataManagerTypes';

export class CalendarMemoryStore {
  private storage: DataManagerStorage = new DataManagerStorage();
  private root: string;
  constructor(filesDir: string) {
    this.root = this.storage.join(filesDir, 'workflows', 'calendar-memory');
  }

  settings(): CalendarMemorySettings {
    return this.storage.readJson<CalendarMemorySettings>(this.storage.join(this.root, 'settings.json'), defaultCalendarSettings());
  }
  saveSettings(settings: CalendarMemorySettings): void {
    this.storage.writeJsonAtomic(this.storage.join(this.root, 'settings.json'), settings);
  }
  consentChoice(): CalendarConsentChoice {
    return this.storage.readJson<CalendarConsentChoice>(this.storage.join(this.root, 'consent-choice.json'),
      { configured: false, skipReminder: false });
  }
  saveConsentChoice(choice: CalendarConsentChoice): void {
    this.storage.writeJsonAtomic(this.storage.join(this.root, 'consent-choice.json'), choice);
  }
  shouldOfferConsent(): boolean { return shouldOfferCalendarConsent(this.settings().enabled, this.consentChoice()); }
  markConfigured(): void {
    let choice = this.consentChoice();
    choice.configured = true;
    this.saveConsentChoice(choice);
  }
  snapshot(): CalendarMemorySnapshot {
    return this.storage.readJson<CalendarMemorySnapshot>(this.storage.join(this.root, 'snapshot.json'), emptyCalendarSnapshot());
  }
  save(snapshot: CalendarMemorySnapshot): void {
    this.storage.writeJsonAtomic(this.storage.join(this.root, 'snapshot.json'), snapshot);
  }
  events(): IndexedEvent[] { return calendarIndexedEvents(this.snapshot(), this.settings()); }
  reminders(now: number = Date.now()): HomeRecommendationViewModel[] {
    return calendarReminders(this.snapshot(), this.settings(), now);
  }
  fingerprint(): string {
    let settings = this.settings();
    if (!settings.enabled) { return 'calendar-disabled-v1'; }
    let snapshot = this.snapshot();
    let events = this.events();
    // Identify the last read snapshot, not the current clock. Merely opening
    // the app after an event ends must not invalidate a saved profile.
    let readAt = Date.parse(snapshot.syncedAt) || 0;
    let pastIds = events.filter((event: IndexedEvent): boolean => event.calendar !== undefined &&
      event.calendar.end <= readAt).map((event: IndexedEvent): string => event.event_id);
    return this.storage.sha256Text(stringifyJsonCompat(settings) + stringifyJsonCompat(events) +
      pastIds.join(',') + String(snapshot.available));
  }
  indexFingerprint(): string {
    let pastIds = this.events().filter((event: IndexedEvent): boolean => event.calendar !== undefined &&
      event.calendar.end <= Date.now()).map((event: IndexedEvent): string => event.event_id);
    return this.storage.sha256Text(this.fingerprint() + pastIds.join(','));
  }
  setCompleted(id: string, completed: boolean): boolean {
    let snapshot = this.snapshot();
    let key = id.substring('calendar:'.length);
    if (!snapshot.occurrences.some((item) => item.key === key)) { return false; }
    snapshot.completedKeys = snapshot.completedKeys.filter((item: string): boolean => item !== key);
    if (completed) { snapshot.completedKeys.push(key); }
    this.save(snapshot);
    return true;
  }
  clear(): void {
    let settings = this.settings();
    settings.enabled = false;
    this.saveSettings(settings);
    this.markConfigured();
    this.save(emptyCalendarSnapshot());
  }
}
