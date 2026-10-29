import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { DataPipelineModelClient } from './DataPipelineModelClient';
import { IndexService } from './IndexService';
import { dataManagerError, dataManagerInfo } from './DataManagerLog';
import {
  DataManagerModelConfig,
  DataManagerProgressCallback,
  HomeRecommendationPlannerEvent,
  HomeRecommendationsDocument,
  HomeRecommendationState,
  IndexedEvent,
  createDataManagerProgress
} from './DataManagerTypes';
import {
  isIsoDate,
  normalizeDomains,
  normalizeFreeText,
  nowIsoLocal,
  stableUnique
} from './DataManagerUtils';

export interface HomeRecommendationBuildResult {
  totalEvents: number;
  recommendationCount: number;
  reused: boolean;
  prunedCount: number;
}

export interface HomeRecommendationPruneResult {
  document: HomeRecommendationsDocument;
  prunedCount: number;
}

interface HomeRecommendationPlanningContext {
  plannerEvents: HomeRecommendationPlannerEvent[];
  plannerEventsById: Record<string, HomeRecommendationPlannerEvent>;
  events: Record<string, IndexedEvent>;
  candidateEventIds: string[];
  today: string;
}

const HOME_TODO_NO_DEADLINE_RECENT_DAYS: number = 7;

export function homeRecommendationSourceInputFingerprint(events: HomeRecommendationPlannerEvent[]): string {
  let parts: string[] = ['home_recommendation_source_v1'];
  events.forEach((event: HomeRecommendationPlannerEvent) => {
    parts.push([
      event.event_id,
      event.date,
      event.todo_type,
      event.todo_deadline,
      event.todo_text,
      event.summary,
      event.normalized_fact,
      event.sources.join(','),
      event.domains.join(','),
      event.keywords.join(','),
      event.image_paths.join(',')
    ].join('\u001f'));
  });
  return parts.join('\u001e');
}

export function isHomeRecommendationSourceReusable(storedHash: string, currentHash: string, sourceEventIds: string[],
  candidateEventIds: string[], coveredEventIds: string[]): boolean {
  if (sourceEventIds.length === 0 || normalizeFreeText(storedHash).length === 0 || storedHash !== currentHash) {
    return false;
  }
  let candidates: Record<string, boolean> = new Object() as Record<string, boolean>;
  candidateEventIds.forEach((id: string) => candidates[id] = true);
  let covered: Record<string, boolean> = new Object() as Record<string, boolean>;
  coveredEventIds.forEach((id: string) => covered[id] = true);
  for (let id of sourceEventIds) {
    if (candidates[id] !== true || covered[id] === true) {
      return false;
    }
  }
  return true;
}

export function isCurrentOrFutureTodoDeadline(deadline: string, today: string): boolean {
  return isIsoDate(deadline) && isIsoDate(today) && deadline >= today;
}

export function pruneHomeRecommendationsDocument(document: HomeRecommendationsDocument, candidateEventIds: string[]): HomeRecommendationPruneResult {
  let candidates: Record<string, boolean> = new Object() as Record<string, boolean>;
  (candidateEventIds || []).forEach((id: string) => {
    let normalized = normalizeFreeText(id);
    if (normalized.length > 0) {
      candidates[normalized] = true;
    }
  });

  let recommendations: HomeRecommendationState[] = [];
  let prunedCount = 0;
  (document.recommendations || []).forEach((item: HomeRecommendationState) => {
    let sourceEventIds = item.source_event_ids || [];
    if (sourceEventIds.length === 0) {
      prunedCount++;
      return;
    }
    for (let sourceEventId of sourceEventIds) {
      let normalized = normalizeFreeText(sourceEventId);
      if (normalized.length === 0 || candidates[normalized] !== true) {
        prunedCount++;
        return;
      }
    }
    recommendations.push(item);
  });

  if (prunedCount === 0) {
    return {
      document: document,
      prunedCount: 0
    };
  }

  let prunedDocument: HomeRecommendationsDocument = {
    generated_at: normalizeFreeText(document.generated_at),
    input_hash: normalizeFreeText(document.input_hash),
    total_events: candidateEventIds.length,
    recommendations: recommendations
  };
  return {
    document: prunedDocument,
    prunedCount: prunedCount
  };
}

