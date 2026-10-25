import { AvatarHomeViewModel } from './avatar/AvatarTypes';

export const DATA_MANAGER_STORAGE_ROOT_NAME: string = 'workflows';
export const DAILY_LOG_DIR_NAME: string = 'daily-log';
export const PROFILE_CONSOLIDATION_DIR_NAME: string = 'profile-consolidation';
export const OUTPUTS_DIR_NAME: string = 'outputs';
export const INDEXES_DIR_NAME: string = 'indexes';
export const COLLECTION_GROUPS_DIR_NAME: string = 'collection-groups';
export const HOME_RECOMMENDATIONS_FILE_NAME: string = 'home-recommendations.json';
export const WORKFLOW_RUNS_DIR_NAME: string = 'runs';

export const DOMAIN_KEYS: string[] = ['eat', 'wear', 'live', 'travel', 'work', 'other'];

export type StringMap = Record<string, string>;
export type NumberMap = Record<string, number>;
export type StringArrayMap = Record<string, string[]>;
export type BooleanMap = Record<string, boolean>;
export type JsonMap = Record<string, Object | string | number | boolean | null>;

export function createStringMap(): StringMap {
  return new Object() as StringMap;
}

export function createNumberMap(): NumberMap {
  return new Object() as NumberMap;
}

export function createStringArrayMap(): StringArrayMap {
  return new Object() as StringArrayMap;
}

export function createBooleanMap(): BooleanMap {
  return new Object() as BooleanMap;
}

export function createJsonMap(): JsonMap {
  return new Object() as JsonMap;
}

export interface DailyLogParseResult {
  workflow_metadata: JsonMap;
  latest_entry_index: number;
  body: string;
}

export interface NumberedEntry {
  index: number;
  text: string;
}

export interface DedupDecision {
  decision: string;
  matched_record_ids: number[];
  reason: string;
  merged_summary: string;
  merged_fact: string;
  merged_tags: string[];
}

export interface RawProfileClaim {
  statement: string;
  claim?: string;
  summary?: string;
  kind: string;
  confidence: string;
  event_ids: string[];
  example: string;
}

export interface ProfileModelPayload {
  short_summary: string;
  summary: string;
  claims: RawProfileClaim[];
  generation: string;
}

export const DOMAIN_DISPLAY_NAMES: StringMap = createStringMap();
DOMAIN_DISPLAY_NAMES['eat'] = '吃';
DOMAIN_DISPLAY_NAMES['wear'] = '穿';
DOMAIN_DISPLAY_NAMES['live'] = '住';
DOMAIN_DISPLAY_NAMES['travel'] = '行';
DOMAIN_DISPLAY_NAMES['work'] = '办公';
DOMAIN_DISPLAY_NAMES['other'] = '其他';

export const DOMAIN_DESCRIPTIONS: StringMap = createStringMap();
DOMAIN_DESCRIPTIONS['eat'] = '吃：餐饮、外卖、食品和饮料购买';
DOMAIN_DESCRIPTIONS['wear'] = '穿：服装、鞋包和穿戴用品';
DOMAIN_DESCRIPTIONS['live'] = '住：住房、住宿、酒店和家居';
DOMAIN_DESCRIPTIONS['travel'] = '行：交通、出行和旅行移动';
DOMAIN_DESCRIPTIONS['work'] = '办公：工作、会议、协作和办公事务';
DOMAIN_DESCRIPTIONS['other'] = '无法归入以上分类的事件';

export interface DataManagerModelConfig {
  baseUrl: string;
  apiKey: string;
  model?: string;
  enabled: boolean;
}

export interface DataManagerRefreshOptions {
  modelConfig: DataManagerModelConfig;
  dedupWindow: number;
}

export interface RefreshSummary {
  dailyEntryCount: number;
  consolidatedRecordCount: number;
  eventCount: number;
  profileClaimCount: number;
  updatedAt: string;
  message: string;
  skipped: boolean;
}

export interface DataManagerProgress {
  stage: string;
  message: string;
  current: number;
  total: number;
  percent: number;
}

