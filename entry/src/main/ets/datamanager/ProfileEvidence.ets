import { JSON as ArkJSON } from '@kit.ArkTS';
import { IndexedEvent } from './DataManagerTypes';
import { stableUnique, summarizeText } from './DataManagerUtils';

export interface ProfileCalendarEvidence { series_key: string; start: number; end: number; }
export interface ProfileEventPromptPayload {
  event_id: string;
  date: string;
  last_seen_date: string;
  summary: string;
  sources: string[];
  entities: string[];
  keywords: string[];
  calendar?: ProfileCalendarEvidence;
  normalized_fact?: string;
  domains?: string[];
}

// The model input and its cache identity share this projection. Changing an
// image path or a UI-only annotation cannot invalidate a factual summary.
export function profileEvidence(event: IndexedEvent): ProfileEventPromptPayload {
  let result: ProfileEventPromptPayload = {
    event_id: event.event_id, date: event.event_date, last_seen_date: event.last_seen_date,
    summary: summarizeText(event.summary, 110), normalized_fact: summarizeText(event.normalized_fact, 180),
    sources: stableUnique(event.sources || []).sort().slice(0, 3),
    entities: stableUnique(event.entities || []).sort().slice(0, 8),
    keywords: stableUnique(event.keywords || []).sort().slice(0, 6)
  };
  if (event.calendar) {
    result.calendar = { series_key: event.calendar.seriesKey, start: event.calendar.start, end: event.calendar.end };
  }
  return result;
}

export function profileEvidenceText(events: IndexedEvent[], shortIds: boolean = false): string {
  let projected = events.slice().sort((a: IndexedEvent, b: IndexedEvent): number => a.event_id.localeCompare(b.event_id))
    .map((event: IndexedEvent, index: number): ProfileEventPromptPayload => {
      let item = profileEvidence(event);
      if (shortIds) { item.event_id = 'e' + String(index + 1); }
      return item;
    });
  return ArkJSON.stringify(projected);
}
