import { JSON as ArkJSON } from '@kit.ArkTS';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { DataPipelineModelClient } from './DataPipelineModelClient';
import { dataManagerInfo, dataManagerWarn } from './DataManagerLog';
import {
  AggregatedRecord,
  BooleanMap,
  ConsolidatedState,
  DataManagerModelConfig,
  DataManagerProgressCallback,
  DOMAIN_DISPLAY_NAMES,
  DOMAIN_KEYS,
  EntityMention,
  EventPartition,
  IndexedEvent,
  IndexedEventTodo,
  JsonMap,
  NumberedEntry,
  ProfileClaim,
  ProfileDomainState,
  ProfileModelPayload,
  ProfileState,
  QueryOptions,
  QueryResult,
  RawProfileClaim,
  NumberMap,
  StringArrayMap,
  StringMap,
  createJsonMap,
  createDataManagerProgress,
  createStringMap
} from './DataManagerTypes';
import {
  addDays,
  dateToTime,
  deriveProfileDomains,
  displayDomainName,
  entityDisplayKey,
  entityLookupKey,
  eventSearchText,
  eventSourceNames,
  indexTerms,
  isIsoDate,
  monthKeyFromDate,
  normalizeEntityName,
  normalizeDomains,
  normalizeEntityMentions,
  normalizeFreeText,
  normalizeLookupText,
  normalizeProfileShortSummary,
  nowIsoLocal,
  parseNumberedEntries,
  publicEvent,
  sourceSearchText,
  stableUnique,
  stableUniqueNumbers,
  summarizeText
} from './DataManagerUtils';
import {
  memorySceneConfigs,
  PERSONAL_INFO_MEMORY_SCENE_ID,
  normalizeMemorySceneId,
  normalizeMemorySceneIds,
  workflowSceneConfigs,
  WorkflowSceneConfig
} from '../utils/WorkflowSceneConfig';
import { GalleryMemorySync } from '../utils/gallery/GalleryMemorySync';

export interface IndexBuildResult {
  sourceFiles: number;
  eventCount: number;
  profileClaimCount: number;
  updatedAt: string;
}

type EventMap = Record<string, IndexedEvent>;
type ObjectMap = Record<string, Object>;

interface SourceManifestEntry {
  sha256: string;
  event_ids: string[];
  event_input_hashes: StringMap;
}

type SourceManifestMap = Record<string, SourceManifestEntry>;

interface EnrichmentManifest {
  schema: string;
  mode: string;
  base_url: string;
}

interface IndexManifest {
  generated_at: string;
  input_root: string;
  index_dir: string;
  run_root: string;
  enrichment: EnrichmentManifest;
  entity_types: string[];
  sources: SourceManifestMap;
}

interface IndexSourceBuildResult {
  relativePath: string;
  sourceEntry: SourceManifestEntry;
  events: EventMap;
  reusedEvents: number;
  enrichedEvents: number;
}

interface IndexSourceCursor {
  nextIndex: number;
}

interface IndexBuildCounters {
  completedSources: number;
  reusedEvents: number;
  enrichedEvents: number;
}

type EventGroupMap = Record<string, IndexedEvent[]>;
type TemporalDayMap = Record<string, TemporalDayNode[]>;
type TemporalDocumentMap = Record<string, TemporalDocument>;
type ProfileDomainMap = Record<string, ProfileDomainState>;

const DEFAULT_INDEX_SOURCE_CONCURRENCY: number = 4;
const EVENT_PARTITION_INDEX_FILE_NAME: string = 'partition-index.json';

interface InvertedDocument {
  postings: StringArrayMap;
}

interface SourceDocument {
  postings: StringArrayMap;
}

interface DomainDocument {
  postings: StringArrayMap;
}

interface WorkflowSceneDocument {
  postings: StringArrayMap;
}

interface HomeTodoDocument {
  deadline_postings: StringArrayMap;
  no_deadline_event_ids: string[];
  type_postings: StringArrayMap;
}

interface QueryTimeScope {
  hasTime: boolean;
  lower: string;
  upper: string;
}

interface EventPartitionIndex {
  schema: string;
  generated_at: string;
  partition_files: string[];
}

interface EntityDefinition {
  type: string;
  name: string;
  aliases: string[];
  event_ids: string[];
}

type EntityDefinitionMap = Record<string, EntityDefinition>;

interface EntityDocument {
  entities: EntityDefinitionMap;
  alias_postings: StringArrayMap;
  mention_assignments?: StringMap;
}

interface EntityMentionCatalogEntry {
  type: string;
  name: string;
  aliases: string[];
  event_ids: string[];
}

type EntityMentionCatalogMap = Record<string, EntityMentionCatalogEntry>;
type EntityMentionCatalogByType = Record<string, EntityMentionCatalogMap>;

interface EntityBuildStats {
  reusedMentionCount: number;
  newMentionCount: number;
  candidateCount: number;
  llmCallCount: number;
}

interface EntityCandidateScore {
  key: string;
  score: number;
  eventCount: number;
}

interface ImageReferenceCandidate {
  summary: string;
  image_path: string;
  used: boolean;
}

type ImageReferenceCandidateMap = Record<string, ImageReferenceCandidate[]>;

const ENTITY_TYPE_KEYS: string[] = ['person', 'place', 'merchant'];

const PROFILE_MODEL_MAX_TOKENS: number = 3000;
const PROFILE_MODEL_PROMPT_CHAR_LIMIT: number = 12000;
const PROFILE_MODEL_MERGE_CHAR_LIMIT: number = 10000;

interface TemporalDayNode {
  date: string;
  event_ids: string[];
}

interface TemporalWeekNode {
  week_id: string;
  start_date: string;
  end_date: string;
  event_ids: string[];
  days: TemporalDayNode[];
}

interface TemporalDocument {
  month: string;
  event_ids: string[];
  weeks: TemporalWeekNode[];
}

export function resolveQueryLimit(selectedLength: number, requestedLimit: number): number {
  return requestedLimit > 0 ? requestedLimit : selectedLength;
}

export function isQueryResultTruncated(selectedLength: number, requestedLimit: number): boolean {
  return requestedLimit > 0 && selectedLength > requestedLimit;
}

export function isHomeTodoIndexCandidate(todo: IndexedEventTodo, eventSceneIds: number[], chatSceneIds: number[]): boolean {
  let type = normalizeFreeText(todo.type);
  let deadline = normalizeFreeText(todo.deadline);
  if (type.length === 0 && !isIsoDate(deadline)) {
    return false;
  }
  if (!isIsoDate(deadline) && hasAnySceneId(eventSceneIds, chatSceneIds) && type !== 'buy') {
    return false;
  }
  return true;
}

export function isRecentNoDeadlineHomeTodoEvent(eventDate: string, today: string, recentDays: number): boolean {
  if (!isIsoDate(eventDate) || !isIsoDate(today)) {
    return false;
  }
  let days = Math.max(0, recentDays);
  let recentLowerBoundExclusive = addDays(today, -days);
  return eventDate > recentLowerBoundExclusive;
}

export function monthLastDateForTemporalIndex(month: string): string {
  if (!/^\d{4}-\d{2}$/.test(month)) {
    return month + '-31';
  }
  let year = Number(month.substring(0, 4));
  let monthNumber = Number(month.substring(5, 7));
  if (isNaN(year) || isNaN(monthNumber) || monthNumber < 1 || monthNumber > 12) {
    return month + '-31';
  }
  return new Date(Date.UTC(year, monthNumber, 0)).toISOString().substring(0, 10);
}

export function normalizeQueryKeywordOperator(value?: string): string {
  let normalized = normalizeFreeText(value === undefined ? '' : value).toLowerCase();
  return normalized === 'or' ? 'or' : 'and';
}

function hasAnySceneId(eventSceneIds: number[], selectedSceneIds: number[]): boolean {
  for (let sceneId of selectedSceneIds) {
    if (eventSceneIds.indexOf(sceneId) >= 0) {
      return true;
    }
  }
  return false;
}

export function eventEnrichInputFingerprint(event: IndexedEvent): string {
  let fields: string[] = [
    'event_enrich_input_v1',
    event.event_id,
    event.event_date,
    event.last_seen_date,
    normalizeFreeText(event.summary),
    normalizeFreeText(event.normalized_fact),
    stableUnique(event.tags || []).sort().join('\u001d'),
    stableUnique(event.source_refs || []).sort().join('\u001d'),
    stableUniqueNumbers(event.workflow_scene_ids || []).map((sceneId: number): string => String(sceneId)).join('\u001d'),
    stableUnique(event.image_paths || []).sort().join('\u001d')
  ];
  return fields.join('\u001f');
}

export function isEventEnrichInputReusable(previousHash: string, currentHash: string, previousEventExists: boolean): boolean {
  return previousEventExists && normalizeFreeText(previousHash).length > 0 && previousHash === currentHash;
}

function profileGenerationFromModelPayload(payload: ProfileModelPayload, claims: ProfileClaim[]): string {
  let generation = normalizeFreeText(payload.generation);
  if (claims.length === 0) {
    if (generation === 'model') {
      return 'model_empty';
    }
    return generation.length > 0 ? generation : 'model_empty';
  }
  return 'model';
}

export function isProfileDomainStateReusable(domain: ProfileDomainState | undefined, eventCount: number): boolean {
  if (!domain || !Array.isArray(domain.claims)) {
    return false;
  }
  let generation = normalizeFreeText(domain.generation);
  if (generation === 'model' || generation === 'model_empty') {
    return true;
  }
  return generation === 'empty' && eventCount === 0;
}

export function buildProfileDomainStateFromPayload(domain: string, inputHash: string, eventIds: string[], eventCount: number,
  dateRange: StringMap, payload: ProfileModelPayload, claims: ProfileClaim[]): ProfileDomainState {
  let generation = profileGenerationFromModelPayload(payload, claims);
  let hasModelClaims = generation === 'model' && claims.length > 0;
  let range: StringMap = createStringMap();
  range.start_date = dateRange ? dateRange.start_date || '' : '';
  range.end_date = dateRange ? dateRange.end_date || '' : '';
  let domainState: ProfileDomainState = {
    domain: domain,
    display_name: DOMAIN_DISPLAY_NAMES[domain] || domain,
    input_hash: inputHash,
    event_ids: eventIds.slice(),
    event_count: eventCount,
    date_range: range,
    short_summary: hasModelClaims ? normalizeProfileShortSummary(payload.short_summary) : '',
    summary: hasModelClaims ? normalizeFreeText(payload.summary) : '',
    claims: hasModelClaims ? claims : [],
    generation: generation
  };
  return domainState;
}