export type DataManagerProgressCallback = (progress: DataManagerProgress) => void;

export function createDataManagerProgress(stage: string, message: string, current: number, total: number, percent: number): DataManagerProgress {
  let progress: DataManagerProgress = {
    stage: stage,
    message: message,
    current: current,
    total: total,
    percent: percent
  };
  return progress;
}

export interface DailyLogMetadata {
  workflow_metadata: JsonMap;
  latest_entry_index: number;
}

export interface SourceEntry {
  source_date: string;
  file_name: string;
  entry_index: number;
  entry_text: string;
  workflow_metadata: JsonMap;
  workflow_scene_id: number;
  source_ref: string;
}

export interface CandidateFact {
  summary: string;
  normalized_fact: string;
  event_date: string;
  tags: string[];
  model_notes: string;
  raw_excerpt: string;
  source_ref: string;
  source_date: string;
  workflow_scene_id: number;
  dedup_text: string;
}

export interface AggregatedRecord {
  record_id: number;
  first_seen_date: string;
  last_seen_date: string;
  source_refs: string[];
  source_dates: string[];
  workflow_scene_ids: number[];
  summary: string;
  normalized_fact: string;
  raw_excerpts: string[];
  tags: string[];
  dedup_status: string;
  model_notes: string[];
  dedup_text: string;
}

export interface ConsolidatedMetadata {
  source_date_range: StringMap;
  source_files: string[];
  processed_entry_hashes: StringMap;
  latest_record_index: number;
  dedup_window_size: number;
  updated_at: string;
  total_records: number;
  month: string;
  recent_match_days: number;
  recent_match_max_records: number;
}

export interface ConsolidatedState {
  metadata: ConsolidatedMetadata;
  records: AggregatedRecord[];
}

export interface EntityMention {
  type: string;
  name: string;
  aliases: string[];
}

export interface IndexedEventTodo {
  type: string;
  deadline: string;
  text: string;
  agent_task: string;
}

export interface IndexedEvent {
  calendar?: CalendarEventMetadata;
  event_id: string;
  source_state_file: string;
  record_id: number;
  event_date: string;
  last_seen_date: string;
  summary: string;
  normalized_fact: string;
  tags: string[];
  source_refs: string[];
  sources: string[];
  workflow_scene_ids: number[];
  image_paths: string[];
  todo: IndexedEventTodo;
  keywords: string[];
  domains: string[];
  entity_mentions: EntityMention[];
  enrichment_method: string;
  entities: string[];
  profile_domains: string[];
}

export interface CalendarEventMetadata {
  seriesKey: string;
  start: number;
  end: number;
  profileEnabled: boolean;
}

export interface EventPartition {
  month: string;
  events: IndexedEvent[];
}

export interface ProfileClaim {
  statement: string;
  kind: string;
  confidence: string;
  event_ids: string[];
  evidence_count: number;
  start_date: string;
  end_date: string;
  example: string;
}

export interface ProfileDomainState {
  domain: string;
  display_name: string;
  input_hash: string;
  event_ids: string[];
  event_count: number;
  date_range: StringMap;
  short_summary: string;
  summary: string;
  claims: ProfileClaim[];
  generation: string;
}

export interface ProfileState {
  calendar_input_hash?: string;
  generated_at: string;
  event_count: number;
  event_date_range: StringMap;
  domains: Record<string, ProfileDomainState>;
  claim_count: number;
}

export interface QueryOptions {
  keywords: string[];
  keywordOperator?: string;
  includeTodoDeadlineInTimeRange?: boolean;
  domains: string[];
  entities: string[];
  date: string;
  month: string;
  startDate: string;
  endDate: string;
  workflowSceneIds: number[];
  limit: number;
}

export interface QueryResult {
  total_events: number;
  events: IndexedEvent[];
  events_truncated: boolean;
}

export interface CollectionGroupState {
  group_id: string;
  title: string;
  source: string;
  time: string;
  meta: string;
  status: string;
  domain: string;
  event_ids: string[];
  source_input_hash: string;
  event_input_hashes: StringMap;
}