export function recommendationTodoDeadlineMeta(deadline: string): string {
  if (!isIsoDate(deadline)) {
    return '';
  }
  let month = Number(deadline.substring(5, 7));
  let day = Number(deadline.substring(8, 10));
  return `${month}月${day}日截止`;
}

export function emptyHomeRecommendationsDocument(): HomeRecommendationsDocument {
  return {
    generated_at: '',
    input_hash: '',
    total_events: 0,
    recommendations: []
  };
}

export class HomeRecommendationService {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private modelClient: DataPipelineModelClient;
  private indexService: IndexService;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage, modelClient: DataPipelineModelClient, indexService: IndexService) {
    this.paths = paths;
    this.storage = storage;
    this.modelClient = modelClient;
    this.indexService = indexService;
  }

  async build(modelConfig: DataManagerModelConfig, progress?: DataManagerProgressCallback, forceWhenEmpty: boolean = false): Promise<HomeRecommendationBuildResult> {
    this.paths.ensureBaseDirs();
    this.emitProgress(progress, '索引', '正在生成待办推荐', 0, 100, 99);
    let context = this.planningContext();
    let inputHash = this.inputHash(context, modelConfig);
    let previous = this.loadDocument();
    let pruneResult = pruneHomeRecommendationsDocument(previous, context.candidateEventIds);
    previous = pruneResult.document;
    let previousGenerated = normalizeFreeText(previous.generated_at).length > 0;
    let previousHasInputHash = normalizeFreeText(previous.input_hash).length > 0;
    let previousEmptyButMissing = (previous.recommendations || []).length === 0 && (!previousGenerated || !previousHasInputHash);
    let shouldRebuildEmpty = forceWhenEmpty && context.candidateEventIds.length > 0 && previousEmptyButMissing;
    if (previous.input_hash === inputHash && !shouldRebuildEmpty) {
      if (pruneResult.prunedCount > 0) {
        this.storage.writeJsonAtomic(this.paths.homeRecommendationsPath(), previous as Object);
      }
      dataManagerInfo(`Home recommendations reused: events=${context.candidateEventIds.length}, recommendations=${previous.recommendations.length}, pruned=${pruneResult.prunedCount}`);
      return {
        totalEvents: context.candidateEventIds.length,
        recommendationCount: previous.recommendations.length,
        reused: true,
        prunedCount: pruneResult.prunedCount
      };
    }
    if (shouldRebuildEmpty) {
      dataManagerInfo(`Home recommendations empty, rebuild requested: events=${context.candidateEventIds.length}`);
    }
    let recommendations = await this.buildIncrementalRecommendations(previous, context, modelConfig);
    let document: HomeRecommendationsDocument = {
      generated_at: nowIsoLocal(),
      input_hash: inputHash,
      total_events: context.candidateEventIds.length,
      recommendations: recommendations
    };
    this.storage.writeJsonAtomic(this.paths.homeRecommendationsPath(), document as Object);
    dataManagerInfo(`Home recommendations built: events=${context.candidateEventIds.length}, recommendations=${recommendations.length}`);
    return {
      totalEvents: context.candidateEventIds.length,
      recommendationCount: recommendations.length,
      reused: false,
      prunedCount: pruneResult.prunedCount
    };
  }

  loadDocument(): HomeRecommendationsDocument {
    return this.storage.readJson<HomeRecommendationsDocument>(this.paths.homeRecommendationsPath(), emptyHomeRecommendationsDocument());
  }

  cachedBuildResult(day: string | undefined): HomeRecommendationBuildResult | null {
    if (day !== this.currentDateKey()) { return null; }
    let document = this.loadDocument();
    if (!document.generated_at || !document.input_hash || !Array.isArray(document.recommendations)) { return null; }
    return { totalEvents: document.total_events, recommendationCount: document.recommendations.length, reused: true, prunedCount: 0 };
  }

  pruneInactiveRecommendationsForToday(): number {
    this.paths.ensureBaseDirs();
    let context = this.planningContext();
    let document = this.loadDocument();
    let result = pruneHomeRecommendationsDocument(document, context.candidateEventIds);
    if (result.prunedCount > 0) {
      this.storage.writeJsonAtomic(this.paths.homeRecommendationsPath(), result.document as Object);
      dataManagerInfo(`Home recommendations pruned: events=${context.candidateEventIds.length}, pruned=${result.prunedCount}, recommendations=${result.document.recommendations.length}`);
    }
    return result.prunedCount;
  }

  private planningContext(): HomeRecommendationPlanningContext {
    let today = this.currentDateKey();
    let todoEvents = this.indexService.loadHomeTodoCandidateEvents(today, HOME_TODO_NO_DEADLINE_RECENT_DAYS);
    let candidates: IndexedEvent[] = [];
    Object.keys(todoEvents).forEach((eventId: string) => {
      let event = todoEvents[eventId];
      let todoType = normalizeFreeText(event.todo.type);
      let deadline = normalizeFreeText(event.todo.deadline);
      let hasCurrentOrFutureDeadline = isCurrentOrFutureTodoDeadline(deadline, today);
      let hasNoDeadlineAction = deadline.length === 0 && todoType.length > 0;
      if (hasCurrentOrFutureDeadline || hasNoDeadlineAction) {
        candidates.push(event);
      }
    });
    candidates.sort((left: IndexedEvent, right: IndexedEvent) => {
      let leftDeadline = normalizeFreeText(left.todo.deadline);
      let rightDeadline = normalizeFreeText(right.todo.deadline);
      if (leftDeadline.length > 0 && rightDeadline.length === 0) {
        return -1;
      }
      if (leftDeadline.length === 0 && rightDeadline.length > 0) {
        return 1;
      }
      if (leftDeadline !== rightDeadline) {
        return leftDeadline.localeCompare(rightDeadline);
      }
      if (left.event_date !== right.event_date) {
        return right.event_date.localeCompare(left.event_date);
      }
      return left.event_id.localeCompare(right.event_id);
    });
    let eventMap: Record<string, IndexedEvent> = new Object() as Record<string, IndexedEvent>;
    let plannerEventsById: Record<string, HomeRecommendationPlannerEvent> = new Object() as Record<string, HomeRecommendationPlannerEvent>;
    let plannerEvents: HomeRecommendationPlannerEvent[] = [];
    candidates.forEach((event: IndexedEvent) => {
      eventMap[event.event_id] = event;
      let plannerEvent: HomeRecommendationPlannerEvent = {
        event_id: event.event_id,
        date: event.event_date,
        todo_type: event.todo.type,
        todo_deadline: event.todo.deadline,
        todo_text: event.todo.text,
        summary: normalizeFreeText(event.summary),
        normalized_fact: normalizeFreeText(event.normalized_fact),
        sources: (event.sources || []).slice(),
        domains: (event.domains || []).slice(),
        keywords: (event.keywords || []).slice(),
        image_paths: (event.image_paths || []).slice()
      };
      plannerEvents.push(plannerEvent);
      plannerEventsById[event.event_id] = plannerEvent;
    });
    return {
      plannerEvents: plannerEvents,
      plannerEventsById: plannerEventsById,
      events: eventMap,
      candidateEventIds: candidates.map((event: IndexedEvent): string => event.event_id),
      today: today
    };
  }

  private inputHash(context: HomeRecommendationPlanningContext, modelConfig: DataManagerModelConfig): string {
    let parts: string[] = [
      'home_recommendations_todo',
      context.today,
      modelConfig.enabled ? 'model' : 'disabled',
      modelConfig.enabled ? modelConfig.baseUrl : ''
    ];
    context.plannerEvents.forEach((event: HomeRecommendationPlannerEvent) => {
      parts.push([
        event.event_id,
        event.date,
        event.todo_type,
        event.todo_deadline,
        event.todo_text,
        event.summary,
        event.normalized_fact,
        event.sources.join(','),
        event.domains.join(','),
        event.keywords.join(','),
        event.image_paths.join(',')
      ].join('\u001f'));
    });
    return this.storage.sha256Text(parts.join('\u001e'));
  }

  private currentDateKey(): string {
    return nowIsoLocal().substring(0, 10);
  }

  private async buildIncrementalRecommendations(previous: HomeRecommendationsDocument, context: HomeRecommendationPlanningContext,
    modelConfig: DataManagerModelConfig): Promise<HomeRecommendationState[]> {
    let usedIds: Record<string, boolean> = new Object() as Record<string, boolean>;
    let covered: Record<string, boolean> = new Object() as Record<string, boolean>;
    let recommendations = this.reusePreviousRecommendations(previous.recommendations || [], context, usedIds, covered);
    let remainingContext = this.remainingPlanningContext(context, covered);
    if (modelConfig.enabled && remainingContext.plannerEvents.length > 0) {
      try {
        let planned = await this.modelClient.planHomeRecommendations(remainingContext.plannerEvents, remainingContext.today, modelConfig);
        recommendations = recommendations.concat(this.normalizeRecommendations(planned, remainingContext, usedIds));
      } catch (e) {
        let err = e as Error;
        dataManagerError(`Home recommendation planner failed: ${err.message}`);
      }
    }
    dataManagerInfo(`Home recommendations incremental: reused=${Object.keys(covered).length}, plannedEvents=${remainingContext.plannerEvents.length}, recommendations=${recommendations.length}`);
    return recommendations;
  }

  private reusePreviousRecommendations(previous: HomeRecommendationState[], context: HomeRecommendationPlanningContext,
    usedIds: Record<string, boolean>, covered: Record<string, boolean>): HomeRecommendationState[] {
    let result: HomeRecommendationState[] = [];
    previous.forEach((item: HomeRecommendationState) => {
      let eventIds = stableUnique(item.source_event_ids || []);
      let currentHash = this.recommendationSourceInputHash(eventIds, context);
      if (!isHomeRecommendationSourceReusable(normalizeFreeText(item.source_input_hash), currentHash, eventIds,
        context.candidateEventIds, Object.keys(covered))) {
        return;
      }
      let id = normalizeFreeText(item.id);
      let title = normalizeFreeText(item.title);
      if (id.length === 0 || title.length === 0) {
        return;
      }
      let domain = normalizeFreeText(item.domain) || this.firstEventDomain(eventIds, context.events);
      let recommendation: HomeRecommendationState = {
        id: id,
        tag: normalizeFreeText(item.tag),
        title: title,
        desc: normalizeFreeText(item.desc),
        meta: this.deadlineMeta(eventIds, context.events),
        domain: domain,
        source_event_ids: eventIds,
        source_input_hash: currentHash,
        completed: item.completed === true
      };
      result.push(recommendation);
      usedIds[id] = true;
      eventIds.forEach((eventId: string) => covered[eventId] = true);
    });
    return result;
  }

  private remainingPlanningContext(context: HomeRecommendationPlanningContext, covered: Record<string, boolean>): HomeRecommendationPlanningContext {
    let plannerEvents = context.plannerEvents.filter((event: HomeRecommendationPlannerEvent): boolean => covered[event.event_id] !== true);
    let plannerEventsById: Record<string, HomeRecommendationPlannerEvent> = new Object() as Record<string, HomeRecommendationPlannerEvent>;
    plannerEvents.forEach((event: HomeRecommendationPlannerEvent) => plannerEventsById[event.event_id] = event);
    return {
      plannerEvents: plannerEvents,
      plannerEventsById: plannerEventsById,
      events: context.events,
      candidateEventIds: plannerEvents.map((event: HomeRecommendationPlannerEvent): string => event.event_id),
      today: context.today
    };
  }

  private normalizeRecommendations(planned: HomeRecommendationState[], context: HomeRecommendationPlanningContext,
    usedIds: Record<string, boolean>): HomeRecommendationState[] {
    let result: HomeRecommendationState[] = [];
    let allowed: Record<string, boolean> = new Object() as Record<string, boolean>;
    context.candidateEventIds.forEach((id: string) => allowed[id] = true);
    let covered: Record<string, boolean> = new Object() as Record<string, boolean>;
    planned.forEach((item: HomeRecommendationState) => {
      let eventIds = stableUnique((item.source_event_ids || [])
        .filter((id: string): boolean => allowed[id] === true && covered[id] !== true));
      if (eventIds.length === 0) {
        return;
      }
      let title = this.recommendationTitle(item, eventIds, context.events);
      if (title.length === 0) {
        return;
      }
      let domains = normalizeDomains([normalizeFreeText(item.domain)]);
      let domain = domains.length > 0 ? domains[0] : this.firstEventDomain(eventIds, context.events);
      let recommendation: HomeRecommendationState = {
        id: this.nextRecommendationId(usedIds),
        tag: this.normalizeRecommendationTag(item.tag, eventIds, context.events),
        title: title,
        desc: this.recommendationDesc(item, eventIds, context.events),
        meta: this.deadlineMeta(eventIds, context.events),
        domain: domain,
        source_event_ids: eventIds,
        source_input_hash: this.recommendationSourceInputHash(eventIds, context),
        completed: false
      };
      result.push(recommendation);
      eventIds.forEach((eventId: string) => covered[eventId] = true);
    });
    return result;
  }

  private recommendationSourceInputHash(eventIds: string[], context: HomeRecommendationPlanningContext): string {
    let events: HomeRecommendationPlannerEvent[] = [];
    for (let id of eventIds) {
      let event = context.plannerEventsById[id];
      if (!event) {
        return '';
      }
      events.push(event);
    }
    return this.storage.sha256Text(homeRecommendationSourceInputFingerprint(events));
  }

  private nextRecommendationId(usedIds: Record<string, boolean>): string {
    let index = 1;
    while (usedIds['todo-' + String(index)] === true) {
      index++;
    }
    let id = 'todo-' + String(index);
    usedIds[id] = true;
    return id;
  }

  private recommendationTitle(item: HomeRecommendationState, eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    return normalizeFreeText(item.title) || this.firstTodoText(eventIds, eventMap) || this.firstEventText(eventIds, eventMap);
  }

  private recommendationDesc(item: HomeRecommendationState, eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    return normalizeFreeText(item.desc) || this.firstTodoText(eventIds, eventMap) || this.firstEventText(eventIds, eventMap);
  }

  private normalizeRecommendationTag(value: string, eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    let tag = normalizeFreeText(value);
    if (tag.length >= 2 && tag.length <= 6) {
      return tag;
    }
    return this.todoTypeTag(this.firstTodoType(eventIds, eventMap), this.hasDeadline(eventIds, eventMap));
  }

  private firstTodoType(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    for (let id of eventIds) {
      let event = eventMap[id];
      let type = event ? normalizeFreeText(event.todo.type) : '';
      if (type.length > 0) {
        return type;
      }
    }
    return '';
  }

  private firstTodoText(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    for (let id of eventIds) {
      let event = eventMap[id];
      let text = event ? normalizeFreeText(event.todo.text) : '';
      if (text.length > 0) {
        return text;
      }
    }
    return '';
  }

  private todoTypeTag(type: string, hasDeadline: boolean): string {
    if (type === 'buy') {
      return '待购买';
    }
    if (type === 'pay') {
      return '待付款';
    }
    if (type === 'pickup') {
      return '待取件';
    }
    if (type === 'order') {
      return '待下单';
    }
    if (type === 'renew') {
      return '待续费';
    }
    if (type === 'book') {
      return '待预订';
    }
    if (type === 'repair') {
      return '待维修';
    }
    if (type === 'appointment') {
      return '待预约';
    }
    if (type === 'plan') {
      return '待安排';
    }
    if (type === 'attend') {
      return '待出席';
    }
    if (type === 'depart') {
      return '待出发';
    }
    if (type === 'check_in') {
      return '待入住';
    }
    if (type === 'reimburse') {
      return '待报销';
    }
    if (hasDeadline) {
      return '日程提醒';
    }
    return '待处理';
  }

  private hasDeadline(eventIds: string[], eventMap: Record<string, IndexedEvent>): boolean {
    for (let id of eventIds) {
      let event = eventMap[id];
      if (event && isIsoDate(event.todo.deadline)) {
        return true;
      }
    }
    return false;
  }

  private deadlineMeta(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    let deadlines: string[] = [];
    eventIds.forEach((id: string) => {
      let event = eventMap[id];
      if (event && isIsoDate(event.todo.deadline)) {
        let deadline = event.todo.deadline;
        deadlines.push(deadline);
      }
    });
    deadlines = stableUnique(deadlines).sort();
    return deadlines.length > 0 ? recommendationTodoDeadlineMeta(deadlines[0]) : '';
  }

  private firstEventText(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    for (let id of eventIds) {
      let event = eventMap[id];
      if (event) {
        return normalizeFreeText(event.summary || event.normalized_fact);
      }
    }
    return '';
  }

  private firstEventDomain(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    for (let id of eventIds) {
      let event = eventMap[id];
      if (event && event.domains.length > 0) {
        return event.domains[0];
      }
    }
    return 'other';
  }

  private emitProgress(progress: DataManagerProgressCallback | undefined, stage: string, message: string, current: number, total: number, percent: number): void {
    if (!progress) {
      return;
    }
    progress(createDataManagerProgress(stage, message, current, total, percent));
  }
}
