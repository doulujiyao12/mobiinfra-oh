import { CollectionImageViewModel, HomeRecommendationViewModel } from '../../datamanager/DataManagerTypes';
import { HomeCodexEvidence, HomeCodexRequest, isHomeCodexExcludedId } from '../../datamanager/HomeCodexContext';
import { HomeTaskSuggestion, HomeTaskSuggestionEvidence } from './HomeTaskSuggestion';

export function homeReminderSupportsCodex(item: HomeRecommendationViewModel): boolean {
  return !isHomeCodexExcludedId(item.id) && item.calendarStart === undefined &&
    !(item.sourceEventIds.length > 0 && item.sourceEventIds.every(isHomeCodexExcludedId));
}

export function homeReminderCodexRequest(item: HomeRecommendationViewModel): HomeCodexRequest {
  if (!homeReminderSupportsCodex(item)) { throw new Error('日历和邮箱提醒暂不支持交给 Codex'); }
  return { kind: 'reminder', id: item.id, title: item.title, description: item.desc,
    goal: item.agentTask, eventIds: item.sourceEventIds.slice(), evidence: [],
    imageRefs: item.imageRefs.map((image: CollectionImageViewModel): string => image.ref) };
}

export function homeSuggestionCodexRequest(item: HomeTaskSuggestion): HomeCodexRequest {
  return { kind: 'suggestion', id: item.id, title: item.title, description: item.reason, goal: item.task,
    eventIds: [], evidence: item.evidence.map((entry: HomeTaskSuggestionEvidence): HomeCodexEvidence => ({
      label: entry.title, summary: entry.summary, eventId: entry.eventId, profileDomain: entry.profileDomain })) };
}