export interface CollectionGroupsDocument {
  generated_at: string;
  tab_id: string;
  title: string;
  query: QueryOptions;
  input_hash: string;
  total_events: number;
  groups: CollectionGroupState[];
}

export interface CollectionGroupAssignment {
  event_id: string;
  group_id: string;
  title: string;
  source: string;
  domain: string;
}

export interface HomeDomainViewModel {
  domain: string;
  icon: string;
  title: string;
  desc: string;
  fullDesc: string;
  claims: string[];
  color: string;
  eventCount: number;
}

export interface HomeRecommendationViewModel {
  calendarStart?: number;
  calendarEnd?: number;
  calendarAllDay?: boolean;
  calendarLocation?: string;
  id: string;
  domain: string;
  tag: string;
  title: string;
  desc: string;
  meta: string;
  color: string;
  imageRefs: CollectionImageViewModel[];
  thumbnailUri: string;
  sourceEventIds: string[];
  detail: string;
  agentTask: string;
  completed: boolean;
}

export interface HomeRecommendationState {
  id: string;
  tag: string;
  title: string;
  desc: string;
  meta: string;
  domain: string;
  source_event_ids: string[];
  source_input_hash: string;
  completed: boolean;
}

export interface HomeRecommendationsDocument {
  generated_at: string;
  input_hash: string;
  total_events: number;
  recommendations: HomeRecommendationState[];
}

export interface HomeRecommendationPlannerEvent {
  event_id: string;
  date: string;
  todo_type: string;
  todo_deadline: string;
  todo_text: string;
  summary: string;
  normalized_fact: string;
  sources: string[];
  domains: string[];
  keywords: string[];
  image_paths: string[];
}

export interface HomeProfileViewModel extends AvatarHomeViewModel {
  calendarEnabled?: boolean;
  calendarError?: string;
  mailReminder?: HomeRecommendationViewModel;
  mailPreview?: string[];
  updatedLabel: string;
  completeness: number;
  totalEvents: number;
  domains: HomeDomainViewModel[];
  recommendations: HomeRecommendationViewModel[];
  empty: boolean;
}

export interface CollectionRowViewModel {
  id: string;
  title: string;
  source: string;
  time: string;
  meta: string;
  status: string;
  domain: string;
}

export interface CollectionImageViewModel {
  ref: string;
  uri: string;
  available: boolean;
  label: string;
}

// 图库分析详情用于把 DataManager 事件反查到原始图库结果，便于 UI 展示 OCR、EXIF 和位置证据。
export interface CollectionGalleryDetailViewModel {
  id: string;
  uri: string;
  title: string;
  category: string;
  summary: string;
  details: string[];
  tags: string[];
  ocrText: string;
  date: string;
  captureTime: string;
  captureDevice: string;
  captureLocation: string;
  address: string;
  poiName: string;
  mapUrl: string;
}

export interface CollectionEventViewModel {
  id: string;
  summary: string;
  fullText: string;
  normalizedFact: string;
  source: string;
  time: string;
  firstSeenTime: string;
  lastSeenTime: string;
  meta: string;
  status: string;
  domain: string;
  imageRefs: CollectionImageViewModel[];
  galleryDetails: CollectionGalleryDetailViewModel[];
  thumbnailUri: string;
}

export interface CollectionGroupViewModel {
  id: string;
  title: string;
  source: string;
  time: string;
  meta: string;
  status: string;
  domain: string;
  eventCount: number;
  thumbnailUri: string;
  events: CollectionEventViewModel[];
}

export interface CollectionInsightViewModel {
  color: string;
  name: string;
  value: string;
  widthValue: string;
}

export interface CollectionViewModel {
  title: string;
  countLabel: string;
  lastUpdatedLabel: string;
  groups: CollectionGroupViewModel[];
  rows: CollectionRowViewModel[];
  insights: CollectionInsightViewModel[];
  insightSummary: string;
  empty: boolean;
}