export class IndexService {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private modelClient: DataPipelineModelClient;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage, modelClient: DataPipelineModelClient) {
    this.paths = paths;
    this.storage = storage;
    this.modelClient = modelClient;
  }

  async build(modelConfig: DataManagerModelConfig, progress?: DataManagerProgressCallback): Promise<IndexBuildResult> {
    this.paths.ensureBaseDirs();
    let statePaths = this.loadOutputStatePaths();
    this.emitProgress(progress, '索引', `发现 ${statePaths.length} 个整理文件`, 0, Math.max(1, statePaths.length), 62);
    dataManagerInfo(`Index build start: stateFiles=${statePaths.length}, outputsRoot=${this.paths.outputsRoot}, modelEnabled=${modelConfig.enabled}`);
    if (statePaths.length === 0) {
      dataManagerWarn('Index build found no consolidated state files.');
    }
    let enrichment = this.currentEnrichment(modelConfig);
    let previousManifest = this.loadManifest();
    let previousEvents = this.loadEvents();
    let reuseAllowed = this.canReuseIndex(previousManifest, enrichment);
    let imageReferences = this.buildImageReferenceMap();
    let events: EventMap = {};
    let sources: SourceManifestMap = {};
    let counters: IndexBuildCounters = {
      completedSources: 0,
      reusedEvents: 0,
      enrichedEvents: 0
    };
    await this.buildSourcesConcurrently(statePaths, previousManifest, previousEvents, reuseAllowed, imageReferences,
      modelConfig, events, sources, counters, progress);

    this.emitProgress(progress, '写入索引', '正在写入事件索引', 85, 100, 85);
    this.writeEventPartitions(events);
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'inverted', 'index.json'), this.buildInvertedDocument(events));
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'source', 'index.json'), this.buildSourceDocument(events));
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'domain', 'index.json'), this.buildDomainDocument(events));
    this.storage.ensureDir(this.storage.join(this.paths.indexesRoot, 'workflow-scene'));
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'workflow-scene', 'index.json'), this.buildWorkflowSceneDocument(events));
    this.storage.ensureDir(this.storage.join(this.paths.indexesRoot, 'home-todo'));
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'home-todo', 'index.json'), this.buildHomeTodoDocument(events));
    let previousEntity = this.storage.readJson<EntityDocument>(this.storage.join(this.paths.indexesRoot, 'entity', 'index.json'), this.emptyEntityDocument());
    let entityDocument = await this.buildEntityDocument(events, modelConfig, previousEntity, reuseAllowed && this.hasEntityIndexData(previousEntity));
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'entity', 'index.json'), entityDocument);
    this.writeTemporalDocuments(events);
    this.emitProgress(progress, '生成画像', '正在生成用户画像', 90, 100, 90);
    let profile = await this.buildProfileDocument(events, modelConfig, reuseAllowed, progress);
    dataManagerInfo(`Index profile built: eventCount=${profile.event_count}, claimCount=${profile.claim_count}`);
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'profile', 'state.json'), profile as Object);
    this.storage.writeTextAtomic(this.storage.join(this.paths.indexesRoot, 'profile', 'profile.md'), this.renderProfileMarkdown(profile));

    let manifest: IndexManifest = {
      generated_at: nowIsoLocal(),
      input_root: 'workflows/profile-consolidation/outputs',
      index_dir: 'workflows/profile-consolidation/indexes',
      run_root: 'workflows/runs',
      enrichment: enrichment,
      entity_types: ENTITY_TYPE_KEYS,
      sources: this.orderedSourcesByStatePaths(sources, statePaths)
    };
    this.storage.writeJsonAtomic(this.storage.join(this.paths.indexesRoot, 'manifest.json'), manifest);
    dataManagerInfo(`Index build done: events=${Object.keys(events).length}, reused=${counters.reusedEvents}, enriched=${counters.enrichedEvents}, manifest=${this.storage.join(this.paths.indexesRoot, 'manifest.json')}`);
    // Keep the index handoff aligned with DataManagerFacade's collection grouping range.
    this.emitProgress(progress, '写入索引', '索引写入完成', 96, 100, 96);
    return {
      sourceFiles: statePaths.length,
      eventCount: Object.keys(events).length,
      profileClaimCount: profile.claim_count,
      updatedAt: profile.generated_at
    };
  }

  private loadOutputStatePaths(): string[] {
    let paths = this.storage.findFiles(this.paths.outputsRoot, '.md.state.json');
    paths = paths.concat(this.outputStatePathsFromIndex());
    return stableUnique(paths)
      .filter((path: string) => path.endsWith('.md.state.json') && this.storage.exists(path))
      .sort();
  }

  private outputStatePathsFromIndex(): string[] {
    let payload = this.storage.readJson<JsonMap>(this.storage.join(this.paths.outputsRoot, 'state-index.json'), createJsonMap());
    let value = payload['state_paths'];
    if (!Array.isArray(value)) {
      return [];
    }
    let paths: string[] = [];
    (value as string[]).forEach((item: string) => {
      let relativePath = normalizeFreeText(item);
      if (relativePath.length > 0) {
        paths.push(this.storage.join(this.paths.outputsRoot, relativePath));
      }
    });
    // 读取整理阶段写出的产物清单，补足单测/沙箱环境无法递归枚举目录时的 state 文件来源。
    return paths;
  }

  private async buildSourcesConcurrently(statePaths: string[], previousManifest: IndexManifest,
    previousEvents: EventMap, reuseAllowed: boolean, imageReferences: StringArrayMap,
    modelConfig: DataManagerModelConfig, events: EventMap, sources: SourceManifestMap, counters: IndexBuildCounters,
    progress?: DataManagerProgressCallback): Promise<void> {
    if (statePaths.length === 0) {
      return;
    }
    let cursor: IndexSourceCursor = {
      nextIndex: 0
    };
    let workerCount = Math.max(1, Math.min(DEFAULT_INDEX_SOURCE_CONCURRENCY, statePaths.length));
    let workers: Promise<void>[] = [];
    for (let index = 0; index < workerCount; index++) {
      workers.push(this.runSourceIndexWorker(cursor, statePaths, previousManifest, previousEvents, reuseAllowed,
        imageReferences, modelConfig, events, sources, counters, progress));
    }
    await Promise.all(workers);
  }

  private async runSourceIndexWorker(cursor: IndexSourceCursor, statePaths: string[], previousManifest: IndexManifest,
    previousEvents: EventMap, reuseAllowed: boolean, imageReferences: StringArrayMap,
    modelConfig: DataManagerModelConfig, events: EventMap, sources: SourceManifestMap, counters: IndexBuildCounters,
    progress?: DataManagerProgressCallback): Promise<void> {
    while (true) {
      let sourceIndex = cursor.nextIndex;
      cursor.nextIndex++;
      if (sourceIndex >= statePaths.length) {
        return;
      }
      let statePath = statePaths[sourceIndex];
      let relativePath = this.storage.relativePath(this.paths.outputsRoot, statePath);
      let indexPercent = 62 + Math.round(counters.completedSources * 22 / Math.max(1, statePaths.length));
      this.emitProgress(progress, '索引增强', `批量增强 ${relativePath}`, counters.completedSources, statePaths.length,
        indexPercent);
      let result = await this.buildSourceIndex(statePath, relativePath, previousManifest, previousEvents, reuseAllowed,
        imageReferences, modelConfig);
      this.mergeSourceIndexResult(result, events, sources, counters);
      counters.completedSources++;
      this.emitProgress(progress, '索引增强', `已增强 ${counters.completedSources}/${statePaths.length} 个整理文件`,
        counters.completedSources, statePaths.length,
        62 + Math.round(counters.completedSources * 22 / Math.max(1, statePaths.length)));
    }
  }

  private mergeSourceIndexResult(result: IndexSourceBuildResult, events: EventMap, sources: SourceManifestMap,
    counters: IndexBuildCounters): void {
    Object.keys(result.events).forEach((eventId: string) => events[eventId] = result.events[eventId]);
    sources[result.relativePath] = result.sourceEntry;
    counters.reusedEvents += result.reusedEvents;
    counters.enrichedEvents += result.enrichedEvents;
  }

  private orderedSourcesByStatePaths(sources: SourceManifestMap, statePaths: string[]): SourceManifestMap {
    let ordered: SourceManifestMap = {};
    statePaths.forEach((statePath: string) => {
      let relativePath = this.storage.relativePath(this.paths.outputsRoot, statePath);
      if (sources[relativePath]) {
        ordered[relativePath] = sources[relativePath];
      }
    });
    return ordered;
  }

  private async buildSourceIndex(statePath: string, relativePath: string, previousManifest: IndexManifest,
    previousEvents: EventMap, reuseAllowed: boolean, imageReferences: StringArrayMap,
    modelConfig: DataManagerModelConfig): Promise<IndexSourceBuildResult> {
    let content = this.storage.readText(statePath, '');
    let digest = this.storage.sha256Text(content);
    let eventIds: string[] = [];
    let eventInputHashes: StringMap = createStringMap();
    let sourceEvents: EventMap = {};
    let reusedEvents = 0;
    let enrichedEventsCount = 0;
    let previousSource = previousManifest.sources ? previousManifest.sources[relativePath] : undefined;
    let canReuseSource = this.canReuseSource(previousSource, digest, previousEvents);
    if (reuseAllowed && canReuseSource && previousSource) {
      for (let eventId of previousSource.event_ids) {
        let reused = this.copyReusableEvent(previousEvents[eventId], relativePath, imageReferences);
        sourceEvents[reused.event_id] = reused;
        eventIds.push(reused.event_id);
        eventInputHashes[reused.event_id] = this.eventEnrichInputHash(reused);
      }
      reusedEvents += eventIds.length;
      dataManagerInfo(`Index source reused: relative=${relativePath}, events=${eventIds.length}`);
    } else {
      let baseEvents = this.baseEventsFromState(statePath, relativePath, imageReferences);
      dataManagerInfo(`Index source state: relative=${relativePath}, baseEvents=${baseEvents.length}`);
      let eventsById: EventMap = {};
      let eventsToEnrich: IndexedEvent[] = [];
      baseEvents.forEach((event: IndexedEvent) => {
        let inputHash = this.eventEnrichInputHash(event);
        eventInputHashes[event.event_id] = inputHash;
        if (reuseAllowed && this.canReuseEvent(previousSource, event.event_id, inputHash, previousEvents)) {
          eventsById[event.event_id] = this.copyReusableEvent(previousEvents[event.event_id], relativePath, imageReferences);
          reusedEvents++;
        } else {
          eventsToEnrich.push(event);
        }
      });
      let enrichedEvents = await this.modelClient.enrichEvents(eventsToEnrich, modelConfig);
      for (let enriched of enrichedEvents) {
        enriched.profile_domains = deriveProfileDomains(enriched);
        eventsById[enriched.event_id] = enriched;
      }
      baseEvents.forEach((event: IndexedEvent) => {
        let current = eventsById[event.event_id];
        if (!current) {
          return;
        }
        sourceEvents[current.event_id] = current;
        eventIds.push(current.event_id);
      });
      if (eventsToEnrich.length > 0 || baseEvents.length > 0) {
        dataManagerInfo(`Index source event reuse: relative=${relativePath}, reused=${baseEvents.length - eventsToEnrich.length}, enriched=${eventsToEnrich.length}`);
      }
      enrichedEventsCount += enrichedEvents.length;
    }
    let sourceEntry: SourceManifestEntry = {
      sha256: digest,
      event_ids: eventIds,
      event_input_hashes: eventInputHashes
    };
    return {
      relativePath: relativePath,
      sourceEntry: sourceEntry,
      events: sourceEvents,
      reusedEvents: reusedEvents,
      enrichedEvents: enrichedEventsCount
    };
  }

  query(options: QueryOptions): QueryResult {
    let candidateIds = this.queryCandidateIds(options);
    let events = this.loadEventsByIds(candidateIds);
    return this.queryWithEvents(options, events);
  }

  queryWithEvents(options: QueryOptions, events: Record<string, IndexedEvent>): QueryResult {
    let ids = Object.keys(events);
    let keywordOperator = normalizeQueryKeywordOperator(options.keywordOperator);
    let timeScope = this.queryTimeScope(options);
    let includeTodoDeadline = this.includeTodoDeadlineInTimeRange(options, timeScope);
    dataManagerInfo(`Index query: events=${ids.length}, keywords=${options.keywords.join(',')}, keywordOperator=${keywordOperator}, domains=${options.domains.join(',')}, limit=${options.limit}`);
    let matching: BooleanMap = {};
    ids.forEach((id: string) => matching[id] = true);

    if (timeScope.hasTime) {
      ids.forEach((id: string) => {
        matching[id] = matching[id] && this.eventMatchesTimeScope(events[id], timeScope, includeTodoDeadline);
      });
    }

    if (options.keywords.length > 0) {
      let inverted = this.storage.readJson<InvertedDocument>(this.storage.join(this.paths.indexesRoot, 'inverted', 'index.json'), this.emptyInvertedDocument());
      let sourceDocument = this.storage.readJson<SourceDocument>(this.storage.join(this.paths.indexesRoot, 'source', 'index.json'), this.emptySourceDocument());
      let invertedPostings = inverted.postings || {};
      let sourcePostings = sourceDocument.postings || {};
      let keywordMatches: BooleanMap = {};
      if (keywordOperator === 'and') {
        ids.forEach((id: string) => keywordMatches[id] = true);
      }
      for (let keyword of options.keywords) {
        let contentIds = this.indexedTextMatchIds(keyword, events, invertedPostings, eventSearchText);
        let sourceIds = this.indexedTextMatchIds(keyword, events, sourcePostings, sourceSearchText);
        ids.forEach((id: string) => {
          let matched = contentIds[id] === true || sourceIds[id] === true;
          if (keywordOperator === 'or') {
            keywordMatches[id] = keywordMatches[id] === true || matched;
          } else {
            keywordMatches[id] = keywordMatches[id] === true && matched;
          }
        });
      }
      ids.forEach((id: string) => matching[id] = matching[id] && keywordMatches[id] === true);
    }

    if (options.domains.length > 0) {
      let domainDocument = this.storage.readJson<DomainDocument>(this.storage.join(this.paths.indexesRoot, 'domain', 'index.json'), this.emptyDomainDocument());
      let postings = domainDocument.postings || {};
      let domainIds: BooleanMap = {};
      options.domains.forEach((domain: string) => {
        (postings[domain] || []).forEach((id: string) => domainIds[id] = true);
      });
      ids.forEach((id: string) => matching[id] = matching[id] && domainIds[id] === true);
    }

    let workflowSceneIds = normalizeMemorySceneIds(options.workflowSceneIds || []);
    if (workflowSceneIds.length > 0) {
      let selectedScenes = this.setFromNumbers(workflowSceneIds);
      ids.forEach((id: string) => {
        let sceneMatch = false;
        normalizeMemorySceneIds(events[id].workflow_scene_ids || []).forEach((sceneId: number) => {
          if (selectedScenes[String(sceneId)] === true) {
            sceneMatch = true;
          }
        });
        matching[id] = matching[id] && sceneMatch;
      });
    }

    if (options.entities.length > 0) {
      let entityIds = this.entityMatchIds(options.entities);
      ids.forEach((id: string) => matching[id] = matching[id] && entityIds[id] === true);
    }

    let selected = ids
      .filter((id: string) => matching[id])
      .map((id: string) => events[id])
      .sort((left: IndexedEvent, right: IndexedEvent) => {
        let leftSortDate = this.querySortDate(left, includeTodoDeadline);
        let rightSortDate = this.querySortDate(right, includeTodoDeadline);
        if (leftSortDate !== rightSortDate) {
          return rightSortDate.localeCompare(leftSortDate);
        }
        return right.event_id.localeCompare(left.event_id);
      });
    let limit = resolveQueryLimit(selected.length, options.limit);
    return {
      total_events: selected.length,
      events: selected.slice(0, limit).map((event: IndexedEvent) => publicEvent(event)),
      events_truncated: isQueryResultTruncated(selected.length, options.limit)
    };
  }

  loadProfileState(): ProfileState {
    return this.storage.readJson<ProfileState>(this.storage.join(this.paths.indexesRoot, 'profile', 'state.json'), this.emptyProfileState());
  }

  loadProfileMarkdown(): string {
    return this.storage.readText(this.storage.join(this.paths.indexesRoot, 'profile', 'profile.md'), '').trim();
  }

  loadEvents(): EventMap {
    let result: EventMap = {};
    let eventDir = this.storage.join(this.paths.indexesRoot, 'events');
    this.eventPartitionNames()
      .forEach((name: string) => {
        let partition = this.storage.readJson<EventPartition>(this.storage.join(eventDir, name), { month: '', events: [] });
        if (partition && Array.isArray(partition.events)) {
          partition.events.forEach((event: IndexedEvent) => {
            result[event.event_id] = this.copyEvent(event);
          });
        }
      });
    return result;
  }

  loadEventsByIds(eventIds: string[]): EventMap {
    let result: EventMap = {};
    let uniqueIds = stableUnique(eventIds);
    if (uniqueIds.length === 0) {
      return result;
    }
    let wanted: BooleanMap = {};
    uniqueIds.forEach((id: string) => wanted[id] = true);
    let eventDir = this.storage.join(this.paths.indexesRoot, 'events');
    let months = this.eventMonthsForIds(wanted);
    let loadedPartitions: BooleanMap = {};
    let partitionNames = months.length > 0 ? months.map((month: string) => month + '.json') :
      this.eventPartitionNames();
    partitionNames.forEach((name: string) => {
      loadedPartitions[name] = true;
      this.readWantedEventsFromPartition(this.storage.join(eventDir, name), wanted, result);
    });
    if (Object.keys(result).length < uniqueIds.length) {
      this.eventPartitionNames()
        .filter((name: string) => loadedPartitions[name] !== true)
        .forEach((name: string) => this.readWantedEventsFromPartition(this.storage.join(eventDir, name), wanted, result));
    }
    return result;
  }

  private eventPartitionNames(): string[] {
    let eventDir = this.storage.join(this.paths.indexesRoot, 'events');
    let names = this.storage.listDir(eventDir)
      .filter((name: string) => name.endsWith('.json') && name !== EVENT_PARTITION_INDEX_FILE_NAME);
    let partitionIndex = this.storage.readJson<JsonMap>(this.storage.join(eventDir, EVENT_PARTITION_INDEX_FILE_NAME), createJsonMap());
    let value = partitionIndex['partition_files'];
    if (Array.isArray(value)) {
      names = names.concat((value as string[]).map((item: string): string => normalizeFreeText(item)));
    }
    // 事件分区按月写入，清单用于目录枚举不可用的环境；只保留分区文件名，排除清单自身。
    return stableUnique(names)
      .filter((name: string) => /^\d{4}-\d{2}\.json$/.test(name))
      .sort();
  }

  loadHomeTodoCandidateEvents(today: string, noDeadlineRecentDays: number): EventMap {
    let document = this.storage.readJson<HomeTodoDocument>(
      this.storage.join(this.paths.indexesRoot, 'home-todo', 'index.json'), this.emptyHomeTodoDocument());
    let deadlineEventIds: string[] = [];
    let deadlinePostings = document.deadline_postings || {};
    Object.keys(deadlinePostings).sort().forEach((deadline: string) => {
      if (isIsoDate(deadline) && isIsoDate(today) && deadline >= today) {
        deadlineEventIds = deadlineEventIds.concat(deadlinePostings[deadline] || []);
      }
    });
    let result = this.loadEventsByIds(stableUnique(deadlineEventIds));
    let noDeadlineEvents = this.loadEventsByIds(stableUnique(document.no_deadline_event_ids || []));
    Object.keys(noDeadlineEvents).forEach((eventId: string) => {
      let event = noDeadlineEvents[eventId];
      if (isRecentNoDeadlineHomeTodoEvent(event.event_date, today, noDeadlineRecentDays)) {
        result[eventId] = event;
      }
    });
    return result;
  }

  private queryCandidateIds(options: QueryOptions): string[] {
    let candidate: BooleanMap | null = null;
    let timeScope = this.queryTimeScope(options);
    let temporalIds = this.temporalCandidateIds(options);
    if (temporalIds !== null) {
      let timeIds = temporalIds;
      if (this.includeTodoDeadlineInTimeRange(options, timeScope)) {
        timeIds = this.unionCandidates(timeIds, this.todoDeadlineCandidateIds(timeScope));
      }
      candidate = this.intersectCandidate(candidate, timeIds);
    }

    if (options.keywords.length > 0) {
      let inverted = this.storage.readJson<InvertedDocument>(this.storage.join(this.paths.indexesRoot, 'inverted', 'index.json'), this.emptyInvertedDocument());
      let sourceDocument = this.storage.readJson<SourceDocument>(this.storage.join(this.paths.indexesRoot, 'source', 'index.json'), this.emptySourceDocument());
      let invertedPostings = inverted.postings || {};
      let sourcePostings = sourceDocument.postings || {};
      let keywordOperator = normalizeQueryKeywordOperator(options.keywordOperator);
      let keywordCandidate: BooleanMap | null = null;
      for (let keyword of options.keywords) {
        let keywordIds = this.keywordCandidateIds(keyword, invertedPostings, sourcePostings);
        if (keywordIds !== null) {
          if (keywordOperator === 'or') {
            keywordCandidate = this.unionCandidates(keywordCandidate, keywordIds);
          } else {
            keywordCandidate = this.intersectCandidate(keywordCandidate, keywordIds);
          }
        }
      }
      if (keywordCandidate !== null) {
        candidate = this.intersectCandidate(candidate, keywordCandidate);
      }
    }

    if (options.domains.length > 0) {
      let domainDocument = this.storage.readJson<DomainDocument>(this.storage.join(this.paths.indexesRoot, 'domain', 'index.json'), this.emptyDomainDocument());
      let postings = domainDocument.postings || {};
      let domainIds: BooleanMap = {};
      options.domains.forEach((domain: string) => {
        (postings[domain] || []).forEach((id: string) => domainIds[id] = true);
      });
      candidate = this.intersectCandidate(candidate, domainIds);
    }

    let workflowSceneIds = normalizeMemorySceneIds(options.workflowSceneIds || []);
    if (workflowSceneIds.length > 0) {
      let sceneDocument = this.storage.readJson<WorkflowSceneDocument>(this.storage.join(this.paths.indexesRoot, 'workflow-scene', 'index.json'), this.emptyWorkflowSceneDocument());
      let postings = sceneDocument.postings || {};
      let selectedScenes = this.setFromNumbers(workflowSceneIds);
      let sceneIds: BooleanMap = {};
      Object.keys(postings).forEach((sceneKey: string) => {
        let numericSceneId = Number(sceneKey);
        if (isNaN(numericSceneId) || selectedScenes[String(normalizeMemorySceneId(numericSceneId))] !== true) {
          return;
        }
        (postings[sceneKey] || []).forEach((id: string) => sceneIds[id] = true);
      });
      candidate = this.intersectCandidate(candidate, sceneIds);
    }

    if (options.entities.length > 0) {
      candidate = this.intersectCandidate(candidate, this.entityMatchIds(options.entities));
    }

    if (candidate === null) {
      return this.allEventIds();
    }
    return Object.keys(candidate).filter((id: string) => candidate![id] === true).sort();
  }

  private keywordCandidateIds(keyword: string, invertedPostings: StringArrayMap, sourcePostings: StringArrayMap): BooleanMap | null {
    let contentIds = this.postingCandidateIds(keyword, invertedPostings);
    let sourceIds = this.postingCandidateIds(keyword, sourcePostings);
    if (contentIds === null && sourceIds === null) {
      return null;
    }
    return this.unionCandidates(contentIds, sourceIds);
  }

  private postingCandidateIds(keyword: string, postings: StringArrayMap): BooleanMap | null {
    let compactKeyword = normalizeLookupText(keyword);
    if (compactKeyword.length === 0) {
      return null;
    }
    let terms = indexTerms(compactKeyword);
    if (terms.length === 0) {
      return null;
    }
    let candidate: BooleanMap | null = null;
    terms.forEach((term: string) => {
      candidate = this.intersectCandidate(candidate, this.setFromIds(postings[term] || []));
    });
    return candidate === null ? {} : candidate;
  }

  private temporalCandidateIds(options: QueryOptions): BooleanMap | null {
    let scope = this.queryTimeScope(options);
    if (!scope.hasTime) {
      return null;
    }
    let documents = this.loadTemporalDocuments();
    if (Object.keys(documents).length === 0) {
      return null;
    }
    if (options.date.length > 0) {
      return this.setFromIds(this.eventIdsForDate(options.date, documents));
    }
    if (options.month.length > 0) {
      let document = documents[options.month];
      return this.setFromIds(document ? (document.event_ids || []) : []);
    }
    let ids: string[] = [];
    Object.keys(documents).sort().forEach((month: string) => {
      let document = documents[month];
      let days = this.temporalDays(document);
      if (days.length === 0) {
        if (this.monthOverlapsRange(month, scope.lower, scope.upper)) {
          ids = ids.concat(document.event_ids || []);
        }
        return;
      }
      days.forEach((day: TemporalDayNode) => {
        if (day.date >= scope.lower && day.date <= scope.upper) {
          ids = ids.concat(day.event_ids || []);
        }
      });
    });
    return this.setFromIds(ids);
  }

  private queryTimeScope(options: QueryOptions): QueryTimeScope {
    if (options.date.length > 0) {
      return {
        hasTime: true,
        lower: options.date,
        upper: options.date
      };
    }
    if (options.month.length > 0) {
      return {
        hasTime: true,
        lower: options.month + '-01',
        upper: this.monthLastDate(options.month)
      };
    }
    if (options.startDate.length > 0 || options.endDate.length > 0) {
      return {
        hasTime: true,
        lower: options.startDate.length > 0 ? options.startDate : '0000-01-01',
        upper: options.endDate.length > 0 ? options.endDate : '9999-12-31'
      };
    }
    return {
      hasTime: false,
      lower: '',
      upper: ''
    };
  }

  private includeTodoDeadlineInTimeRange(options: QueryOptions, scope: QueryTimeScope): boolean {
    return options.includeTodoDeadlineInTimeRange === true && scope.hasTime;
  }

  private eventMatchesTimeScope(event: IndexedEvent, scope: QueryTimeScope, includeTodoDeadline: boolean): boolean {
    if (!scope.hasTime) {
      return true;
    }
    if (event.event_date >= scope.lower && event.event_date <= scope.upper) {
      return true;
    }
    if (!includeTodoDeadline) {
      return false;
    }
    let deadline = normalizeFreeText(event.todo.deadline);
    return isIsoDate(deadline) && deadline >= scope.lower && deadline <= scope.upper;
  }

  private querySortDate(event: IndexedEvent, preferTodoDeadline: boolean): string {
    let deadline = normalizeFreeText(event.todo.deadline);
    if (preferTodoDeadline && isIsoDate(deadline)) {
      return deadline;
    }
    return event.event_date;
  }

  private todoDeadlineCandidateIds(scope: QueryTimeScope): BooleanMap {
    if (!scope.hasTime) {
      return {};
    }
    let document = this.storage.readJson<HomeTodoDocument>(
      this.storage.join(this.paths.indexesRoot, 'home-todo', 'index.json'), this.emptyHomeTodoDocument());
    let ids: string[] = [];
    let deadlinePostings = document.deadline_postings || {};
    Object.keys(deadlinePostings).sort().forEach((deadline: string) => {
      if (isIsoDate(deadline) && deadline >= scope.lower && deadline <= scope.upper) {
        ids = ids.concat(deadlinePostings[deadline] || []);
      }
    });
    return this.setFromIds(stableUnique(ids));
  }

  private eventIdsForDate(date: string, documents: TemporalDocumentMap): string[] {
    let month = monthKeyFromDate(date);
    if (month.length === 0) {
      return [];
    }
    let document = documents[month];
    if (!document) {
      return [];
    }
    let ids: string[] = [];
    this.temporalDays(document).forEach((day: TemporalDayNode) => {
      if (day.date === date) {
        ids = ids.concat(day.event_ids || []);
      }
    });
    return ids;
  }

  private temporalDays(document: TemporalDocument): TemporalDayNode[] {
    let days: TemporalDayNode[] = [];
    (document.weeks || []).forEach((week: TemporalWeekNode) => {
      days = days.concat(week.days || []);
    });
    return days;
  }

  private monthOverlapsRange(month: string, lower: string, upper: string): boolean {
    let first = month + '-01';
    let last = this.monthLastDate(month);
    return first <= upper && last >= lower;
  }

  private allEventIds(): string[] {
    let documents = this.loadTemporalDocuments();
    let ids: string[] = [];
    Object.keys(documents).sort().forEach((month: string) => {
      ids = ids.concat(documents[month].event_ids || []);
    });
    ids = stableUnique(ids).sort();
    return ids.length > 0 ? ids : Object.keys(this.loadEvents()).sort();
  }

  private eventMonthsForIds(wanted: BooleanMap): string[] {
    let documents = this.loadTemporalDocuments();
    let months: string[] = [];
    Object.keys(documents).sort().forEach((month: string) => {
      let document = documents[month];
      for (let id of document.event_ids || []) {
        if (wanted[id] === true) {
          months.push(month);
          break;
        }
      }
    });
    return stableUnique(months).sort();
  }

  private readWantedEventsFromPartition(path: string, wanted: BooleanMap, out: EventMap): void {
    let partition = this.storage.readJson<EventPartition>(path, { month: '', events: [] });
    if (!partition || !Array.isArray(partition.events)) {
      return;
    }
    partition.events.forEach((event: IndexedEvent) => {
      if (wanted[event.event_id] === true) {
        out[event.event_id] = this.copyEvent(event);
      }
    });
  }

  private setFromIds(ids: string[]): BooleanMap {
    let result: BooleanMap = {};
    ids.forEach((id: string) => result[id] = true);
    return result;
  }

  private setFromNumbers(values: number[]): BooleanMap {
    let result: BooleanMap = {};
    values.forEach((value: number) => result[String(value)] = true);
    return result;
  }

  private intersectCandidate(left: BooleanMap | null, right: BooleanMap): BooleanMap {
    if (left === null) {
      return this.setFromIds(Object.keys(right).filter((id: string) => right[id] === true));
    }
    let result: BooleanMap = {};
    Object.keys(left).forEach((id: string) => {
      if (left[id] === true && right[id] === true) {
        result[id] = true;
      }
    });
    return result;
  }

  private unionCandidates(left: BooleanMap | null, right: BooleanMap | null): BooleanMap {
    let result: BooleanMap = {};
    if (left !== null) {
      Object.keys(left).forEach((id: string) => {
        if (left[id] === true) {
          result[id] = true;
        }
      });
    }
    if (right !== null) {
      Object.keys(right).forEach((id: string) => {
        if (right[id] === true) {
          result[id] = true;
        }
      });
    }
    return result;
  }

  private currentEnrichment(modelConfig: DataManagerModelConfig): EnrichmentManifest {
    let enrichment: EnrichmentManifest = {
      schema: 'todo_signal_agent_task',
      mode: modelConfig.enabled ? 'model' : 'heuristic',
      base_url: modelConfig.baseUrl
    };
    return enrichment;
  }

  private loadManifest(): IndexManifest {
    return this.storage.readJson<IndexManifest>(this.storage.join(this.paths.indexesRoot, 'manifest.json'), this.emptyManifest());
  }

  private canReuseIndex(previousManifest: IndexManifest, enrichment: EnrichmentManifest): boolean {
    if (!previousManifest || !previousManifest.enrichment || !previousManifest.sources) {
      return false;
    }
    return previousManifest.input_root === 'workflows/profile-consolidation/outputs' &&
      previousManifest.index_dir === 'workflows/profile-consolidation/indexes' &&
      previousManifest.enrichment.schema === enrichment.schema &&
      previousManifest.enrichment.mode === enrichment.mode &&
      previousManifest.enrichment.base_url === enrichment.base_url &&
      this.sameStringArrays(previousManifest.entity_types || [], ENTITY_TYPE_KEYS);
  }

  private canReuseSource(previousSource: SourceManifestEntry | undefined, digest: string, previousEvents: EventMap): boolean {
    if (!previousSource || previousSource.sha256 !== digest || !Array.isArray(previousSource.event_ids) || previousSource.event_ids.length === 0 ||
      !previousSource.event_input_hashes) {
      return false;
    }
    for (let eventId of previousSource.event_ids) {
      if (!previousEvents[eventId] || normalizeFreeText(previousSource.event_input_hashes[eventId]).length === 0) {
        return false;
      }
    }
    return true;
  }

  private canReuseEvent(previousSource: SourceManifestEntry | undefined, eventId: string, currentInputHash: string, previousEvents: EventMap): boolean {
    if (!previousSource || !previousSource.event_input_hashes) {
      return false;
    }
    return isEventEnrichInputReusable(previousSource.event_input_hashes[eventId], currentInputHash, previousEvents[eventId] !== undefined);
  }

  private sameStringArrays(left: string[], right: string[]): boolean {
    if (left.length !== right.length) {
      return false;
    }
    for (let index = 0; index < left.length; index++) {
      if (left[index] !== right[index]) {
        return false;
      }
    }
    return true;
  }

  private copyEvent(event: IndexedEvent): IndexedEvent {
    let copied: IndexedEvent = {
      event_id: event.event_id,
      source_state_file: event.source_state_file,
      record_id: event.record_id,
      event_date: event.event_date,
      last_seen_date: event.last_seen_date,
      summary: event.summary,
      normalized_fact: event.normalized_fact,
      tags: (event.tags || []).slice(),
      source_refs: (event.source_refs || []).slice(),
      sources: (event.sources || []).slice(),
      workflow_scene_ids: normalizeMemorySceneIds(event.workflow_scene_ids || []),
      image_paths: (event.image_paths || []).slice(),
      todo: this.copyTodo(event.todo || this.emptyTodo()),
      keywords: (event.keywords || []).slice(),
      domains: (event.domains || []).slice(),
      entity_mentions: (event.entity_mentions || []).slice(),
      enrichment_method: event.enrichment_method,
      entities: (event.entities || []).slice(),
      profile_domains: (event.profile_domains || []).slice()
    };
    return copied;
  }

  private copyReusableEvent(event: IndexedEvent, relativePath: string, imageReferences: StringArrayMap): IndexedEvent {
    let reused = this.copyEvent(event);
    reused.sources = eventSourceNames(reused.source_refs || [], relativePath);
    reused.image_paths = this.imagePathsForSourceRefs(reused.source_refs || [], imageReferences);
    reused.profile_domains = deriveProfileDomains(reused);
    return reused;
  }

  private eventEnrichInputHash(event: IndexedEvent): string {
    return this.storage.sha256Text(eventEnrichInputFingerprint(event));
  }

  private emptyTodo(): IndexedEventTodo {
    return {
      type: '',
      deadline: '',
      text: '',
      agent_task: ''
    };
  }

  private copyTodo(todo: IndexedEventTodo): IndexedEventTodo {
    let type = normalizeFreeText(todo.type);
    let deadline = isIsoDate(normalizeFreeText(todo.deadline)) ? normalizeFreeText(todo.deadline) : '';
    let text = normalizeFreeText(todo.text);
    let agentTask = normalizeFreeText(todo.agent_task);
    if (type.length === 0 && deadline.length === 0) {
      return this.emptyTodo();
    }
    let copied: IndexedEventTodo = {
      type: type,
      deadline: deadline,
      text: text,
      agent_task: agentTask
    };
    return copied;
  }

  private baseEventsFromState(statePath: string, relativePath: string, imageReferences: StringArrayMap): IndexedEvent[] {
    let state = this.storage.readJson<ConsolidatedState>(statePath, this.emptyConsolidatedState());
    let events: IndexedEvent[] = [];
    if (!state || !Array.isArray(state.records)) {
      return events;
    }
    for (let record of state.records) {
      if (!this.isValidRecord(record)) {
        continue;
      }
      let eventId = `${relativePath}#${record.record_id}`;
      let eventDate = isIsoDate(record.first_seen_date) ? record.first_seen_date : '';
      if (eventDate.length === 0) {
        continue;
      }
      let lastSeenDate = isIsoDate(record.last_seen_date) ? record.last_seen_date : eventDate;
      events.push({
        event_id: eventId,
        source_state_file: relativePath,
        record_id: record.record_id,
        event_date: eventDate,
        last_seen_date: lastSeenDate,
        summary: normalizeFreeText(record.summary || record.normalized_fact),
        normalized_fact: normalizeFreeText(record.normalized_fact),
        tags: stableUnique(record.tags || []),
        source_refs: stableUnique(record.source_refs || []),
        sources: eventSourceNames(record.source_refs || [], relativePath),
        workflow_scene_ids: normalizeMemorySceneIds(stableUniqueNumbers(record.workflow_scene_ids || [])),
        image_paths: this.imagePathsForSourceRefs(record.source_refs || [], imageReferences),
        todo: this.emptyTodo(),
        keywords: [],
        domains: [],
        entity_mentions: [],
        enrichment_method: '',
        entities: [],
        profile_domains: []
      });
    }
    return events;
  }

  private buildImageReferenceMap(): StringArrayMap {
    let candidates: ImageReferenceCandidateMap = new Object() as ImageReferenceCandidateMap;
    this.storage.listDir(this.paths.workflowRunsRoot).forEach((runName: string) => {
      let summaryPath = this.storage.join(this.paths.workflowRunsRoot, runName, 'run_summary.json');
      if (!this.storage.exists(summaryPath)) {
        return;
      }
      let payload = this.storage.readJson<JsonMap>(summaryPath, new Object() as JsonMap);
      let stepsValue = payload['steps'];
      if (!stepsValue || typeof stepsValue !== 'object') {
        return;
      }
      let steps = stepsValue as Record<string, JsonMap>;
      let stepKeys = Object.keys(steps);
      stepKeys.forEach((stepKey: string) => {
        let step = steps[stepKey];
        let outputValue = step['output'];
        if (!outputValue || typeof outputValue !== 'object') {
          return;
        }
        let output = outputValue as JsonMap;
        if (normalizeFreeText(output['tool_name']) !== 'vlm_qa' || normalizeFreeText(output['mode']) !== 'summary') {
          return;
        }
        let logRelative = this.pathAfterDirectory(output['daily_log_path'], 'daily-log');
        let imagePath = this.workflowImageReferenceForToolOutput(output, runName, stepKey, steps, stepKeys);
        let summary = this.summaryOutputText(output);
        if (logRelative.length === 0 || imagePath.length === 0 || summary.length === 0) {
          return;
        }
        if (!candidates[logRelative]) {
          candidates[logRelative] = [];
        }
        candidates[logRelative].push({
          summary: summary,
          image_path: imagePath,
          used: false
        });
      });
    });

    let imageReferences: StringArrayMap = new Object() as StringArrayMap;
    this.storage.listDir(this.paths.dailyLogRoot)
      .filter((day: string) => /^\d{4}-\d{2}-\d{2}$/.test(day))
      .forEach((day: string) => {
        let dayDir = this.storage.join(this.paths.dailyLogRoot, day);
        this.storage.listDir(dayDir)
          .filter((name: string) => name.endsWith('.md'))
          .forEach((fileName: string) => {
            let relative = day + '/' + fileName;
            let available = candidates[relative] || [];
            if (available.length === 0) {
              return;
            }
            let text = this.storage.readText(this.storage.join(dayDir, fileName), '');
            let body = text.indexOf('-->') >= 0 ? text.substring(text.indexOf('-->') + 3) : text;
            parseNumberedEntries(body).forEach((entry: NumberedEntry) => {
              let entryText = normalizeFreeText(entry.text);
              for (let candidate of available) {
                if (!candidate.used && this.summaryTextsMatch(candidate.summary, entryText)) {
                  candidate.used = true;
                  imageReferences[relative + '#' + entry.index] = [candidate.image_path];
                  break;
                }
              }
            });
          });
      });
    return imageReferences;
  }

  private workflowImageReferenceForToolOutput(output: JsonMap, runName: string, stepKey: string,
    steps: Record<string, JsonMap>, stepKeys: string[]): string {
    let directImage = this.workflowImageRelativePath(output['image'], runName);
    if (directImage.length > 0) {
      return directImage;
    }
    let directImagePath = this.workflowImageRelativePath(output['image_path'], runName);
    if (directImagePath.length > 0) {
      return directImagePath;
    }
    return this.nearestScreenshotImageReference(runName, stepKey, steps, stepKeys);
  }

  private pathAfterDirectory(value: Object | string | number | boolean | null | undefined, directoryName: string): string {
    let normalized = normalizeFreeText(value).replace(/\\/g, '/');
    if (normalized.length === 0) {
      return '';
    }
    let parts = normalized.split('/').filter((part: string) => part.length > 0);
    let position = -1;
    for (let index = 0; index < parts.length; index++) {
      if (parts[index] === directoryName) {
        position = index;
      }
    }
    if (position < 0 || position >= parts.length - 1) {
      return '';
    }
    return parts.slice(position + 1).join('/');
  }

  private workflowImageRelativePath(value: Object | string | number | boolean | null | undefined, runName: string): string {
    let pathText = normalizeFreeText(value).replace(/\\/g, '/');
    if (pathText.length === 0) {
      return '';
    }
    let marker = '/' + runName + '/';
    if (pathText.indexOf(marker) >= 0) {
      let relative = 'runs/' + runName + '/' + pathText.split(marker)[1];
      return this.storage.exists(this.paths.fromDataManagerRelative(relative)) ? relative : '';
    }
    let workflowMarker = '/workflows/';
    if (pathText.indexOf(workflowMarker) >= 0) {
      let relative = pathText.split(workflowMarker)[1];
      return this.storage.exists(this.paths.fromDataManagerRelative(relative)) ? relative : '';
    }
    return '';
  }

  private nearestScreenshotImageReference(runName: string, toolStepKey: string,
    steps: Record<string, JsonMap>, stepKeys: string[]): string {
    let toolStep = steps[toolStepKey];
    let toolStarted = this.stepTime(toolStep, 'started_at');
    let toolOrder = this.stepOrder(toolStepKey, stepKeys);
    let toolScope = this.stepScope(toolStepKey);
    let bestReference = '';
    let bestSameScope = false;
    let bestScore = -1;
    for (let index = 0; index < stepKeys.length; index++) {
      let candidateKey = stepKeys[index];
      if (candidateKey === toolStepKey) {
        continue;
      }
      let candidateStep = steps[candidateKey];
      let output = this.stepOutputMap(candidateStep);
      if (output === null) {
        continue;
      }
      let reference = this.screenshotImageReference(runName, candidateKey, output);
      if (reference.length === 0) {
        continue;
      }
      let candidateFinished = this.stepTime(candidateStep, 'finished_at');
      let candidateStarted = this.stepTime(candidateStep, 'started_at');
      let candidateOrder = this.stepOrder(candidateKey, stepKeys);
      let beforeTool = false;
      if (toolStarted > 0 && candidateFinished > 0) {
        beforeTool = candidateFinished <= toolStarted;
      } else if (toolStarted > 0 && candidateStarted > 0) {
        beforeTool = candidateStarted <= toolStarted;
      } else {
        beforeTool = candidateOrder < toolOrder;
      }
      if (!beforeTool) {
        continue;
      }
      let sameScope = this.stepScope(candidateKey) === toolScope;
      let score = candidateFinished > 0 ? candidateFinished : candidateOrder;
      if (bestReference.length === 0 || (sameScope && !bestSameScope) ||
        (sameScope === bestSameScope && score > bestScore)) {
        bestReference = reference;
        bestSameScope = sameScope;
        bestScore = score;
      }
    }
    return bestReference;
  }

  private screenshotImageReference(runName: string, stepKey: string, output: JsonMap): string {
    if (normalizeFreeText(output['action']) !== 'screenshot') {
      return '';
    }
    let directImagePath = this.workflowImageRelativePath(output['image_path'], runName);
    if (directImagePath.length > 0) {
      return directImagePath;
    }
    if (normalizeFreeText(output['image_b64']).length > 0) {
      return 'runs/' + runName + '/run_summary.json#steps/' + stepKey + '/output/image_b64';
    }
    if (normalizeFreeText(output['image_path']).length > 0) {
      return 'runs/' + runName + '/run_summary.json#steps/' + stepKey + '/output/image_path';
    }
    return '';
  }

  private stepOutputMap(step: JsonMap): JsonMap | null {
    let output = step['output'];
    if (!output || typeof output !== 'object') {
      return null;
    }
    return output as JsonMap;
  }

  private stepTime(step: JsonMap, key: string): number {
    let value = step[key];
    return typeof value === 'number' ? value : 0;
  }

  private stepOrder(stepKey: string, stepKeys: string[]): number {
    for (let index = 0; index < stepKeys.length; index++) {
      if (stepKeys[index] === stepKey) {
        return index;
      }
    }
    return -1;
  }

  private stepScope(stepKey: string): string {
    let index = stepKey.lastIndexOf('.');
    return index > 0 ? stepKey.substring(0, index) : '';
  }

  private summaryOutputText(output: JsonMap): string {
    let structured = output['structured_output'];
    if (structured && typeof structured === 'object') {
      let structuredMap = structured as JsonMap;
      let summary = normalizeFreeText(structuredMap['summary']);
      if (summary.length > 0) {
        return summary;
      }
    }
    return normalizeFreeText(output['response']);
  }

  private summaryTextsMatch(left: string, right: string): boolean {
    let leftKeys = this.summaryTextKeys(left);
    let rightKeys = this.summaryTextKeys(right);
    for (let leftKey of leftKeys) {
      for (let rightKey of rightKeys) {
        if (leftKey === rightKey) {
          return true;
        }
      }
    }
    return false;
  }

  private summaryTextKeys(value: Object | string | number | boolean | null | undefined): string[] {
    let raw = normalizeFreeText(value);
    let keys: string[] = [];
    if (raw.length > 0) {
      keys.push(raw);
    }
    let jsonSummary = this.summaryFromJsonText(raw);
    if (jsonSummary.length > 0) {
      keys.push(jsonSummary);
    }
    return stableUnique(keys);
  }

  private summaryFromJsonText(raw: string): string {
    let text = raw.trim();
    if (text.length === 0) {
      return '';
    }
    let block = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
    if (block && block.length > 1) {
      text = block[1].trim();
    }
    text = text.replace(/^```(?:json)?\s*/i, '');
    text = text.replace(/\s*```$/, '');
    let start = text.indexOf('{');
    let end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
    try {
      let parsed = ArkJSON.parse(text) as JsonMap;
      if (parsed && typeof parsed === 'object') {
        return normalizeFreeText(parsed['summary']);
      }
    } catch (e) {
    }
    return '';
  }

  private imagePathsForSourceRefs(sourceRefs: string[], imageReferences: StringArrayMap): string[] {
    let paths: string[] = [];
    sourceRefs.forEach((sourceRef: string) => {
      paths = paths.concat(imageReferences[sourceRef] || []);
    });
    paths = paths.concat(GalleryMemorySync.imageRefsForSourceRefs(this.paths.filesDir, this.paths.dailyLogRoot, sourceRefs));
    return stableUnique(paths);
  }

  private isValidRecord(record: AggregatedRecord): boolean {
    return record && typeof record.record_id === 'number' &&
      normalizeFreeText(record.summary || record.normalized_fact).length > 0 &&
      normalizeFreeText(record.normalized_fact).length > 0;
  }

  private writeEventPartitions(events: EventMap): void {
    let partitions: EventGroupMap = {};
    Object.keys(events).forEach((eventId: string) => {
      let event = events[eventId];
      let month = monthKeyFromDate(event.event_date);
      if (month.length === 0) {
        return;
      }
      if (!partitions[month]) {
        partitions[month] = [];
      }
      partitions[month].push(event);
    });
    let desired: ObjectMap = {};
    Object.keys(partitions).sort().forEach((month: string) => {
      let monthEvents = partitions[month].sort((left: IndexedEvent, right: IndexedEvent) => {
        if (left.event_date !== right.event_date) {
          return left.event_date.localeCompare(right.event_date);
        }
        return left.event_id.localeCompare(right.event_id);
      });
      let partition: EventPartition = {
        month: month,
        events: monthEvents
      };
      desired[month + '.json'] = partition as Object;
    });
    let partitionIndex: EventPartitionIndex = {
      schema: 'datamanager-event-partition-index-v1',
      generated_at: nowIsoLocal(),
      partition_files: Object.keys(partitions).sort().map((month: string): string => month + '.json')
    };
    // 记录事件分区清单，避免查询阶段因目录枚举失败而读不到刚写入的图库事件。
    desired[EVENT_PARTITION_INDEX_FILE_NAME] = partitionIndex as Object;
    this.storage.syncJsonDirectory(this.storage.join(this.paths.indexesRoot, 'events'), desired);
  }

  private buildInvertedDocument(events: EventMap): InvertedDocument {
    let postings: StringArrayMap = {};
    Object.keys(events).forEach((eventId: string) => {
      indexTerms(eventSearchText(events[eventId])).forEach((term: string) => {
        if (!postings[term]) {
          postings[term] = [];
        }
        postings[term].push(eventId);
      });
    });
    Object.keys(postings).forEach((term: string) => postings[term] = stableUnique(postings[term]).sort());
    let document: InvertedDocument = {
      postings: postings
    };
    return document;
  }

  private buildSourceDocument(events: EventMap): SourceDocument {
    let postings: StringArrayMap = {};
    Object.keys(events).forEach((eventId: string) => {
      let event = events[eventId];
      indexTerms(sourceSearchText(event)).forEach((term: string) => {
        if (!postings[term]) {
          postings[term] = [];
        }
        postings[term].push(eventId);
      });
    });
    Object.keys(postings).forEach((term: string) => postings[term] = stableUnique(postings[term]).sort());
    let document: SourceDocument = {
      postings: postings
    };
    return document;
  }

  private buildHomeTodoDocument(events: EventMap): HomeTodoDocument {
    let deadlinePostings: StringArrayMap = {};
    let typePostings: StringArrayMap = {};
    let noDeadlineEvents: IndexedEvent[] = [];
    let chatSceneIds = this.chatSceneIds();
    Object.keys(events).forEach((eventId: string) => {
      let event = events[eventId];
      let todo = this.copyTodo(event.todo);
      if (!isHomeTodoIndexCandidate(todo, event.workflow_scene_ids || [], chatSceneIds)) {
        return;
      }
      if (todo.type.length > 0) {
        if (!typePostings[todo.type]) {
          typePostings[todo.type] = [];
        }
        typePostings[todo.type].push(eventId);
      }
      if (isIsoDate(todo.deadline)) {
        if (!deadlinePostings[todo.deadline]) {
          deadlinePostings[todo.deadline] = [];
        }
        deadlinePostings[todo.deadline].push(eventId);
      } else {
        noDeadlineEvents.push(event);
      }
    });
    Object.keys(deadlinePostings).forEach((deadline: string) => deadlinePostings[deadline] = stableUnique(deadlinePostings[deadline]).sort());
    Object.keys(typePostings).forEach((type: string) => typePostings[type] = stableUnique(typePostings[type]).sort());
    noDeadlineEvents.sort((left: IndexedEvent, right: IndexedEvent) => {
      if (left.event_date !== right.event_date) {
        return right.event_date.localeCompare(left.event_date);
      }
      return right.event_id.localeCompare(left.event_id);
    });
    let document: HomeTodoDocument = {
      deadline_postings: deadlinePostings,
      no_deadline_event_ids: noDeadlineEvents.map((event: IndexedEvent): string => event.event_id),
      type_postings: typePostings
    };
    return document;
  }

  private chatSceneIds(): number[] {
    let ids: number[] = [];
    workflowSceneConfigs().forEach((scene: WorkflowSceneConfig) => {
      if (scene.tabId === 'chat') {
        ids.push(scene.sceneId);
      }
    });
    return ids;
  }

  private buildDomainDocument(events: EventMap): DomainDocument {
    let postings: StringArrayMap = {};
    DOMAIN_KEYS.forEach((domain: string) => postings[domain] = []);
    Object.keys(events).forEach((eventId: string) => {
      let domains = normalizeDomains(events[eventId].domains || []);
      if (domains.length === 0) {
        domains = ['other'];
      }
      domains.forEach((domain: string) => {
        if (!postings[domain]) {
          postings[domain] = [];
        }
        postings[domain].push(eventId);
      });
    });
    Object.keys(postings).forEach((domain: string) => postings[domain] = stableUnique(postings[domain]).sort());
    let document: DomainDocument = {
      postings: postings
    };
    return document;
  }

  private buildWorkflowSceneDocument(events: EventMap): WorkflowSceneDocument {
    let postings: StringArrayMap = {};
    memorySceneConfigs().forEach((scene: WorkflowSceneConfig) => {
      let key = String(scene.sceneId);
      postings[key] = [];
    });
    Object.keys(events).sort().forEach((eventId: string) => {
      let sceneIds = normalizeMemorySceneIds(stableUniqueNumbers(events[eventId].workflow_scene_ids || []));
      sceneIds.forEach((sceneId: number) => {
        let key = String(sceneId);
        if (!postings[key]) {
          postings[key] = [];
        }
        postings[key].push(eventId);
      });
    });
    Object.keys(postings).forEach((sceneId: string) => postings[sceneId] = stableUnique(postings[sceneId]).sort());
    let document: WorkflowSceneDocument = {
      postings: postings
    };
    return document;
  }

  private async buildEntityDocument(events: EventMap, modelConfig: DataManagerModelConfig,
    previousDocument?: EntityDocument, incrementalAllowed?: boolean): Promise<EntityDocument> {
    let catalog = this.buildEntityMentionCatalog(events);
    if (incrementalAllowed && previousDocument) {
      return await this.buildIncrementalEntityDocument(events, catalog, previousDocument, modelConfig);
    }
    return await this.buildFullEntityDocument(events, catalog, modelConfig);
  }

  private buildEntityMentionCatalog(events: EventMap): EntityMentionCatalogByType {
    let mentionsByType = this.emptyEntityMentionCatalog();
    Object.keys(events).sort().forEach((eventId: string) => {
      let event = events[eventId];
      let mentions = normalizeEntityMentions(event.entity_mentions || []);
      event.entity_mentions = mentions;
      mentions.forEach((mention: EntityMention) => {
        let token = this.entityNameToken(mention.name);
        let mentionMap = mentionsByType[mention.type];
        if (token.length === 0 || !mentionMap) {
          return;
        }
        let existing = mentionMap[token];
        if (!existing) {
          mentionMap[token] = {
            type: mention.type,
            name: mention.name,
            aliases: stableUnique(mention.aliases || []),
            event_ids: [eventId]
          };
        } else {
          existing.aliases = this.uniqueEntityNames(existing.aliases.concat(mention.aliases || []));
          existing.event_ids = stableUnique(existing.event_ids.concat([eventId])).sort();
        }
      });
    });
    return mentionsByType;
  }

  private async buildFullEntityDocument(events: EventMap, mentionsByType: EntityMentionCatalogByType,
    modelConfig: DataManagerModelConfig): Promise<EntityDocument> {
    let assignments: StringMap = createStringMap();
    let entities: EntityDefinitionMap = {};
    let stats = this.emptyEntityBuildStats();
    for (let entityType of ENTITY_TYPE_KEYS) {
      let mentionMap = mentionsByType[entityType];
      let tokens = Object.keys(mentionMap).sort();
      if (tokens.length === 0) {
        continue;
      }
      stats.newMentionCount += tokens.length;
      let promptMentions = tokens.map((token: string): EntityMention => this.catalogEntryToMention(mentionMap[token]));
      let sourceDisplay = this.entitySourceDisplay(promptMentions);

      let resolved: EntityMention[] = [];
      if (this.isEntityModelEnabled(modelConfig)) {
        stats.llmCallCount++;
        resolved = await this.modelClient.resolveEntities(entityType, promptMentions, modelConfig);
      }
      resolved.forEach((mention: EntityMention) => {
        let canonicalToken = this.entityNameToken(mention.name);
        if (sourceDisplay[canonicalToken] === undefined) {
          return;
        }
        let coveredTokens = this.coveredEntityTokens(mention, sourceDisplay);
        let key = this.addEntityDefinition(entities, entityType, sourceDisplay[canonicalToken],
          coveredTokens.filter((token: string) => token !== canonicalToken).map((token: string) => sourceDisplay[token]));
        coveredTokens.forEach((token: string) => assignments[this.entityAssignmentKey(entityType, token)] = key);
      });

      tokens.forEach((token: string) => {
        let assignmentKey = this.entityAssignmentKey(entityType, token);
        if (assignments[assignmentKey] === undefined) {
          assignments[assignmentKey] = this.addEntityDefinition(entities, entityType, mentionMap[token].name, []);
        }
      });
    }
    let document = this.finalizeEntityDocument(events, entities, assignments);
    dataManagerInfo(`Entity index built: mode=full, newMentionCount=${stats.newMentionCount}, reusedMentionCount=${stats.reusedMentionCount}, candidateCount=${stats.candidateCount}, llmCallCount=${stats.llmCallCount}`);
    return document;
  }

  private async buildIncrementalEntityDocument(events: EventMap, mentionsByType: EntityMentionCatalogByType,
    previousDocument: EntityDocument, modelConfig: DataManagerModelConfig): Promise<EntityDocument> {
    let entities = this.copyEntityDefinitions(previousDocument);
    let previousAssignments = this.previousEntityAssignments(previousDocument, entities);
    let assignments: StringMap = createStringMap();
    let pendingByType = this.emptyEntityMentionCatalog();
    let stats = this.emptyEntityBuildStats();

    for (let entityType of ENTITY_TYPE_KEYS) {
      let mentionMap = mentionsByType[entityType];
      Object.keys(mentionMap).sort().forEach((token: string) => {
        let entry = mentionMap[token];
        let assignmentKey = this.entityAssignmentKey(entityType, token);
        let reusedKey = previousAssignments[assignmentKey];
        if (reusedKey !== undefined && entities[reusedKey]) {
          assignments[assignmentKey] = reusedKey;
          this.addEntityDefinitionAliases(entities, reusedKey, [entry.name].concat(entry.aliases || []));
          stats.reusedMentionCount++;
          return;
        }
        let exactKey = this.exactEntityKeyForMention(entry, previousAssignments, entities);
        if (exactKey.length > 0) {
          assignments[assignmentKey] = exactKey;
          this.addEntityDefinitionAliases(entities, exactKey, [entry.name].concat(entry.aliases || []));
          stats.reusedMentionCount++;
          return;
        }
        pendingByType[entityType][token] = entry;
      });
    }

    for (let entityType of ENTITY_TYPE_KEYS) {
      let pendingMap = pendingByType[entityType];
      let pendingTokens = Object.keys(pendingMap).sort();
      stats.newMentionCount += pendingTokens.length;
      if (pendingTokens.length > 0) {
        await this.resolvePendingEntityMentions(entityType, pendingMap, entities, assignments, modelConfig, stats);
      }
    }

    let document = this.finalizeEntityDocument(events, entities, assignments);
    dataManagerInfo(`Entity index built: mode=incremental, newMentionCount=${stats.newMentionCount}, reusedMentionCount=${stats.reusedMentionCount}, candidateCount=${stats.candidateCount}, llmCallCount=${stats.llmCallCount}`);
    return document;
  }

  private async resolvePendingEntityMentions(entityType: string, pendingMap: EntityMentionCatalogMap,
    entities: EntityDefinitionMap, assignments: StringMap, modelConfig: DataManagerModelConfig,
    stats: EntityBuildStats): Promise<void> {
    let pendingTokens = Object.keys(pendingMap).sort();
    let chunkSize = 60;
    for (let offset = 0; offset < pendingTokens.length; offset += chunkSize) {
      let chunkTokens = pendingTokens.slice(offset, Math.min(offset + chunkSize, pendingTokens.length));
      let chunkEntries = chunkTokens.map((token: string): EntityMentionCatalogEntry => pendingMap[token]);
      let candidateLimit = pendingTokens.length > chunkSize ? 20 : 30;
      let candidateKeys = this.entityCandidateKeysForPending(entityType, chunkEntries, entities, candidateLimit);
      stats.candidateCount += candidateKeys.length;
      let promptMentions: EntityMention[] = chunkEntries.map((entry: EntityMentionCatalogEntry): EntityMention => this.catalogEntryToMention(entry));
      candidateKeys.forEach((key: string) => {
        let definition = entities[key];
        if (definition) {
          promptMentions.push(this.entityDefinitionPromptMention(definition));
        }
      });
      let sourceDisplay = this.entitySourceDisplay(promptMentions);
      let candidateAssignments = this.deriveEntityAssignmentsFromDefinitionKeys(entities, candidateKeys);
      let pendingSet: BooleanMap = {};
      chunkTokens.forEach((token: string) => pendingSet[this.entityAssignmentKey(entityType, token)] = true);

      let resolved: EntityMention[] = [];
      if (this.isEntityModelEnabled(modelConfig)) {
        stats.llmCallCount++;
        resolved = await this.modelClient.resolveEntities(entityType, promptMentions, modelConfig);
      }
      resolved.forEach((mention: EntityMention) => {
        this.applyIncrementalResolvedEntity(entityType, mention, sourceDisplay, candidateAssignments,
          pendingSet, entities, assignments);
      });
      chunkTokens.forEach((token: string) => {
        let assignmentKey = this.entityAssignmentKey(entityType, token);
        if (assignments[assignmentKey] === undefined) {
          assignments[assignmentKey] = this.addEntityDefinition(entities, entityType, pendingMap[token].name, []);
        }
      });
    }
  }

  private applyIncrementalResolvedEntity(entityType: string, mention: EntityMention, sourceDisplay: StringMap,
    candidateAssignments: StringMap, pendingSet: BooleanMap, entities: EntityDefinitionMap, assignments: StringMap): void {
    let coveredTokens = this.coveredEntityTokens(mention, sourceDisplay);
    let pendingTokens: string[] = [];
    let historicalKeys: string[] = [];
    coveredTokens.forEach((token: string) => {
      let assignmentKey = this.entityAssignmentKey(entityType, token);
      if (pendingSet[assignmentKey]) {
        pendingTokens.push(token);
      }
      let historicalKey = candidateAssignments[assignmentKey];
      if (historicalKey !== undefined && entities[historicalKey]) {
        historicalKeys.push(historicalKey);
      }
    });
    pendingTokens = stableUnique(pendingTokens);
    if (pendingTokens.length === 0) {
      return;
    }
    historicalKeys = stableUnique(historicalKeys);
    let targetKey = historicalKeys.length > 0 ? this.bestHistoricalEntityKey(historicalKeys, entities) : '';
    if (targetKey.length === 0) {
      let canonicalToken = this.pendingCanonicalToken(mention, pendingSet, sourceDisplay, pendingTokens);
      targetKey = this.addEntityDefinition(entities, entityType, sourceDisplay[canonicalToken],
        pendingTokens.filter((token: string) => token !== canonicalToken).map((token: string) => sourceDisplay[token]));
    } else {
      this.addEntityDefinitionAliases(entities, targetKey, pendingTokens.map((token: string) => sourceDisplay[token]));
    }
    pendingTokens.forEach((token: string) => assignments[this.entityAssignmentKey(entityType, token)] = targetKey);
  }

  private finalizeEntityDocument(events: EventMap, entities: EntityDefinitionMap, assignments: StringMap): EntityDocument {
    Object.keys(entities).forEach((key: string) => entities[key].event_ids = []);
    Object.keys(events).sort().forEach((eventId: string) => {
      let event = events[eventId];
      let mentions = normalizeEntityMentions(event.entity_mentions || []);
      let displayKeys: string[] = [];
      mentions.forEach((mention: EntityMention) => {
        let key = assignments[this.entityAssignmentKey(mention.type, this.entityNameToken(mention.name))];
        let existing = key ? entities[key] : undefined;
        if (!existing) {
          return;
        }
        existing.event_ids = stableUnique((existing.event_ids || []).concat([eventId])).sort();
        displayKeys.push(key);
      });
      event.entities = stableUnique(displayKeys);
    });
    let nonEmptyEntities = this.nonEmptyEntityDefinitions(entities);
    let document: EntityDocument = {
      entities: nonEmptyEntities,
      alias_postings: this.buildEntityAliasPostings(nonEmptyEntities),
      mention_assignments: this.nonEmptyEntityAssignments(assignments, nonEmptyEntities)
    };
    return document;
  }

  private emptyEntityMentionCatalog(): EntityMentionCatalogByType {
    let catalog = new Object() as EntityMentionCatalogByType;
    ENTITY_TYPE_KEYS.forEach((type: string) => catalog[type] = new Object() as EntityMentionCatalogMap);
    return catalog;
  }

  private emptyEntityBuildStats(): EntityBuildStats {
    let stats: EntityBuildStats = {
      reusedMentionCount: 0,
      newMentionCount: 0,
      candidateCount: 0,
      llmCallCount: 0
    };
    return stats;
  }

  private isEntityModelEnabled(modelConfig: DataManagerModelConfig): boolean {
    return modelConfig.enabled && modelConfig.baseUrl.trim().length > 0;
  }

  private catalogEntryToMention(entry: EntityMentionCatalogEntry): EntityMention {
    let mention: EntityMention = {
      type: entry.type,
      name: entry.name,
      aliases: (entry.aliases || []).slice()
    };
    return mention;
  }

  private entityDefinitionPromptMention(definition: EntityDefinition): EntityMention {
    let mention: EntityMention = {
      type: definition.type,
      name: definition.name,
      aliases: (definition.aliases || []).slice(0, 8)
    };
    return mention;
  }

  private entitySourceDisplay(mentions: EntityMention[]): StringMap {
    let sourceDisplay: StringMap = createStringMap();
    mentions.forEach((mention: EntityMention) => {
      [mention.name].concat(mention.aliases || []).forEach((name: string) => {
        let token = this.entityNameToken(name);
        if (token.length > 0 && sourceDisplay[token] === undefined) {
          sourceDisplay[token] = normalizeEntityName(name);
        }
      });
    });
    return sourceDisplay;
  }

  private coveredEntityTokens(mention: EntityMention, sourceDisplay: StringMap): string[] {
    let tokens: string[] = [];
    [mention.name].concat(mention.aliases || []).forEach((name: string) => {
      let token = this.entityNameToken(name);
      if (token.length > 0 && sourceDisplay[token] !== undefined) {
        tokens.push(token);
      }
    });
    return stableUnique(tokens);
  }

  private copyEntityDefinitions(document: EntityDocument): EntityDefinitionMap {
    let result: EntityDefinitionMap = {};
    let source = document.entities || {};
    Object.keys(source).sort().forEach((key: string) => {
      let definition = source[key];
      let entityType = normalizeFreeText(definition.type).toLowerCase();
      let name = normalizeEntityName(definition.name);
      if (ENTITY_TYPE_KEYS.indexOf(entityType) < 0 || name.length === 0 || key.length === 0) {
        return;
      }
      let copied: EntityDefinition = {
        type: entityType,
        name: name,
        aliases: this.uniqueEntityNames(definition.aliases || []),
        event_ids: stableUnique(definition.event_ids || []).sort()
      };
      result[key] = copied;
    });
    return result;
  }

  private previousEntityAssignments(document: EntityDocument, entities: EntityDefinitionMap): StringMap {
    let result: StringMap = createStringMap();
    let rawAssignments = document.mention_assignments;
    if (rawAssignments && !Array.isArray(rawAssignments)) {
      let currentAssignments: StringMap = rawAssignments;
      Object.keys(currentAssignments).sort().forEach((assignmentKey: string) => {
        let entityKey = currentAssignments[assignmentKey];
        if (this.isValidEntityAssignmentKey(assignmentKey) && entityKey !== undefined && entities[entityKey]) {
          result[assignmentKey] = entityKey;
        }
      });
    }
    let derived = this.deriveEntityAssignmentsFromDefinitions(entities);
    Object.keys(derived).sort().forEach((assignmentKey: string) => {
      if (result[assignmentKey] === undefined) {
        result[assignmentKey] = derived[assignmentKey];
      }
    });
    return result;
  }

  private deriveEntityAssignmentsFromDefinitions(definitions: EntityDefinitionMap): StringMap {
    return this.deriveEntityAssignmentsFromDefinitionKeys(definitions, Object.keys(definitions).sort());
  }

  private deriveEntityAssignmentsFromDefinitionKeys(definitions: EntityDefinitionMap, keys: string[]): StringMap {
    let assignments: StringMap = createStringMap();
    let conflicts: BooleanMap = {};
    keys.forEach((key: string) => {
      let definition = definitions[key];
      if (!definition) {
        return;
      }
      this.entityDefinitionTokens(definition).forEach((token: string) => {
        let assignmentKey = this.entityAssignmentKey(definition.type, token);
        let existing = assignments[assignmentKey];
        if (existing === undefined) {
          assignments[assignmentKey] = key;
        } else if (existing !== key) {
          conflicts[assignmentKey] = true;
        }
      });
    });
    let filtered: StringMap = createStringMap();
    Object.keys(assignments).sort().forEach((assignmentKey: string) => {
      if (!conflicts[assignmentKey]) {
        filtered[assignmentKey] = assignments[assignmentKey];
      }
    });
    return filtered;
  }

  private exactEntityKeyForMention(entry: EntityMentionCatalogEntry, assignments: StringMap,
    entities: EntityDefinitionMap): string {
    let tokens = this.entityMentionTokens(entry);
    for (let token of tokens) {
      let key = assignments[this.entityAssignmentKey(entry.type, token)];
      if (key !== undefined && entities[key]) {
        return key;
      }
    }
    return '';
  }

  private entityCandidateKeysForPending(entityType: string, entries: EntityMentionCatalogEntry[],
    entities: EntityDefinitionMap, limit: number): string[] {
    let pendingTokens: string[] = [];
    entries.forEach((entry: EntityMentionCatalogEntry) => pendingTokens = stableUnique(pendingTokens.concat(this.entityMentionTokens(entry))));
    let scores: Record<string, EntityCandidateScore> = {};
    Object.keys(entities).sort().forEach((key: string) => {
      let definition = entities[key];
      if (!definition || definition.type !== entityType) {
        return;
      }
      let bestScore = 0;
      let definitionTokens = this.entityDefinitionTokens(definition);
      pendingTokens.forEach((pendingToken: string) => {
        definitionTokens.forEach((definitionToken: string) => {
          bestScore = Math.max(bestScore, this.entityTokenRelationScore(pendingToken, definitionToken));
        });
      });
      if (bestScore > 0) {
        let score: EntityCandidateScore = {
          key: key,
          score: bestScore,
          eventCount: (definition.event_ids || []).length
        };
        scores[key] = score;
      }
    });
    return Object.keys(scores).sort((leftKey: string, rightKey: string): number => {
      let left = scores[leftKey];
      let right = scores[rightKey];
      if (left.score !== right.score) {
        return right.score - left.score;
      }
      if (left.eventCount !== right.eventCount) {
        return right.eventCount - left.eventCount;
      }
      return left.key.localeCompare(right.key);
    }).slice(0, limit);
  }

  private entityTokenRelationScore(left: string, right: string): number {
    if (left.length === 0 || right.length === 0) {
      return 0;
    }
    if (left === right) {
      return 100;
    }
    if (left.length < 2 || right.length < 2) {
      return 0;
    }
    if (left.startsWith(right) || right.startsWith(left)) {
      return 70;
    }
    if (left.indexOf(right) >= 0 || right.indexOf(left) >= 0) {
      return 50;
    }
    return 0;
  }

  private entityMentionTokens(entry: EntityMentionCatalogEntry): string[] {
    let tokens: string[] = [];
    [entry.name].concat(entry.aliases || []).forEach((name: string) => {
      let token = this.entityNameToken(name);
      if (token.length > 0) {
        tokens.push(token);
      }
    });
    return stableUnique(tokens);
  }

  private entityDefinitionTokens(definition: EntityDefinition): string[] {
    let tokens: string[] = [];
    [definition.name].concat(definition.aliases || []).forEach((name: string) => {
      let token = this.entityNameToken(name);
      if (token.length > 0) {
        tokens.push(token);
      }
    });
    return stableUnique(tokens);
  }

  private bestHistoricalEntityKey(keys: string[], entities: EntityDefinitionMap): string {
    let sorted = keys.slice().sort((leftKey: string, rightKey: string): number => {
      let left = entities[leftKey];
      let right = entities[rightKey];
      let leftCount = left ? (left.event_ids || []).length : 0;
      let rightCount = right ? (right.event_ids || []).length : 0;
      if (leftCount !== rightCount) {
        return rightCount - leftCount;
      }
      return leftKey.localeCompare(rightKey);
    });
    return sorted.length > 0 ? sorted[0] : '';
  }

  private pendingCanonicalToken(mention: EntityMention, pendingSet: BooleanMap, sourceDisplay: StringMap,
    pendingTokens: string[]): string {
    let canonicalToken = this.entityNameToken(mention.name);
    if (sourceDisplay[canonicalToken] !== undefined && pendingSet[this.entityAssignmentKey(mention.type, canonicalToken)]) {
      return canonicalToken;
    }
    for (let alias of mention.aliases || []) {
      let aliasToken = this.entityNameToken(alias);
      if (sourceDisplay[aliasToken] !== undefined && pendingSet[this.entityAssignmentKey(mention.type, aliasToken)]) {
        return aliasToken;
      }
    }
    return pendingTokens[0];
  }

  private addEntityDefinitionAliases(definitions: EntityDefinitionMap, key: string, aliases: string[]): void {
    let existing = definitions[key];
    if (!existing) {
      return;
    }
    existing.aliases = this.uniqueEntityNames((existing.aliases || []).concat(aliases))
      .filter((alias: string) => this.entityNameToken(alias) !== this.entityNameToken(existing.name));
  }

  private buildEntityAliasPostings(entities: EntityDefinitionMap): StringArrayMap {
    let aliasPostings: StringArrayMap = {};
    Object.keys(entities).sort().forEach((key: string) => {
      let definition = entities[key];
      [definition.name].concat(definition.aliases || []).forEach((name: string) => {
        let lookup = entityLookupKey(definition.type, name);
        if (!aliasPostings[lookup]) {
          aliasPostings[lookup] = [];
        }
        aliasPostings[lookup].push(key);
      });
    });
    Object.keys(aliasPostings).forEach((key: string) => aliasPostings[key] = stableUnique(aliasPostings[key]).sort());
    return aliasPostings;
  }

  private nonEmptyEntityAssignments(assignments: StringMap, entities: EntityDefinitionMap): StringMap {
    let result: StringMap = createStringMap();
    Object.keys(assignments).sort().forEach((assignmentKey: string) => {
      let entityKey = assignments[assignmentKey];
      if (this.isValidEntityAssignmentKey(assignmentKey) && entityKey !== undefined && entities[entityKey]) {
        result[assignmentKey] = entityKey;
      }
    });
    return result;
  }

  private entityAssignmentKey(entityType: string, token: string): string {
    return entityType + '\n' + token;
  }

  private isValidEntityAssignmentKey(value: string): boolean {
    let parts = value.split('\n');
    return parts.length === 2 && ENTITY_TYPE_KEYS.indexOf(parts[0]) >= 0 && parts[1].length > 0;
  }

  private addEntityDefinition(definitions: EntityDefinitionMap, entityType: string, name: string, aliases: string[]): string {
    let key = entityDisplayKey(entityType, name);
    let existing = definitions[key];
    if (!existing) {
      existing = {
        type: entityType,
        name: normalizeEntityName(name),
        aliases: [],
        event_ids: []
      };
      definitions[key] = existing;
    }
    existing.aliases = this.uniqueEntityNames((existing.aliases || []).concat(aliases))
      .filter((alias: string) => this.entityNameToken(alias) !== this.entityNameToken(existing.name));
    return key;
  }

  private nonEmptyEntityDefinitions(definitions: EntityDefinitionMap): EntityDefinitionMap {
    let result: EntityDefinitionMap = {};
    Object.keys(definitions).sort().forEach((key: string) => {
      if ((definitions[key].event_ids || []).length > 0) {
        result[key] = definitions[key];
      }
    });
    return result;
  }

  private uniqueEntityNames(values: string[]): string[] {
    let result: string[] = [];
    let seen: BooleanMap = {};
    values.forEach((value: string) => {
      let name = normalizeEntityName(value);
      let token = this.entityNameToken(name);
      if (name.length > 0 && token.length > 0 && !seen[token]) {
        seen[token] = true;
        result.push(name);
      }
    });
    return result;
  }

  private entityNameToken(value: string): string {
    return normalizeLookupText(normalizeEntityName(value));
  }

  private writeTemporalDocuments(events: EventMap): void {
    let monthGroups: EventGroupMap = {};
    Object.keys(events).forEach((eventId: string) => {
      let event = events[eventId];
      let month = monthKeyFromDate(event.event_date);
      if (month.length === 0) {
        return;
      }
      if (!monthGroups[month]) {
        monthGroups[month] = [];
      }
      monthGroups[month].push(event);
    });
    let desired: ObjectMap = {};
    for (let month of Object.keys(monthGroups).sort()) {
      let monthEvents = monthGroups[month].sort((left: IndexedEvent, right: IndexedEvent) => {
        if (left.event_date !== right.event_date) {
          return left.event_date.localeCompare(right.event_date);
        }
        return left.event_id.localeCompare(right.event_id);
      });
      let dayMap: EventGroupMap = {};
      monthEvents.forEach((event: IndexedEvent) => {
        if (!dayMap[event.event_date]) {
          dayMap[event.event_date] = [];
        }
        dayMap[event.event_date].push(event);
      });
      let dayNodes: TemporalDayNode[] = [];
      for (let day of Object.keys(dayMap).sort()) {
        let dayEvents = dayMap[day];
        let dayNode: TemporalDayNode = {
          date: day,
          event_ids: dayEvents.map((event: IndexedEvent) => event.event_id)
        };
        dayNodes.push(dayNode);
      }
      let weekMap: TemporalDayMap = {};
      dayNodes.forEach((node: TemporalDayNode) => {
        let day = node.date;
        let week = this.weekGroupKey(day);
        if (!weekMap[week]) {
          weekMap[week] = [];
        }
        weekMap[week].push(node);
      });
      let weekNodes: TemporalWeekNode[] = [];
      for (let week of Object.keys(weekMap).sort()) {
        let days = weekMap[week];
        let eventIds: string[] = [];
        days.forEach((node: TemporalDayNode) => {
          eventIds = eventIds.concat(node.event_ids || []);
        });
        let weekNode: TemporalWeekNode = {
          week_id: week,
          start_date: this.weekStartDate(week, month),
          end_date: this.weekEndDate(week, month),
          event_ids: stableUnique(eventIds),
          days: days
        };
        weekNodes.push(weekNode);
      }
      let temporalDocument: TemporalDocument = {
        month: month,
        event_ids: monthEvents.map((event: IndexedEvent) => event.event_id),
        weeks: weekNodes
      };
      desired[month + '.json'] = temporalDocument as Object;
    }
    this.storage.syncJsonDirectory(this.storage.join(this.paths.indexesRoot, 'temporal'), desired);
  }

  private loadTemporalDocuments(): TemporalDocumentMap {
    let result: TemporalDocumentMap = new Object() as TemporalDocumentMap;
    let temporalDir = this.storage.join(this.paths.indexesRoot, 'temporal');
    this.storage.listDir(temporalDir)
      .filter((name: string) => name.endsWith('.json'))
      .forEach((name: string) => {
        let document = this.storage.readJson<TemporalDocument>(this.storage.join(temporalDir, name), this.emptyTemporalDocument());
        if (document && document.month.length > 0) {
          result[document.month] = document;
        }
      });
    return result;
  }

  private async buildProfileDocument(events: EventMap, modelConfig: DataManagerModelConfig, reuseAllowed: boolean, progress?: DataManagerProgressCallback): Promise<ProfileState> {
    let byDomain: EventGroupMap = {};
    let profileDomains = this.profileDomainKeys();
    profileDomains.forEach((domain: string) => byDomain[domain] = []);
    Object.keys(events).forEach((eventId: string) => {
      let event = events[eventId];
      // 个人信息只供按需查询，避免自动进入每轮云端聊天携带的画像摘要及碰一碰分享。
      if ((event.workflow_scene_ids || []).indexOf(PERSONAL_INFO_MEMORY_SCENE_ID) >= 0) {
        return;
      }
      let domains = normalizeDomains(event.profile_domains || event.domains || [])
        .filter((domain: string): boolean => domain !== 'other');
      domains.forEach((domain: string) => {
        if (!byDomain[domain]) {
          byDomain[domain] = [];
        }
        byDomain[domain].push(event);
      });
    });
    let previous = this.loadProfileState();
    let domainsState: ProfileDomainMap = {};
    let domainIndex = 0;
    for (let domain of profileDomains) {
      this.emitProgress(progress, '生成画像', `生成${displayDomainName(domain)}画像`, domainIndex, profileDomains.length, 90 + Math.round(domainIndex * 7 / Math.max(1, profileDomains.length)));
      let domainEvents = byDomain[domain] || [];
      domainEvents.sort((left: IndexedEvent, right: IndexedEvent) => {
        if (left.event_date !== right.event_date) {
          return left.event_date.localeCompare(right.event_date);
        }
        return left.event_id.localeCompare(right.event_id);
      });
      let eventIds = domainEvents.map((event: IndexedEvent) => event.event_id);
      let inputHash = this.profileDomainInputHash(domain, domainEvents, modelConfig);
      let domainState: ProfileDomainState;
      if (domainEvents.length === 0) {
        domainState = {
          domain: domain,
          display_name: DOMAIN_DISPLAY_NAMES[domain] || domain,
          input_hash: inputHash,
          event_ids: [],
          event_count: 0,
          date_range: this.eventDateRange(domainEvents),
          short_summary: '',
          summary: '',
          claims: [],
          generation: 'empty'
        };
      } else {
        let previousClaims = previous.domains && previous.domains[domain] ? previous.domains[domain].claims : [];
        let previousDomain = previous.domains && previous.domains[domain] ? previous.domains[domain] : undefined;
        if (reuseAllowed && previousDomain && previousDomain.input_hash === inputHash && isProfileDomainStateReusable(previousDomain, eventIds.length)) {
          domainState = this.copyProfileDomain(previousDomain);
          domainState.event_ids = eventIds;
          domainState.event_count = eventIds.length;
          domainState.date_range = this.eventDateRange(domainEvents);
          dataManagerInfo(`Profile domain reused: domain=${domain}, events=${eventIds.length}, claims=${domainState.claims.length}`);
        } else {
          let payload: ProfileModelPayload = await this.modelClient.generateProfile(domain, domainEvents, previousClaims, modelConfig);
          let claims = this.normalizeProfileClaims(payload.claims, domainEvents, domain);
          domainState = buildProfileDomainStateFromPayload(domain, inputHash, eventIds, domainEvents.length, this.eventDateRange(domainEvents), payload, claims);
        }
      }
      domainsState[domain] = domainState;
      domainIndex++;
    }
    let profile: ProfileState = {
      generated_at: nowIsoLocal(),
      event_count: Object.keys(events).length,
      event_date_range: this.eventDateRange(Object.keys(events).map((eventId: string) => events[eventId])),
      domains: domainsState,
      claim_count: 0
    };
    profile.claim_count = this.profileClaimCount(profile);
    return profile;
  }

  private profileDomainKeys(): string[] {
    return DOMAIN_KEYS.filter((domain: string): boolean => domain !== 'other');
  }

  private emitProgress(progress: DataManagerProgressCallback | undefined, stage: string, message: string, current: number, total: number, percent: number): void {
    if (!progress) {
      return;
    }
    progress(createDataManagerProgress(stage, message, current, total, percent));
  }

  private profileDomainInputHash(domain: string, domainEvents: IndexedEvent[], modelConfig: DataManagerModelConfig): string {
    let parts: string[] = [
      domain,
      'short_summary_v1',
      modelConfig.enabled ? 'model' : 'model_unavailable',
      modelConfig.enabled ? String(PROFILE_MODEL_MAX_TOKENS) : '0',
      modelConfig.enabled ? String(PROFILE_MODEL_PROMPT_CHAR_LIMIT) : '0',
      modelConfig.enabled ? String(PROFILE_MODEL_MERGE_CHAR_LIMIT) : '0'
    ];
    domainEvents.forEach((event: IndexedEvent) => {
      parts.push([
        event.event_id,
        event.event_date,
        summarizeText(event.summary, 220),
        summarizeText(event.normalized_fact, 260),
        (event.domains || []).join(','),
        (event.sources || []).slice(0, 3).join(','),
        (event.entities || []).slice(0, 8).join(','),
        (event.keywords || []).slice(0, 12).join(',')
      ].join('\u001f'));
    });
    return this.storage.sha256Text(parts.join('\u001e'));
  }

  private copyProfileDomain(domain: ProfileDomainState): ProfileDomainState {
    let range: StringMap = createStringMap();
    range.start_date = domain.date_range ? domain.date_range.start_date || '' : '';
    range.end_date = domain.date_range ? domain.date_range.end_date || '' : '';
    let copied: ProfileDomainState = {
      domain: domain.domain,
      display_name: domain.display_name,
      input_hash: domain.input_hash,
      event_ids: (domain.event_ids || []).slice(),
      event_count: domain.event_count,
      date_range: range,
      short_summary: normalizeProfileShortSummary(domain.short_summary),
      summary: domain.summary,
      claims: (domain.claims || []).map((claim: ProfileClaim): ProfileClaim => {
        let item: ProfileClaim = {
          statement: claim.statement,
          kind: claim.kind,
          confidence: claim.confidence,
          event_ids: (claim.event_ids || []).slice(),
          evidence_count: claim.evidence_count,
          start_date: claim.start_date,
          end_date: claim.end_date,
          example: claim.example
        };
        return item;
      }),
      generation: domain.generation
    };
    return copied;
  }

  private normalizeProfileClaims(rawClaims: RawProfileClaim[], domainEvents: IndexedEvent[], domain: string): ProfileClaim[] {
    let eventMap: EventMap = {};
    domainEvents.forEach((event: IndexedEvent) => eventMap[event.event_id] = event);
    let result: ProfileClaim[] = [];
    let seen: BooleanMap = {};
    for (let raw of rawClaims) {
      let statement = normalizeFreeText(raw.statement || raw.claim || raw.summary);
      if (statement.length === 0 || seen[normalizeLookupText(statement)]) {
        continue;
      }
      let ids = stableUnique(raw.event_ids || []).filter((id: string) => eventMap[id] !== undefined);
      if (ids.length === 0) {
        continue;
      }
      let evidenceEvents = ids.map((id: string) => eventMap[id]).filter((event: IndexedEvent) => event !== undefined);
      let dateRange = this.eventDateRange(evidenceEvents);
      let claim: ProfileClaim = {
        statement: statement,
        kind: this.normalizeProfileKind(raw.kind),
        confidence: this.normalizeConfidence(raw.confidence),
        event_ids: ids,
        evidence_count: ids.length,
        start_date: dateRange.start_date,
        end_date: dateRange.end_date,
        example: normalizeFreeText(raw.example) || (evidenceEvents.length > 0 ? evidenceEvents[evidenceEvents.length - 1].summary : '')
      };
      if (!this.isProfileClaimWorthy(claim, domain)) {
        continue;
      }
      result.push(claim);
      seen[normalizeLookupText(statement)] = true;
      if (result.length >= 8) {
        break;
      }
    }
    return result;
  }

  private normalizeProfileKind(value: string): string {
    let kind = normalizeFreeText(value);
    return ['preference', 'habit', 'topic', 'service', 'relation', 'place', 'observation'].indexOf(kind) >= 0 ? kind : 'observation';
  }

  private normalizeConfidence(value: string): string {
    let confidence = normalizeFreeText(value);
    return ['high', 'medium', 'low'].indexOf(confidence) >= 0 ? confidence : 'low';
  }

  private isProfileClaimWorthy(claim: ProfileClaim, domain: string): boolean {
    let statement = normalizeFreeText(claim.statement);
    if (statement.length === 0 || claim.evidence_count < 2) {
      return false;
    }
    if (this.looksLikeEventDetail(statement)) {
      return false;
    }
    if (domain !== 'other' && claim.kind === 'relation') {
      return false;
    }
    return true;
  }

  private looksLikeEventDetail(statement: string): boolean {
    if (/\d{4}年|\d{4}-\d{2}-\d{2}|\d{1,2}月\d{1,2}日|\d+(?:\.\d+)?元|¥\s*\d/.test(statement)) {
      return true;
    }
    let markers = ['订单状态', '实付', '下单时间', '当前页面', '记录显示', '分别为', '之前', '正在尝试', '这块'];
    for (let marker of markers) {
      if (statement.indexOf(marker) >= 0) {
        return true;
      }
    }
    return false;
  }

  private renderProfileMarkdown(profile: ProfileState): string {
    let range = profile.event_date_range || createStringMap();
    let startDate = normalizeFreeText(range.start_date) || '-';
    let endDate = normalizeFreeText(range.end_date) || '-';
    let lines: string[] = [
      '# 用户画像',
      '',
      `- 生成时间：${profile.generated_at || '-'}`,
      `- 覆盖事件：${profile.event_count} 条`,
      `- 时间范围：${startDate} ~ ${endDate}`,
      `- 画像条目：${profile.claim_count} 条`,
      ''
    ];
    this.profileDomainKeys().forEach((domain: string) => {
      let doc = profile.domains[domain];
      lines.push(`## ${displayDomainName(domain)}`, '');
      if (!doc) {
        lines.push(`当前记录还不足以形成稳定的${displayDomainName(domain)}领域画像。`, '');
        return;
      }
      let summary = normalizeFreeText(doc.summary);
      if (summary.length > 0) {
        lines.push(summary, '');
      }
      if (doc.claims.length === 0) {
        if (summary.length === 0) {
          lines.push(`当前记录还不足以形成稳定的${displayDomainName(domain)}领域画像。`, '');
        }
      } else {
        doc.claims.forEach((claim: ProfileClaim) => {
          lines.push(`- ${claim.statement}`);
        });
        lines.push('');
      }
    });
    return lines.join('\n');
  }

  private indexedTextMatchIds(keyword: string, events: EventMap, postings: StringArrayMap, textGetter: (event: IndexedEvent) => string): BooleanMap {
    let compactKeyword = normalizeLookupText(keyword);
    let result: BooleanMap = {};
    if (compactKeyword.length === 0) {
      Object.keys(events).forEach((id: string) => result[id] = true);
      return result;
    }
    let terms = indexTerms(compactKeyword);
    if (terms.length === 0) {
      Object.keys(events).forEach((id: string) => {
        if (normalizeLookupText(textGetter(events[id])).indexOf(compactKeyword) >= 0) {
          result[id] = true;
        }
      });
      return result;
    }
    let candidate: BooleanMap | null = null;
    terms.forEach((term: string) => {
      let ids: BooleanMap = {};
      (postings[term] || []).forEach((id: string) => ids[id] = true);
      if (candidate === null) {
        candidate = ids;
      } else {
        Object.keys(candidate).forEach((id: string) => {
          candidate![id] = candidate![id] && ids[id] === true;
        });
      }
    });
    if (candidate === null) {
      return result;
    }
    Object.keys(candidate).forEach((id: string) => {
      if ((candidate as BooleanMap)[id] && events[id] &&
        normalizeLookupText(textGetter(events[id])).indexOf(compactKeyword) >= 0) {
        result[id] = true;
      }
    });
    return result;
  }

  private entityMatchIds(selectors: string[]): BooleanMap {
    let document = this.storage.readJson<EntityDocument>(this.storage.join(this.paths.indexesRoot, 'entity', 'index.json'), this.emptyEntityDocument());
    let entities = document.entities || {};
    let aliasPostings = document.alias_postings || {};
    let result: BooleanMap = {};
    selectors.forEach((selector: string) => {
      let parts = selector.split(':');
      if (parts.length < 2) {
        return;
      }
      let lookup = entityLookupKey(parts[0], parts.slice(1).join(':'));
      (aliasPostings[lookup] || []).forEach((entityKey: string) => {
        let definition = entities[entityKey];
        if (!definition) {
          return;
        }
        definition.event_ids.forEach((id: string) => result[id] = true);
      });
    });
    return result;
  }

  private weekGroupKey(day: string): string {
    let time = dateToTime(day);
    if (time <= 0) {
      return day;
    }
    let date = new Date(time);
    let weekday = date.getDay();
    let delta = weekday === 0 ? -6 : 1 - weekday;
    return new Date(time + delta * 86400000).toISOString().substring(0, 10);
  }

  private weekStartDate(weekStart: string, month: string): string {
    return weekStart < month + '-01' ? month + '-01' : weekStart;
  }

  private weekEndDate(weekStart: string, month: string): string {
    let start = dateToTime(weekStart);
    if (start <= 0) {
      return weekStart;
    }
    let end = new Date(start + 6 * 86400000).toISOString().substring(0, 10);
    let monthLast = this.monthLastDate(month);
    return end <= monthLast ? end : monthLast;
  }

  private monthLastDate(month: string): string {
    return monthLastDateForTemporalIndex(month);
  }

  private eventDateRange(events: IndexedEvent[]): StringMap {
    let dates = events.map((event: IndexedEvent) => event.event_date).filter((date: string) => isIsoDate(date)).sort();
    let range: StringMap = createStringMap();
    range['start_date'] = '';
    range['end_date'] = '';
    if (dates.length > 0) {
      range.start_date = dates[0];
      range.end_date = dates[dates.length - 1];
    }
    return range;
  }

  private profileClaimCount(profile: ProfileState): number {
    let count = 0;
    this.profileDomainKeys().forEach((domain: string) => {
      let doc = profile.domains[domain];
      count += doc ? doc.claims.length : 0;
    });
    return count;
  }

  private emptyProfileState(): ProfileState {
    let domains: ProfileDomainMap = {};
    this.profileDomainKeys().forEach((domain: string) => {
      let range: StringMap = createStringMap();
      range['start_date'] = '';
      range['end_date'] = '';
      let domainState: ProfileDomainState = {
        domain: domain,
        display_name: DOMAIN_DISPLAY_NAMES[domain] || domain,
        input_hash: '',
        event_ids: [],
        event_count: 0,
        date_range: range,
        short_summary: '',
        summary: '',
        claims: [],
        generation: 'empty'
      };
      domains[domain] = domainState;
    });
    let eventRange: StringMap = createStringMap();
    eventRange['start_date'] = '';
    eventRange['end_date'] = '';
    return {
      generated_at: '',
      event_count: 0,
      event_date_range: eventRange,
      domains: domains,
      claim_count: 0
    };
  }

  private emptyManifest(): IndexManifest {
    let sources: SourceManifestMap = {};
    let enrichment: EnrichmentManifest = {
      schema: '',
      mode: '',
      base_url: ''
    };
    let manifest: IndexManifest = {
      generated_at: '',
      input_root: '',
      index_dir: '',
      run_root: '',
      enrichment: enrichment,
      entity_types: [],
      sources: sources
    };
    return manifest;
  }

  private emptyInvertedDocument(): InvertedDocument {
    let postings: StringArrayMap = {};
    let document: InvertedDocument = {
      postings: postings
    };
    return document;
  }

  private emptyHomeTodoDocument(): HomeTodoDocument {
    let deadlinePostings: StringArrayMap = {};
    let typePostings: StringArrayMap = {};
    let document: HomeTodoDocument = {
      deadline_postings: deadlinePostings,
      no_deadline_event_ids: [],
      type_postings: typePostings
    };
    return document;
  }

  private emptySourceDocument(): SourceDocument {
    let postings: StringArrayMap = {};
    let document: SourceDocument = {
      postings: postings
    };
    return document;
  }

  private emptyDomainDocument(): DomainDocument {
    let postings: StringArrayMap = {};
    DOMAIN_KEYS.forEach((domain: string) => postings[domain] = []);
    let document: DomainDocument = {
      postings: postings
    };
    return document;
  }

  private emptyWorkflowSceneDocument(): WorkflowSceneDocument {
    let postings: StringArrayMap = {};
    memorySceneConfigs().forEach((scene: WorkflowSceneConfig) => {
      let key = String(scene.sceneId);
      postings[key] = [];
    });
    let document: WorkflowSceneDocument = {
      postings: postings
    };
    return document;
  }

  private emptyEntityDocument(): EntityDocument {
    let entities: EntityDefinitionMap = {};
    let aliasPostings: StringArrayMap = {};
    let mentionAssignments: StringMap = createStringMap();
    let document: EntityDocument = {
      entities: entities,
      alias_postings: aliasPostings,
      mention_assignments: mentionAssignments
    };
    return document;
  }

  private hasEntityIndexData(document: EntityDocument): boolean {
    return document.entities !== undefined && document.alias_postings !== undefined;
  }

  private emptyTemporalDocument(): TemporalDocument {
    return {
      month: '',
      event_ids: [],
      weeks: []
    };
  }

  private emptyConsolidatedState(): ConsolidatedState {
    let dateRange: StringMap = createStringMap();
    let state: ConsolidatedState = {
      metadata: {
        source_date_range: dateRange,
        source_files: [],
        processed_entry_hashes: createStringMap(),
        latest_record_index: 0,
        dedup_window_size: 0,
        updated_at: '',
        total_records: 0,
        month: '',
        recent_match_days: 7,
        recent_match_max_records: 0
      },
      records: []
    };
    return state;
  }
}
