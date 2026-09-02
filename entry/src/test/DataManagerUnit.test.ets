import { describe, it, expect } from '@ohos/hypium';
import fs from '@ohos.file.fs';
import {
  atomicizeCandidateFacts,
  findExactExistingMatch,
  eventSourceNames,
  indexTerms,
  normalizeProfileShortSummary,
  parseDailyLogDocument,
  parseNumberedEntries,
  profileShortSummaryFromText,
  selectRecentScopeRecords,
  sourceAppDisplayName,
  sourceDisplayName,
  weekdayLabelFromDate
} from '../main/ets/datamanager/DataManagerUtils';
import {
  applyIncrementalCollectionGroupAssignments,
  collectionGroupEventInputFingerprint,
  collectionGroupSourceInputFingerprint,
  CollectionTabSpec,
  collectionTabSpecs,
  collectionTabSpecByIndex,
  heuristicCollectionGroups,
  normalizeCollectionGroups,
  prepareIncrementalCollectionGroups
} from '../main/ets/datamanager/CollectionGroupingService';
import { GalleryExifUtils } from '../main/ets/utils/gallery/GalleryExifUtils';
import {
  homeRecommendationSourceInputFingerprint,
  isHomeRecommendationSourceReusable,
  isCurrentOrFutureTodoDeadline,
  pruneHomeRecommendationsDocument,
  recommendationTodoDeadlineMeta
} from '../main/ets/datamanager/HomeRecommendationService';
import {
  IndexService,
  eventEnrichInputFingerprint,
  isEventEnrichInputReusable,
  isHomeTodoIndexCandidate,
  isRecentNoDeadlineHomeTodoEvent,
  isQueryResultTruncated,
  monthLastDateForTemporalIndex,
  normalizeQueryKeywordOperator,
  resolveQueryLimit,
  buildProfileDomainStateFromPayload,
  isProfileDomainStateReusable
} from '../main/ets/datamanager/IndexService';
import {
  buildFactSplitPromptPreview,
  buildEnrichPromptPreview,
  DataPipelineModelClient,
  shouldKeepTodoAgentTask
} from '../main/ets/datamanager/DataPipelineModelClient';
import {
  collectionViewModelByTabIndex,
  createEmptyCollectionViewModels,
  homeProfileCompleteness,
  homeProfileDomainDescription,
  homeProfileDomainFullDescription,
  setHomeRecommendationCompletedInDocument,
  shouldShowHomeRecommendationInView
} from '../main/ets/datamanager/DataManagerFacade';
import {
  GalleryMemorySync,
  GalleryMemorySyncResult,
  galleryMemorySceneIdForCategory
} from '../main/ets/utils/gallery/GalleryMemorySync';
import {
  AggregatedRecord,
  CandidateFact,
  CollectionGroupAssignment,
  CollectionGroupState,
  CollectionViewModel,
  HomeRecommendationsDocument,
  HomeRecommendationState,
  HomeDomainViewModel,
  IndexedEvent,
  IndexedEventTodo,
  HomeRecommendationPlannerEvent,
  DataManagerModelConfig,
  CollectionGalleryDetailViewModel,
  EventPartition,
  JsonMap,
  ProfileClaim,
  ProfileDomainState,
  ProfileModelPayload,
  ProfileState,
  QueryOptions,
  QueryResult,
  NumberedEntry,
  SourceEntry,
  StringArrayMap,
  createJsonMap,
  createStringMap
} from '../main/ets/datamanager/DataManagerTypes';
import { GalleryAnalysisResult } from '../main/ets/utils/gallery/GalleryTypes';
import {
  memorySceneConfigs,
  memorySceneLabel,
  normalizeMemorySceneIds,
  workflowSceneConfigs,
  WorkflowSceneConfig
} from '../main/ets/utils/WorkflowSceneConfig';
import { parseJsonCompat, stringifyJsonCompat } from '../main/ets/utils/JsonCompat';
import { AvatarPromptBuilder } from '../main/ets/datamanager/avatar/AvatarPromptBuilder';
import { AvatarService } from '../main/ets/datamanager/avatar/AvatarService';
import { AvatarStorage } from '../main/ets/datamanager/avatar/AvatarStorage';
import {
  avatarErrorMessage,
  createDefaultAvatarGenerationParams,
  createEmptyAvatarHomeViewModel
} from '../main/ets/datamanager/avatar/AvatarTypes';
import {
  createSeedreamRequestBody,
  normalizeSeedreamImageBase64,
  normalizeSeedreamImageUrl
} from '../main/ets/datamanager/avatar/SeedreamAvatarProvider';
import { DataManagerFacade } from '../main/ets/datamanager/DataManagerFacade';
import { DataManagerPaths } from '../main/ets/datamanager/DataManagerPaths';
import { DataManagerStorage } from '../main/ets/datamanager/DataManagerStorage';
import { sourceEntryProcessingHash } from '../main/ets/datamanager/ConsolidationService';

interface TestTemporalSummary {
  text: string;
  input_hash: string;
  generation: string;
}

interface TestTemporalDocument {
  month: string;
  event_ids: string[];
  summary: TestTemporalSummary;
  weeks: Object[];
}

interface TestStringArrayDocument {
  postings: Record<string, string[]>;
}

interface TestHomeTodoDocument {
  deadline_postings: Record<string, string[]>;
  no_deadline_event_ids: string[];
  type_postings: Record<string, string[]>;
}

class MemoryDataManagerStorage extends DataManagerStorage {
  private documents: Record<string, Object> = new Object() as Record<string, Object>;
  private directories: Record<string, boolean> = new Object() as Record<string, boolean>;

  ensureDir(path: string): void {
    if (path.length > 0) {
      this.directories[path] = true;
    }
  }

  listDir(path: string): string[] {
    let names: Record<string, boolean> = new Object() as Record<string, boolean>;
    let prefix = path.length > 0 ? path + '/' : '';
    Object.keys(this.directories).forEach((directory: string) => {
      this.addListDirChild(directory, prefix, names);
    });
    Object.keys(this.documents).forEach((document: string) => {
      this.addListDirChild(document, prefix, names);
    });
    return Object.keys(names).sort();
  }

  readJson<T>(path: string, fallback: T): T {
    let document = this.documents[path];
    if (document === undefined) {
      return fallback;
    }
    return document as T;
  }

  writeJsonAtomic(path: string, payload: Object): void {
    let parent = this.dirname(path);
    if (parent.length > 0) {
      this.ensureDir(parent);
    }
    this.documents[path] = payload;
  }

  removeTree(path: string): void {
    let nextDocuments: Record<string, Object> = new Object() as Record<string, Object>;
    Object.keys(this.documents).forEach((document: string) => {
      if (document !== path && !document.startsWith(path + '/')) {
        nextDocuments[document] = this.documents[document];
      }
    });
    this.documents = nextDocuments;
    let nextDirectories: Record<string, boolean> = new Object() as Record<string, boolean>;
    Object.keys(this.directories).forEach((directory: string) => {
      if (directory !== path && !directory.startsWith(path + '/')) {
        nextDirectories[directory] = this.directories[directory];
      }
    });
    this.directories = nextDirectories;
  }

  private addListDirChild(path: string, prefix: string, names: Record<string, boolean>): void {
    if (!path.startsWith(prefix)) {
      return;
    }
    let rest = path.substring(prefix.length);
    if (rest.length === 0) {
      return;
    }
    let slash = rest.indexOf('/');
    let child = slash >= 0 ? rest.substring(0, slash) : rest;
    if (child.length > 0) {
      names[child] = true;
    }
  }
}

function demoIndexedEvent(id: string, summary: string, source: string, domain: string, keyword: string): IndexedEvent {
  return {
    event_id: id,
    source_state_file: '2026-05/demo.md.state.json',
    record_id: Number(id.replace('e', '')),
    event_date: '2026-05-29',
    last_seen_date: '2026-05-29',
    summary: summary,
    normalized_fact: summary,
    tags: [],
    source_refs: [],
    sources: [source],
    workflow_scene_ids: [3],
    image_paths: [],
    todo: {
      type: '',
      deadline: '',
      text: '',
      agent_task: ''
    },
    keywords: [keyword],
    domains: [domain],
    entity_mentions: [],
    enrichment_method: 'test',
    entities: [],
    profile_domains: [domain]
  };
}

function demoPlannerEvent(id: string, deadline: string, todoType: string = 'buy'): HomeRecommendationPlannerEvent {
  return {
    event_id: id,
    date: '2026-06-05',
    todo_type: todoType,
    todo_deadline: deadline,
    todo_text: '购买咖啡豆',
    summary: '微信里提到要买咖啡豆',
    normalized_fact: '用户想购买咖啡豆',
    sources: ['微信'],
    domains: ['eat'],
    keywords: ['咖啡豆'],
    image_paths: []
  };
}

function demoRecommendationState(id: string, completed: boolean): HomeRecommendationState {
  return {
    id: id,
    tag: '待购买',
    title: '购买咖啡豆',
    desc: '记得购买咖啡豆',
    meta: '',
    domain: 'eat',
    source_event_ids: ['e1'],
    source_input_hash: 'hash-' + id,
    completed: completed
  };
}

function demoAggregatedRecord(id: number, firstSeenDate: string, lastSeenDate: string, text: string): AggregatedRecord {
  return {
    record_id: id,
    first_seen_date: firstSeenDate,
    last_seen_date: lastSeenDate,
    source_refs: ['2026-05-21/demo.md#' + String(id)],
    source_dates: [firstSeenDate],
    workflow_scene_ids: [1],
    summary: text,
    normalized_fact: text,
    raw_excerpts: [text],
    tags: [],
    dedup_status: 'new',
    model_notes: [],
    dedup_text: text
  };
}

function demoCandidateFact(eventDate: string, sourceDate: string, text: string): CandidateFact {
  return {
    summary: text,
    normalized_fact: text,
    event_date: eventDate,
    tags: [],
    model_notes: 'test',
    raw_excerpt: text,
    source_ref: sourceDate + '/demo.md#99',
    source_date: sourceDate,
    workflow_scene_id: 1,
    dedup_text: text
  };
}

function demoHomeDomain(domain: string, desc: string): HomeDomainViewModel {
  return {
    domain: domain,
    icon: domain,
    title: domain,
    desc: desc,
    fullDesc: desc,
    claims: [],
    color: '#000000',
    eventCount: desc === '暂无数据' ? 0 : 1
  };
}

function demoHomeRecommendationEvent(id: string, eventDate: string, deadline: string): IndexedEvent {
  let event = demoIndexedEvent(id, '微信里提到一个待办事项', '微信', 'work', '待办');
  event.event_date = eventDate;
  event.todo = {
    type: deadline.length > 0 ? '' : 'buy',
    deadline: deadline,
    text: '处理待办事项',
    agent_task: ''
  };
  return event;
}

function disabledModelConfig(): DataManagerModelConfig {
  return {
    baseUrl: '',
    apiKey: '',
    enabled: false
  };
}

function demoProfileClaim(statement: string): ProfileClaim {
  return {
    statement: statement,
    kind: 'preference',
    confidence: 'medium',
    event_ids: ['e1', 'e2'],
    evidence_count: 2,
    start_date: '2026-05-29',
    end_date: '2026-05-30',
    example: '用户记录了咖啡相关消费'
  };
}

function demoProfileDomainState(generation: string): ProfileDomainState {
  let range = createStringMap();
  range.start_date = '2026-05-29';
  range.end_date = '2026-05-30';
  return {
    domain: 'eat',
    display_name: '吃',
    input_hash: 'hash',
    event_ids: ['e1', 'e2'],
    event_count: 2,
    date_range: range,
    short_summary: '',
    summary: '',
    claims: [],
    generation: generation
  };
}

function demoEventMap(events: IndexedEvent[]): Record<string, IndexedEvent> {
  let map: Record<string, IndexedEvent> = new Object() as Record<string, IndexedEvent>;
  events.forEach((event: IndexedEvent) => {
    map[event.event_id] = event;
  });
  return map;
}

function demoQueryOptions(): QueryOptions {
  return {
    keywords: [],
    keywordOperator: 'and',
    includeTodoDeadlineInTimeRange: false,
    domains: [],
    entities: [],
    date: '',
    month: '',
    startDate: '',
    endDate: '',
    workflowSceneIds: [],
    limit: 0
  };
}

function demoIndexService(filesDir: string): IndexService {
  let storage = new DataManagerStorage();
  let paths = new DataManagerPaths(filesDir, storage);
  return new IndexService(paths, storage, new DataPipelineModelClient());
}

function demoTemporalSummary(text: string): TestTemporalSummary {
  return {
    text: text,
    input_hash: 'hash-' + text,
    generation: 'test'
  };
}

let galleryMemoryRootCounter: number = 0;

interface GalleryMemoryItemsIndexDocument {
  items: string[];
}

interface TestWorkflowSceneDocument {
  postings: StringArrayMap;
}

interface TestEventPartitionIndex {
  schema: string;
  generated_at: string;
  partition_files: string[];
}

function nextGalleryMemoryRoot(name: string): string {
  galleryMemoryRootCounter += 1;
  return '/tmp/gallery-memory-sync-' + name + '-' + String(new Date().getTime()) + '-' +
    String(galleryMemoryRootCounter);
}

function galleryMemoryStorage(): DataManagerStorage {
  return new DataManagerStorage();
}

function galleryMemoryWriteItem(root: string, result: GalleryAnalysisResult): void {
  let storage = galleryMemoryStorage();
  let path = root + '/gallery-log/items/' + result.date + '/' + result.id + '.json';
  storage.writeText(path, stringifyJsonCompat(galleryMemoryResultJson(result), 2));
  galleryMemoryUpsertIndex(root, 'gallery-log/items/' + result.date + '/' + result.id + '.json');
}

function galleryMemoryUpsertIndex(root: string, relativePath: string): void {
  let storage = galleryMemoryStorage();
  let indexPath = root + '/gallery-log/items-index.json';
  let document: GalleryMemoryItemsIndexDocument = { items: [] };
  let content = storage.readText(indexPath, '');
  if (content.length > 0) {
    try {
      document = parseJsonCompat<GalleryMemoryItemsIndexDocument>(content);
    } catch (e) {
      document = { items: [] };
    }
  }
  if (!Array.isArray(document.items)) {
    document.items = [];
  }
  if (document.items.indexOf(relativePath) < 0) {
    document.items.push(relativePath);
  }
  storage.writeText(indexPath, stringifyJsonCompat(document as Object, 2));
}

function galleryMemoryResultJson(result: GalleryAnalysisResult): JsonMap {
  let record = createJsonMap();
  record['id'] = result.id;
  record['uri'] = result.uri;
  record['thumbnailUri'] = result.thumbnailUri ? result.thumbnailUri : '';
  record['title'] = result.title;
  record['category'] = result.category;
  record['summary'] = result.summary;
  record['details'] = result.details as Object;
  record['tags'] = result.tags as Object;
  record['ocrText'] = result.ocrText;
  record['rawModelText'] = result.rawModelText;
  record['keywords'] = result.keywords as Object;
  record['date'] = result.date;
  record['embeddingRef'] = result.embeddingRef;
  record['embeddingStatus'] = result.embeddingStatus;
  record['embeddingDimension'] = result.embeddingDimension;
  record['error'] = result.error;
  if (result.latitude !== undefined) {
    record['latitude'] = result.latitude;
  }
  if (result.longitude !== undefined) {
    record['longitude'] = result.longitude;
  }
  if (result.exif) {
    record['exif'] = result.exif as Object;
  }
  if (result.location) {
    record['location'] = result.location as Object;
  }
  record['createdAt'] = result.createdAt;
  return record;
}

function galleryMemoryItem(id: string, category: string, title: string, summary: string): GalleryAnalysisResult {
  return {
    id: id,
    uri: 'file://gallery/' + id + '.jpg',
    thumbnailUri: '',
    title: title,
    category: category,
    summary: summary,
    details: ['画面主体清晰', '包含可用于记忆的场景细节'],
    tags: ['图库', category],
    ocrText: 'OCR-' + id,
    rawModelText: '',
    keywords: ['图库'],
    date: '2026-06-01',
    embeddingRef: '',
    embeddingStatus: '',
    embeddingDimension: 0,
    error: '',
    latitude: 31.024267,
    longitude: 121.437828,
    exif: {
      dateTimeOriginal: '2026:06:01 09:08:07',
      deviceMake: 'Huawei',
      deviceModel: 'Pura 80'
    },
    location: {
      key: '31.024267,121.437828',
      provider: 'amap',
      rawLatitude: 31.024267,
      rawLongitude: 121.437828,
      amapLatitude: 31.024267,
      amapLongitude: 121.437828,
      formattedAddress: '上海市闵行区东川路 800 号',
      province: '上海市',
      city: '上海市',
      district: '闵行区',
      township: '江川路街道',
      street: '东川路',
      poiName: '上海交通大学',
      updatedAt: 1760000000000
    },
    createdAt: 1760000000000
  };
}

function demoCollectionGroupState(id: string, title: string, events: IndexedEvent[]): CollectionGroupState {
  let eventMap = demoEventMap(events);
  let hashes = createStringMap();
  let eventIds = events.map((event: IndexedEvent): string => {
    hashes[event.event_id] = collectionGroupEventInputFingerprint(event);
    return event.event_id;
  });
  let time = '';
  events.forEach((event: IndexedEvent) => {
    if (event.event_date > time) {
      time = event.event_date;
    }
  });
  return {
    group_id: id,
    title: title,
    source: events.length > 0 ? events[0].sources[0] : '',
    time: time,
    meta: `${eventIds.length} 条`,
    status: '已整理',
    domain: events.length > 0 ? events[0].domains[0] : 'other',
    event_ids: eventIds,
    source_input_hash: collectionGroupSourceInputFingerprint(eventIds, eventMap),
    event_input_hashes: hashes
  };
}

function demoAvatarProfileDomainState(domain: string, displayName: string, shortSummary: string, summary: string, claims: string[]): ProfileDomainState {
  let profileClaims: ProfileClaim[] = claims.map((statement: string): ProfileClaim => {
    return {
      statement: statement,
      kind: 'preference',
      confidence: 'high',
      event_ids: ['e1', 'e2'],
      evidence_count: 2,
      start_date: '2026-06-01',
      end_date: '2026-06-10',
      example: statement
    };
  });
  return {
    domain: domain,
    display_name: displayName,
    input_hash: domain + '-hash',
    event_ids: ['e1', 'e2'],
    event_count: 2,
    date_range: createStringMap(),
    short_summary: shortSummary,
    summary: summary,
    claims: profileClaims,
    generation: 'model'
  };
}

function demoProfileStateForAvatar(): ProfileState {
  let domains = new Object() as Record<string, ProfileDomainState>;
  domains['eat'] = demoAvatarProfileDomainState('eat', '吃', '咖啡轻食', '近期记录显示用户关注咖啡、轻食和外卖效率。', ['经常围绕咖啡和轻食做选择']);
  domains['wear'] = demoAvatarProfileDomainState('wear', '穿', '简洁舒适', '穿搭相关记录偏向简洁、舒适和实用。', []);
  domains['live'] = demoAvatarProfileDomainState('live', '住', '桌面收纳', '居住相关记录关注桌面整理和空间收纳。', []);
  domains['travel'] = demoAvatarProfileDomainState('travel', '行', '地铁通勤', '出行记录以地铁通勤和计划执行为主。', []);
  return {
    generated_at: '2026-06-10 10:07:00',
    event_count: 12,
    event_date_range: createStringMap(),
    domains: domains,
    claim_count: 1
  };
}

export default function dataManagerUnitTest() {
  describe('dataManagerUnitTest', () => {
    it('parseDailyLogDocument', 0, () => {
      let content = '<!-- DAILY_LOG_METADATA\n{"workflow_metadata":{"name":"demo"},"latest_entry_index":2}\n-->\n\n1. 第一条\n\n2. 第二条';
      let doc = parseDailyLogDocument(content);
      expect(doc.latest_entry_index).assertEqual(2);
      let entries = parseNumberedEntries(doc.body);
      expect(entries.length).assertEqual(2);
      expect(entries[0].index).assertEqual(1);
    });

    it('parseNumberedEntriesIgnoresNestedLists', 0, () => {
      let body = '1. 这段聊天记录主要围绕手机刷机故障处理展开，具体内容如下：\n' +
        '1. **故障描述**：手机出现 Magisk 图标异常。\n' +
        '2. **处理方案**：预约线下重新刷机。\n' +
        '3. **回应**：建议先暂停折腾。\n\n' +
        '2. 第二条顶层记录，讨论 workflow 替代 cli 的可行性。';
      let entries = parseNumberedEntries(body);
      expect(entries.length).assertEqual(2);
      expect(entries[0].index).assertEqual(1);
      expect(entries[0].text.indexOf('故障描述') >= 0).assertTrue();
      expect(entries[1].index).assertEqual(2);
    });

    it('galleryMemorySyncWritesParseableDailyLogWithMetadata', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('daily-log');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('food-001', '餐饮', '牛肉面照片', '午餐吃了牛肉面'));
      let failed = galleryMemoryItem('failed-001', '餐饮', '失败照片', '失败摘要');
      failed.error = 'model error';
      galleryMemoryWriteItem(root, failed);
      let empty = galleryMemoryItem('empty-001', '餐饮', '', '');
      empty.details = [];
      empty.ocrText = '';
      galleryMemoryWriteItem(root, empty);

      let result: GalleryMemorySyncResult = GalleryMemorySync.sync(root);

      expect(result.scannedItemCount).assertEqual(3);
      expect(result.exportedEntryCount).assertEqual(1);
      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__餐饮.md';
      let doc = parseDailyLogDocument(storage.readText(path, ''));
      expect(Number(doc.workflow_metadata['task_scene_id'])).assertEqual(galleryMemorySceneIdForCategory('餐饮'));
      expect(String(doc.workflow_metadata['source_kind'])).assertEqual('gallery');
      expect(String(doc.workflow_metadata['gallery_category'])).assertEqual('餐饮');
      expect(doc.latest_entry_index > 0).assertTrue();
      let entries = parseNumberedEntries(doc.body);
      expect(entries.length).assertEqual(1);
      expect(entries[0].text.indexOf('牛肉面照片') >= 0).assertTrue();
      expect(entries[0].text.indexOf('OCR-food-001') >= 0).assertTrue();
      storage.removeTree(root);
    });

    it('galleryMemorySyncRecoversFieldsFromLegacyRawModelText', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('legacy-raw-model');
      storage.removeTree(root);
      let legacy = galleryMemoryItem('legacy-001', '其他', '图库图片', '{ "title": "生活记忆", "category": "餐饮", "summary": 这张图展示了与饮食相关的照片和日常使用场景。');
      legacy.details = [];
      legacy.tags = [];
      legacy.rawModelText = '{\n' +
        '  "title": "生活记忆",\n' +
        '  "category": "餐饮",\n' +
        '  "summary": 这张图展示了与饮食相关的照片和日常使用场景。",\n' +
        '  "details": [\n' +
        '    "桌上有咖啡杯和咖啡壶，表明餐饮活动",\n' +
        '    "近期积极购入手冲咖啡器具"\n' +
        '  ],\n' +
        '  "tags": ["饮食", "外卖", "餐饮"]\n' +
        '}';
      galleryMemoryWriteItem(root, legacy);

      GalleryMemorySync.sync(root);

      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__餐饮.md';
      let doc = parseDailyLogDocument(storage.readText(path, ''));
      expect(Number(doc.workflow_metadata['task_scene_id'])).assertEqual(galleryMemorySceneIdForCategory('餐饮'));
      expect(String(doc.workflow_metadata['gallery_category'])).assertEqual('餐饮');
      let entries = parseNumberedEntries(doc.body);
      expect(entries.length).assertEqual(1);
      expect(entries[0].text.indexOf('生活记忆') >= 0).assertTrue();
      expect(entries[0].text.indexOf('这张图展示了与饮食相关') >= 0).assertTrue();
      expect(entries[0].text.indexOf('手冲咖啡器具') >= 0).assertTrue();
      expect(entries[0].text.indexOf('饮食、外卖、餐饮') >= 0).assertTrue();
      storage.removeTree(root);
    });

    it('galleryMemorySceneConfigsKeepWorkflowScenesStable', 0, () => {
      expect(galleryMemorySceneIdForCategory('聊天')).assertEqual(3);
      expect(galleryMemorySceneIdForCategory('购物')).assertEqual(0);
      expect(galleryMemorySceneIdForCategory('出行')).assertEqual(6);
      expect(galleryMemorySceneIdForCategory('餐饮')).assertEqual(1);
      expect(galleryMemorySceneIdForCategory('文档')).assertEqual(8);
      expect(galleryMemorySceneIdForCategory('健康')).assertEqual(9);
      expect(galleryMemorySceneIdForCategory('工作')).assertEqual(10);
      expect(galleryMemorySceneIdForCategory('其他')).assertEqual(11);

      expect(workflowSceneConfigs().length).assertEqual(7);
      let memoryScenes: WorkflowSceneConfig[] = memorySceneConfigs();
      expect(memoryScenes.length > workflowSceneConfigs().length).assertTrue();
      expect(memoryScenes.filter((scene: WorkflowSceneConfig): boolean => scene.label === '餐饮').length).assertEqual(0);
      expect(collectionTabSpecs().filter((spec: CollectionTabSpec): boolean => spec.title === '餐饮记录').length).assertEqual(0);
      expect(memoryScenes.filter((scene: WorkflowSceneConfig): boolean => scene.label === '图库').length).assertEqual(1);
      let foodSpec = collectionTabSpecByIndex(galleryMemorySceneIdForCategory('餐饮'));
      expect(foodSpec.title).assertEqual('外卖记录');
      expect(foodSpec.query.workflowSceneIds[0]).assertEqual(1);
      expect(collectionTabSpecByIndex(7).title).assertEqual('外卖记录');
      expect(memorySceneLabel(7)).assertEqual('外卖');
      let normalizedLegacyScenes = normalizeMemorySceneIds([7, 1]);
      expect(normalizedLegacyScenes.length).assertEqual(1);
      expect(normalizedLegacyScenes[0]).assertEqual(1);
    });

    it('collectionViewModelByTabIndexUsesSceneIdInsteadOfArrayOffset', 0, () => {
      let emptyViews: CollectionViewModel[] = createEmptyCollectionViewModels();

      expect(collectionViewModelByTabIndex(emptyViews, 8).title).assertEqual('文档记录');
      expect(collectionViewModelByTabIndex(emptyViews, 9).title).assertEqual('健康记录');
      expect(collectionViewModelByTabIndex(emptyViews, 10).title).assertEqual('办公记录');
      expect(collectionViewModelByTabIndex(emptyViews, 11).title).assertEqual('图库记录');
      expect(collectionViewModelByTabIndex(emptyViews, 7).title).assertEqual('外卖记录');
    });

    it('indexQueryMatchesLegacyGalleryFoodSceneSeven', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('legacy-scene-query');
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      paths.ensureBaseDirs();
      let service = new IndexService(paths, storage, new DataPipelineModelClient());
      let legacyEvent: IndexedEvent = demoIndexedEvent('e7', '图库餐饮记录', 'photos', 'eat', '餐饮');
      legacyEvent.event_date = '2026-06-01';
      legacyEvent.last_seen_date = '2026-06-01';
      legacyEvent.workflow_scene_ids = [7];
      let partition: EventPartition = {
        month: '2026-06',
        events: [legacyEvent]
      };
      let partitionIndex: TestEventPartitionIndex = {
        schema: 'datamanager-event-partition-index-v1',
        generated_at: '2026-06-18T21:07:00',
        partition_files: ['2026-06.json']
      };
      let postings: StringArrayMap = {};
      postings['7'] = ['e7'];
      let workflowSceneDocument: TestWorkflowSceneDocument = {
        postings: postings
      };
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'events', '2026-06.json'), partition as Object);
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'events', 'partition-index.json'), partitionIndex as Object);
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'workflow-scene', 'index.json'), workflowSceneDocument as Object);

      let foodQuery: QueryResult = service.query({
        keywords: [],
        domains: [],
        entities: [],
        date: '',
        month: '',
        startDate: '',
        endDate: '',
        workflowSceneIds: [1],
        limit: 0
      });
      let legacyQuery: QueryResult = service.query({
        keywords: [],
        domains: [],
        entities: [],
        date: '',
        month: '',
        startDate: '',
        endDate: '',
        workflowSceneIds: [7],
        limit: 0
      });

      expect(foodQuery.total_events).assertEqual(1);
      expect(foodQuery.events[0].workflow_scene_ids[0]).assertEqual(1);
      expect(legacyQuery.total_events).assertEqual(1);
      storage.removeTree(root);
    });

    it('sourceEntryProcessingHashChangesWhenWorkflowSceneChanges', 0, () => {
      let storage = galleryMemoryStorage();
      let entry: SourceEntry = {
        source_date: '2026-06-01',
        file_name: 'com.huawei.photos__gallery-analysis__餐饮.md',
        entry_index: 1,
        entry_text: '同一张餐饮图片的分析结果',
        workflow_metadata: createJsonMap(),
        workflow_scene_id: 7,
        source_ref: '2026-06-01/com.huawei.photos__gallery-analysis__餐饮.md#1'
      };
      let oldHash = sourceEntryProcessingHash(storage, entry);
      entry.workflow_scene_id = galleryMemorySceneIdForCategory('餐饮');
      let nextHash = sourceEntryProcessingHash(storage, entry);

      expect(oldHash === nextHash).assertFalse();
    });

    it('galleryMemorySyncKeepsEntryIndexStableWhenNewItemsArrive', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('stable-index');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('stable-001', '餐饮', '第一张餐饮图', '第一条摘要'));
      GalleryMemorySync.sync(root);
      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__餐饮.md';
      let firstEntries: NumberedEntry[] = parseNumberedEntries(parseDailyLogDocument(storage.readText(path, '')).body);
      let firstIndex: number = firstEntries[0].index;

      galleryMemoryWriteItem(root, galleryMemoryItem('stable-999', '餐饮', '第二张餐饮图', '第二条摘要'));
      GalleryMemorySync.sync(root);
      let secondEntries: NumberedEntry[] = parseNumberedEntries(parseDailyLogDocument(storage.readText(path, '')).body);
      let stableEntry: NumberedEntry = secondEntries.filter((entry: NumberedEntry): boolean =>
        entry.text.indexOf('第一张餐饮图') >= 0)[0];

      expect(stableEntry.index).assertEqual(firstIndex);
      storage.removeTree(root);
    });

    it('galleryMemorySyncDeletesOldExportsWhenGalleryIsEmpty', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('clear');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('clear-001', '文档', '文档截图', '一张文档截图'));
      GalleryMemorySync.sync(root);
      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__文档.md';
      expect(storage.exists(path)).assertTrue();

      storage.removeTree(root + '/gallery-log/items');
      let result: GalleryMemorySyncResult = GalleryMemorySync.sync(root);

      expect(result.exportedFileCount).assertEqual(0);
      expect(storage.exists(path)).assertFalse();
      storage.removeTree(root);
    });

    it('galleryMemorySyncResolvesImageRefsForSourceRefs', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('image-refs');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('image-001', '文档', '报告截图', '报告内容截图'));
      GalleryMemorySync.sync(root);
      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__文档.md';
      let entry = parseNumberedEntries(parseDailyLogDocument(storage.readText(path, '')).body)[0];
      let refs: string[] = GalleryMemorySync.imageRefsForSourceRefs(root, root + '/workflows/daily-log',
        ['2026-06-01/com.huawei.photos__gallery-analysis__文档.md#' + String(entry.index)]);

      expect(refs.length).assertEqual(1);
      expect(refs[0]).assertEqual('gallery-log/items/2026-06-01/image-001.json#uri');
      storage.removeTree(root);
    });

    it('galleryMemorySyncReturnsDetailsForSourceRefs', 0, () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('details');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('detail-001', '健康', '跑步记录', '晨跑后的健康记录'));
      GalleryMemorySync.sync(root);
      let path = root + '/workflows/daily-log/2026-06-01/com.huawei.photos__gallery-analysis__健康.md';
      let entry = parseNumberedEntries(parseDailyLogDocument(storage.readText(path, '')).body)[0];
      let details: CollectionGalleryDetailViewModel[] = GalleryMemorySync.detailsForSourceRefs(root, root + '/workflows/daily-log',
        ['2026-06-01/com.huawei.photos__gallery-analysis__健康.md#' + String(entry.index)]);

      expect(details.length).assertEqual(1);
      expect(details[0].id).assertEqual('detail-001');
      expect(details[0].uri).assertEqual('file://gallery/detail-001.jpg');
      expect(details[0].ocrText).assertEqual('OCR-detail-001');
      expect(details[0].captureTime).assertEqual('2026-06-01 09:08:07');
      expect(details[0].captureDevice).assertEqual('Huawei Pura 80');
      expect(details[0].captureLocation).assertEqual('北纬 31.024267，东经 121.437828');
      expect(details[0].address).assertEqual('上海市闵行区东川路 800 号');
      expect(details[0].poiName).assertEqual('上海交通大学');
      expect(details[0].mapUrl.indexOf('position=121.437828,31.024267') >= 0).assertTrue();
      storage.removeTree(root);
    });

    it('dataManagerRefreshIndexesGalleryMemoryEventsWithImagesAndDetails', 0, async () => {
      let storage = galleryMemoryStorage();
      let root = nextGalleryMemoryRoot('facade-refresh');
      storage.removeTree(root);
      galleryMemoryWriteItem(root, galleryMemoryItem('health-001', '健康', '晨跑健康记录', '晨跑后保存了一张健康记录截图'));

      let facade = new DataManagerFacade(root);
      await facade.refresh(disabledModelConfig());
      let view: CollectionViewModel = facade.loadCollectionViewModel(galleryMemorySceneIdForCategory('健康'));

      expect(view.empty).assertFalse();
      expect(view.groups.length > 0).assertTrue();
      expect(view.groups[0].events.length > 0).assertTrue();
      let event = view.groups[0].events[0];
      expect(event.summary.indexOf('晨跑') >= 0).assertTrue();
      expect(event.imageRefs.length).assertEqual(1);
      expect(event.imageRefs[0].ref).assertEqual('gallery-log/items/2026-06-01/health-001.json#uri');
      expect(event.imageRefs[0].uri).assertEqual('file://gallery/health-001.jpg');
      expect(event.thumbnailUri).assertEqual('file://gallery/health-001.jpg');
      expect(event.galleryDetails.length).assertEqual(1);
      expect(event.galleryDetails[0].id).assertEqual('health-001');
      expect(event.galleryDetails[0].ocrText).assertEqual('OCR-health-001');
      storage.removeTree(root);
    });

    it('sourceDisplayName', 0, () => {
      let source = sourceDisplayName('2026-05/com.tencent.wechat__01_basic_gui_task_weixin__WAIC-数据归家.md.state.json#1');
      expect(source).assertEqual('WAIC-数据归家');
      expect(sourceDisplayName('2026-05/com.tencent.wechat__01_basic_gui_task_weixin_v2__小赵.md.state.json#1')).assertEqual('小赵');
      expect(sourceAppDisplayName('2026-05/com.tencent.wechat__01_basic_gui_task_weixin_v2__小赵.md.state.json#1')).assertEqual('微信');
      expect(sourceDisplayName('2026-05/com.alipay.mobile.client__01_basic_gui_task_alipay.md.state.json#1')).assertEqual('支付宝');
      let wechatNames = eventSourceNames(
        ['2026-05/com.tencent.wechat__01_basic_gui_task_weixin_v2__小赵.md.state.json#1'],
        '2026-05/com.tencent.wechat__01_basic_gui_task_weixin_v2__小赵.md.state.json'
      );
      expect(wechatNames.length).assertEqual(2);
      expect(wechatNames[0]).assertEqual('微信');
      expect(wechatNames[1]).assertEqual('小赵');
      let xhsNames = eventSourceNames(
        ['2026-05/com.xingin.xhs_hos__01_basic_gui_task_xiaohongshu.md.state.json#1'],
        '2026-05/com.xingin.xhs_hos__01_basic_gui_task_xiaohongshu.md.state.json'
      );
      expect(xhsNames.length).assertEqual(1);
      expect(xhsNames[0]).assertEqual('小红书');
    });

    it('eventSourceNamesSkipsCollectorRunIdAndGalleryCategoryContext', 0, () => {
      let wechatAutoNames = eventSourceNames(
        ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#1'],
        '2026-06/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md.state.json'
      );
      expect(wechatAutoNames.length).assertEqual(1);
      expect(wechatAutoNames[0]).assertEqual('微信');

      let galleryNames = eventSourceNames(
        ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#574201189'],
        '2026-06/com.huawei.photos__gallery-analysis__聊天.md.state.json'
      );
      expect(galleryNames.length).assertEqual(1);
      expect(galleryNames[0]).assertEqual('图库');
    });

    it('eventSourceNamesUsesBusinessPackageDisplayNames', 0, () => {
      let names = eventSourceNames([
        '2026-06-04/com.jd.harmony__basic-gui-task.md#1',
        '2026-06-06/com.ctrip.harmony__basic-gui-task.md#1',
        '2026-06-04/com.sankuai.meituan__basic-gui-task.md#1',
        '2026-06-07/com.meituan.waimai__basic-gui-task.md#1',
        '2026-06-10/tv.danmaku.bili__basic-gui-task.md#1'
      ], '');
      expect(names.indexOf('京东') >= 0).assertTrue();
      expect(names.indexOf('携程') >= 0).assertTrue();
      expect(names.indexOf('美团') >= 0).assertTrue();
      expect(names.indexOf('美团外卖') >= 0).assertTrue();
      expect(names.indexOf('哔哩哔哩') >= 0).assertTrue();
      expect(names.indexOf('harmony') < 0).assertTrue();
      expect(names.indexOf('meituan') < 0).assertTrue();
    });

    it('indexTerms', 0, () => {
      let terms = indexTerms('高德顺风车订单');
      expect(terms.indexOf('顺风') >= 0).assertTrue();
    });

    it('weekdayLabelFromDate', 0, () => {
      expect(weekdayLabelFromDate('2026-06-05')).assertEqual('星期五');
      expect(weekdayLabelFromDate('2026-06-06')).assertEqual('星期六');
      expect(weekdayLabelFromDate('bad-date')).assertEqual('');
      expect(weekdayLabelFromDate('2026-02-31')).assertEqual('');
    });

    it('monthLastDateForTemporalIndex', 0, () => {
      expect(monthLastDateForTemporalIndex('2026-05')).assertEqual('2026-05-31');
      expect(monthLastDateForTemporalIndex('2026-06')).assertEqual('2026-06-30');
      expect(monthLastDateForTemporalIndex('2024-02')).assertEqual('2024-02-29');
    });

    it('normalizeQueryKeywordOperator', 0, () => {
      expect(normalizeQueryKeywordOperator()).assertEqual('and');
      expect(normalizeQueryKeywordOperator('')).assertEqual('and');
      expect(normalizeQueryKeywordOperator('AND')).assertEqual('and');
      expect(normalizeQueryKeywordOperator('OR')).assertEqual('or');
      expect(normalizeQueryKeywordOperator('xor')).assertEqual('and');
    });

    it('profileShortSummaryNormalization', 0, () => {
      expect(normalizeProfileShortSummary('清淡轻食')).assertEqual('清淡轻食');
      expect(normalizeProfileShortSummary('清淡轻食。')).assertEqual('清淡轻食');
      expect(normalizeProfileShortSummary('健康轻食餐')).assertEqual('');
      expect(profileShortSummaryFromText('eat', '近期咖啡、奶茶等话题反复出现。', '')).assertEqual('咖啡奶茶');
      expect(profileShortSummaryFromText('travel', '', '近期记录')).assertEqual('近期记录');
    });

    it('profileGenerationReturnsEmptyWhenModelUnavailable', 0, async () => {
      let client = new DataPipelineModelClient();
      let event = demoIndexedEvent('e1', '近期咖啡、奶茶等话题反复出现。', '微信', 'eat', '咖啡');
      let payload = await client.generateProfile('eat', [event], [], disabledModelConfig());
      expect(payload.summary).assertEqual('');
      expect(payload.short_summary).assertEqual('');
      expect(payload.claims.length).assertEqual(0);
      expect(payload.generation).assertEqual('model_unavailable');
    });

    it('profileDomainStateDoesNotDeriveMissingSummary', 0, () => {
      let range = createStringMap();
      range.start_date = '2026-05-29';
      range.end_date = '2026-05-30';
      let payload: ProfileModelPayload = {
        short_summary: '咖啡奶茶',
        summary: '模型给出的摘要不应在无有效 claims 时落盘',
        claims: [],
        generation: 'model'
      };
      let emptyState = buildProfileDomainStateFromPayload('eat', 'hash', ['e1', 'e2'], 2, range, payload, []);
      expect(emptyState.summary).assertEqual('');
      expect(emptyState.short_summary).assertEqual('');
      expect(emptyState.claims.length).assertEqual(0);
      expect(emptyState.generation).assertEqual('model_empty');

      let modelState = buildProfileDomainStateFromPayload('eat', 'hash', ['e1', 'e2'], 2, range, {
        short_summary: '',
        summary: '',
        claims: [],
        generation: 'model'
      }, [demoProfileClaim('用户在多条记录中关注咖啡和奶茶。')]);
      expect(modelState.summary).assertEqual('');
      expect(modelState.short_summary).assertEqual('');
      expect(modelState.claims.length).assertEqual(1);
      expect(modelState.generation).assertEqual('model');
    });

    it('profileDomainReuseRejectsHeuristicAndFailureStates', 0, () => {
      expect(isProfileDomainStateReusable(demoProfileDomainState('heuristic'), 2)).assertFalse();
      expect(isProfileDomainStateReusable(demoProfileDomainState('model_error'), 2)).assertFalse();
      expect(isProfileDomainStateReusable(demoProfileDomainState('model_unavailable'), 2)).assertFalse();
      expect(isProfileDomainStateReusable(demoProfileDomainState('model'), 2)).assertTrue();
      expect(isProfileDomainStateReusable(demoProfileDomainState('model_empty'), 2)).assertTrue();
      expect(isProfileDomainStateReusable(demoProfileDomainState('empty'), 2)).assertFalse();
      expect(isProfileDomainStateReusable(demoProfileDomainState('empty'), 0)).assertTrue();
    });

    it('homeProfileDescriptionShowsExistingProfileWithoutShortSummary', 0, () => {
      let state = demoProfileDomainState('model');
      state.summary = '模型已经生成了完整的饮食画像。';
      state.claims = [demoProfileClaim('用户在多条记录中关注咖啡和奶茶。')];
      expect(homeProfileDomainDescription(state)).assertEqual('查看画像');
      expect(homeProfileDomainFullDescription(state)).assertEqual('模型已经生成了完整的饮食画像。');

      state.short_summary = '咖啡奶茶';
      expect(homeProfileDomainDescription(state)).assertEqual('咖啡奶茶');
    });

    it('homeProfileCompletenessCountsVisibleProfileDomains', 0, () => {
      expect(homeProfileCompleteness([
        demoHomeDomain('eat', '暂无数据'),
        demoHomeDomain('wear', '暂无数据'),
        demoHomeDomain('live', '暂无数据'),
        demoHomeDomain('travel', '暂无数据')
      ])).assertEqual(0);
      expect(homeProfileCompleteness([
        demoHomeDomain('eat', '查看画像'),
        demoHomeDomain('wear', '暂无数据'),
        demoHomeDomain('live', '暂无数据'),
        demoHomeDomain('travel', '暂无数据')
      ])).assertEqual(25);
      expect(homeProfileCompleteness([
        demoHomeDomain('eat', '查看画像'),
        demoHomeDomain('wear', '简约舒适'),
        demoHomeDomain('live', '暂无数据'),
        demoHomeDomain('travel', '暂无数据')
      ])).assertEqual(50);
      expect(homeProfileCompleteness([
        demoHomeDomain('eat', '查看画像'),
        demoHomeDomain('wear', '简约舒适'),
        demoHomeDomain('live', '整洁有序'),
        demoHomeDomain('travel', '地铁通勤')
      ])).assertEqual(100);
    });

    it('atomicizeCandidateFacts', 0, () => {
      let entry: SourceEntry = {
        source_date: '2026-05-21',
        file_name: 'demo.md',
        entry_index: 1,
        entry_text: '当前页面显示了订单记录，其中最近一单是潮汕牛肉火锅实付25.8元，第二单是大米先生实付23.9元。',
        workflow_metadata: createJsonMap(),
        workflow_scene_id: 1,
        source_ref: '2026-05-21/demo.md#1'
      };
      let fact: CandidateFact = {
        summary: entry.entry_text,
        normalized_fact: entry.entry_text,
        event_date: '2026-05-21',
        tags: [],
        model_notes: 'test',
        raw_excerpt: entry.entry_text,
        source_ref: entry.source_ref,
        source_date: entry.source_date,
        workflow_scene_id: entry.workflow_scene_id,
        dedup_text: entry.entry_text
      };
      let facts = atomicizeCandidateFacts(entry, [fact]);
      expect(facts.length).assertEqual(2);
      expect(facts[0].normalized_fact.indexOf('25.8元') >= 0).assertTrue();
      expect(facts[1].normalized_fact.indexOf('23.9元') >= 0).assertTrue();
    });

    it('findExactExistingMatchSameSourceNeedsSameFact', 0, () => {
      let record: AggregatedRecord = {
        record_id: 1,
        first_seen_date: '2026-05-21',
        last_seen_date: '2026-05-21',
        source_refs: ['2026-05-21/demo.md#1'],
        source_dates: ['2026-05-21'],
        workflow_scene_ids: [1],
        summary: '潮汕牛肉火锅实付25.8元',
        normalized_fact: '潮汕牛肉火锅实付25.8元',
        raw_excerpts: [],
        tags: [],
        dedup_status: 'new',
        model_notes: [],
        dedup_text: '潮汕牛肉火锅实付25.8元'
      };
      let fact: CandidateFact = {
        summary: '大米先生实付23.9元',
        normalized_fact: '大米先生实付23.9元',
        event_date: '2026-05-21',
        tags: [],
        model_notes: 'test',
        raw_excerpt: '',
        source_ref: '2026-05-21/demo.md#1',
        source_date: '2026-05-21',
        workflow_scene_id: 1,
        dedup_text: '大米先生实付23.9元'
      };
      let match = findExactExistingMatch([record], fact);
      expect(match === null).assertTrue();
    });

    it('selectRecentScopeRecordsUsesEventDateAndFirstSeenWindow', 0, () => {
      let recent = demoAggregatedRecord(1, '2026-05-24', '2026-06-01', '近期订单');
      let tooOldButTouched = demoAggregatedRecord(2, '2026-05-23', '2026-06-01', '很早之前的订单');
      let future = demoAggregatedRecord(3, '2026-05-31', '2026-05-31', '未来记录');
      let fact = demoCandidateFact('2026-05-30', '2026-06-01', '新增订单');
      let scoped = selectRecentScopeRecords([recent, tooOldButTouched, future], fact);
      expect(scoped.length).assertEqual(1);
      expect(scoped[0].record_id).assertEqual(1);
    });

    it('selectRecentScopeRecordsDoesNotFallbackToRecentCount', 0, () => {
      let oldRecord = demoAggregatedRecord(1, '2026-05-01', '2026-06-01', '很早之前的订单');
      let fact = demoCandidateFact('2026-05-30', '2026-06-01', '新增订单');
      let scoped = selectRecentScopeRecords([oldRecord], fact);
      expect(scoped.length).assertEqual(0);
    });

    it('selectRecentScopeRecordsFallsBackToSourceDateWhenEventDateInvalid', 0, () => {
      let sourceDateMatch = demoAggregatedRecord(1, '2026-06-01', '2026-06-01', '来源日期附近订单');
      let eventDateOnlyMatch = demoAggregatedRecord(2, '2026-05-25', '2026-05-25', '无效事件日期附近订单');
      let fact = demoCandidateFact('', '2026-06-01', '新增订单');
      let scoped = selectRecentScopeRecords([sourceDateMatch, eventDateOnlyMatch], fact);
      expect(scoped.length).assertEqual(1);
      expect(scoped[0].record_id).assertEqual(1);
    });

    it('exactMatchCannotMergeOutsideRecentScope', 0, () => {
      let oldRecord = demoAggregatedRecord(1, '2026-05-01', '2026-06-01', '同一条订单');
      let fact = demoCandidateFact('2026-05-30', '2026-06-01', '同一条订单');
      let scoped = selectRecentScopeRecords([oldRecord], fact);
      let match = findExactExistingMatch(scoped, fact);
      expect(scoped.length).assertEqual(0);
      expect(match === null).assertTrue();
    });

    it('normalizeCollectionGroupsValidatesIdsAndBackfills', 0, () => {
      let events = [
        demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐'),
        demoIndexedEvent('e2', '微信里讨论周末晚餐', '微信聊天', 'eat', '晚餐'),
        demoIndexedEvent('e3', '微信里讨论出游路线', '微信聊天', 'travel', '出游')
      ];
      let candidate: CollectionGroupState = {
        group_id: 'raw-1',
        title: '晚餐计划',
        source: '微信聊天',
        time: '',
        meta: '',
        status: '',
        domain: 'eat',
        event_ids: ['e1', 'missing', 'e1', 'e2'],
        source_input_hash: '',
        event_input_hashes: createStringMap()
      };
      let groups = normalizeCollectionGroups('chat', '最近聊天', events, [candidate]);
      let ids: string[] = [];
      groups.forEach((group: CollectionGroupState) => ids = ids.concat(group.event_ids));
      expect(groups.length >= 2).assertTrue();
      expect(ids.indexOf('missing') < 0).assertTrue();
      expect(ids.length).assertEqual(3);
    });

    it('heuristicCollectionGroupsByChatTopic', 0, () => {
      let events = [
        demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐'),
        demoIndexedEvent('e2', '微信里继续讨论晚餐安排', '微信聊天', 'eat', '晚餐')
      ];
      let groups = heuristicCollectionGroups('chat', '最近聊天', events);
      expect(groups.length).assertEqual(1);
      expect(groups[0].event_ids.length).assertEqual(2);
    });

    it('heuristicChatGroupsPreferWechatAutoContactOverRunId', 0, () => {
      let xz = demoIndexedEvent('e1', '用户于2026-06-15与联系人小赵沟通工作UI优化任务及高德相关代码/信息', '微信', 'work', 'UI');
      xz.sources = ['微信', 'wechat-20260618T105024'];
      xz.source_refs = ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#1'];
      xz.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      xz.entities = ['person:小赵'];
      let xm = demoIndexedEvent('e2', '用户于2026-06-16与联系人小铭讨论图片标签解析异常和模型参数配置', '微信', 'work', '模型');
      xm.sources = ['微信', 'wechat-20260618T105024'];
      xm.source_refs = ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#2'];
      xm.entity_mentions = [{ type: 'person', name: '小铭', aliases: [] }];
      xm.entities = ['person:小铭'];
      let transfer = demoIndexedEvent('e3', '## 微信联系人「文件传输助手」当前可见页面消息采集 - 联系人：文件传输助手 - 会话标题：文件传输助手 - 消息数：0', '微信', 'other', '文件传输助手');
      transfer.sources = ['微信', 'wechat-20260618T105024'];
      transfer.source_refs = ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#4'];

      let groups = heuristicCollectionGroups('chat', '聊天记录', [xz, xm, transfer]);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(groups.length).assertEqual(3);
      expect(titles.indexOf('与wechat-20260618T105024的对话') < 0).assertTrue();
      expect(titles.indexOf('小赵-UI') >= 0 || titles.indexOf('小赵-工作UI优化任务') >= 0).assertTrue();
      expect(titles.indexOf('小铭-模型') >= 0 || titles.indexOf('小铭-图片标签解析异常') >= 0).assertTrue();
      expect(titles.indexOf('文件传输助手-微信联系人') >= 0 || titles.indexOf('文件传输助手-聊天记录') >= 0).assertTrue();
    });

    it('normalizesChatGroupTitlesToConversationAndTopic', 0, () => {
      let bug = demoIndexedEvent('e101', '小赵要求明天下午两点前修复bug并提交PR', '微信', 'work', 'bug');
      bug.sources = ['微信', '小赵'];
      bug.source_refs = ['2026-06-11/com.tencent.wechat__basic-gui-task__小赵.md#6'];
      bug.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      bug.entities = ['person:小赵'];
      let register = demoIndexedEvent('e102', '小赵提醒明天上午领取注册条', '微信', 'work', '领取注册条');
      register.sources = ['微信', '小赵'];
      register.source_refs = ['2026-06-11/com.tencent.wechat__basic-gui-task__小赵.md#7'];
      register.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      register.entities = ['person:小赵'];

      let groups = normalizeCollectionGroups('chat', '聊天记录', [bug, register], [
        demoCollectionGroupState('g-bug', 'Bug修复与PR', [bug]),
        demoCollectionGroupState('g-register', '领取注册条', [register])
      ]);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('小赵-Bug修复与PR') >= 0).assertTrue();
      expect(titles.indexOf('小赵-领取注册条') >= 0).assertTrue();
      expect(titles.indexOf('与小赵的对话') < 0).assertTrue();
    });

    it('normalizesChatTitlesWithoutUsingPlaceOrMerchantAsConversation', 0, () => {
      let travel = demoIndexedEvent('e103', '小赵计划周末去苏州看展', '微信', 'travel', '苏州看展');
      travel.sources = ['微信', '小赵'];
      travel.source_refs = ['2026-06-02/com.tencent.wechat__basic-gui-task__小赵.md#3'];
      travel.entity_mentions = [{ type: 'place', name: '苏州', aliases: [] }];
      travel.entities = ['place:苏州'];
      let takeout = demoIndexedEvent('e104', '小赵提及上周饿了么订单需补充发票抬头', '微信', 'other', '发票需求');
      takeout.sources = ['微信', '小赵'];
      takeout.source_refs = ['2026-06-02/com.tencent.wechat__basic-gui-task__小赵.md#2'];
      takeout.entity_mentions = [{ type: 'merchant', name: '饿了么', aliases: ['饿了么订单'] }];
      takeout.entities = ['merchant:饿了么'];

      let groups = normalizeCollectionGroups('chat', '聊天记录', [travel, takeout], [
        demoCollectionGroupState('g-travel', '与苏州的对话', [travel]),
        demoCollectionGroupState('g-takeout', '与饿了么的对话', [takeout])
      ]);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('小赵-苏州看展') >= 0).assertTrue();
      expect(titles.indexOf('小赵-发票需求') >= 0).assertTrue();
      expect(titles.indexOf('与苏州的对话') < 0).assertTrue();
      expect(titles.indexOf('与饿了么的对话') < 0).assertTrue();
    });

    it('normalizesGroupChatTitlesToGroupAndTopic', 0, () => {
      let hdc = demoIndexedEvent('e105', '群成员讨论HDC导入脚本，建议默认使用bundle alias路径', '微信', 'other', 'HDC脚本优化');
      hdc.sources = ['微信', '产品群'];
      hdc.source_refs = ['2026-06-05/com.tencent.wechat__basic-gui-task__产品群.md#4'];
      hdc.entity_mentions = [{ type: 'place', name: 'HDC导入脚本', aliases: ['脚本'] }];
      hdc.entities = ['place:HDC导入脚本'];

      let groups = normalizeCollectionGroups('chat', '聊天记录', [hdc], [
        demoCollectionGroupState('g-hdc', '与HDC导入脚本的对话', [hdc])
      ]);
      expect(groups.length).assertEqual(1);
      expect(groups[0].title).assertEqual('产品群-HDC脚本优化');
    });

    it('normalizesChatTitlesRejectsObjectLikeSourceDetailAndGenericContact', 0, () => {
      let sourceObject = demoIndexedEvent('e109', '当前页面显示群成员在讨论 HDC 导入脚本，建议默认使用 bundle alias 路径。', '微信', 'other', 'HDC脚本优化');
      sourceObject.sources = ['微信', 'HDC导入脚本'];
      sourceObject.source_refs = ['2026-06-05/com.tencent.wechat__basic-gui-task__产品群.md#4'];
      sourceObject.entity_mentions = [{ type: 'place', name: 'HDC导入脚本', aliases: ['脚本'] }];
      sourceObject.entities = ['place:HDC导入脚本'];
      let genericMerchant = demoIndexedEvent('e110', '用户与饿了么沟通上周订单发票抬头。', '微信', 'other', '发票需求');
      genericMerchant.sources = ['微信'];
      genericMerchant.entity_mentions = [{ type: 'merchant', name: '饿了么', aliases: ['饿了么订单'] }];
      genericMerchant.entities = ['merchant:饿了么'];
      let sourcePlaceWithoutEntity = demoIndexedEvent('e111', '用户讨论苏州周末路线。', '微信', 'travel', '周末路线');
      sourcePlaceWithoutEntity.sources = ['微信', '苏州'];
      let sourceMerchantWithoutEntity = demoIndexedEvent('e112', '用户讨论饿了么订单发票。', '微信', 'other', '发票需求');
      sourceMerchantWithoutEntity.sources = ['微信', '饿了么'];
      let directMetadataObject = demoIndexedEvent('e117',
        '微信联系人「HDC导入脚本」当前页面显示 HDC 导入脚本配置 - 联系人：HDC导入脚本 - 会话标题：HDC导入脚本',
        '微信', 'other', '脚本配置优化');
      directMetadataObject.sources = ['微信'];
      directMetadataObject.entity_mentions = [{ type: 'tool', name: 'HDC导入脚本', aliases: ['脚本'] }];
      directMetadataObject.entities = ['tool:HDC导入脚本'];
      let legacySourcePlaceGroup = demoCollectionGroupState('g-source-place', '周末路线', [sourcePlaceWithoutEntity]);
      legacySourcePlaceGroup.source = '苏州';
      let legacySourceMerchantGroup = demoCollectionGroupState('g-source-merchant', '发票需求', [sourceMerchantWithoutEntity]);
      legacySourceMerchantGroup.source = '饿了么';

      let groups = normalizeCollectionGroups('chat', '聊天记录',
        [sourceObject, genericMerchant, sourcePlaceWithoutEntity, sourceMerchantWithoutEntity, directMetadataObject], [
        demoCollectionGroupState('g-source-object', 'HDC脚本优化', [sourceObject]),
        demoCollectionGroupState('g-merchant', '发票需求', [genericMerchant]),
        legacySourcePlaceGroup,
        legacySourceMerchantGroup,
        demoCollectionGroupState('g-direct-object', '脚本配置优化', [directMetadataObject])
      ]);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('HDC导入脚本-HDC脚本优化') < 0).assertTrue();
      expect(titles.indexOf('HDC导入脚本-脚本配置优化') < 0).assertTrue();
      expect(titles.indexOf('饿了么-发票需求') < 0).assertTrue();
      expect(titles.indexOf('苏州-周末路线') < 0).assertTrue();
      expect(titles.indexOf('微信-HDC脚本优化') >= 0).assertTrue();
      expect(titles.indexOf('微信-脚本配置优化') >= 0).assertTrue();
      expect(titles.indexOf('微信-发票需求') >= 0).assertTrue();
      expect(titles.indexOf('微信-周末路线') >= 0).assertTrue();
    });

    it('normalizesBusinessTabTitlesToSourceAndTopic', 0, () => {
      let shoe = demoIndexedEvent('e106', '浏览耐克官方店铺Air Zoom Pegasus跑鞋详情', 'taobao', 'wear', '耐克跑鞋浏览');
      shoe.sources = ['taobao'];
      shoe.entity_mentions = [{ type: 'merchant', name: '耐克', aliases: ['Nike Official Store'] }];
      shoe.entities = ['merchant:耐克'];
      let takeout = demoIndexedEvent('e107', '中午在美团外卖下单黄焖鸡米饭', 'waimai', 'eat', '黄焖鸡');
      takeout.sources = ['waimai', 'llm-takeout-美团外卖'];
      takeout.entity_mentions = [{ type: 'merchant', name: '美团外卖', aliases: [] }];
      takeout.entities = ['merchant:美团外卖'];
      let video = demoIndexedEvent('e108', '浏览苏州旅行 Vlog', 'bili', 'travel', '苏州旅行Vlog');
      video.sources = ['bili'];

      let shoppingGroups = normalizeCollectionGroups('shopping', '购物记录', [shoe], [
        demoCollectionGroupState('g-shoe', '耐克跑鞋浏览', [shoe])
      ]);
      let takeoutGroups = normalizeCollectionGroups('takeout', '外卖记录', [takeout], [
        demoCollectionGroupState('g-chicken', '黄焖鸡', [takeout])
      ]);
      let entertainmentGroups = normalizeCollectionGroups('entertainment', '娱乐记录', [video], [
        demoCollectionGroupState('g-vlog', '苏州旅行 Vlog', [video])
      ]);

      expect(shoppingGroups[0].title).assertEqual('淘宝-耐克跑鞋浏览');
      expect(takeoutGroups[0].title).assertEqual('美团外卖-黄焖鸡');
      expect(entertainmentGroups[0].title).assertEqual('哔哩哔哩-苏州旅行Vlog');
    });

    it('normalizesGroupTitleSeparatorsAfterSourcePrefixRemoval', 0, () => {
      let video = demoIndexedEvent('e117', '浏览苏州旅行与咖啡测评视频', 'bili', 'travel', '苏州旅行与咖啡测评');
      video.sources = ['bili'];
      let chat = demoIndexedEvent('e118', '小赵讨论注册条领取安排', '微信', 'work', '注册条领取安排');
      chat.sources = ['微信', '小赵'];
      chat.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      chat.entities = ['person:小赵'];

      let entertainmentGroups = normalizeCollectionGroups('entertainment', '娱乐记录', [video], [
        demoCollectionGroupState('g-video', '哔哩哔哩：苏州旅行与咖啡测评', [video])
      ]);
      let chatGroups = normalizeCollectionGroups('chat', '聊天记录', [chat], [
        demoCollectionGroupState('g-chat', '小赵：注册条领取安排', [chat])
      ]);

      expect(entertainmentGroups[0].title).assertEqual('哔哩哔哩-苏州旅行与咖啡测评');
      expect(chatGroups[0].title).assertEqual('小赵-注册条领取安排');
      expect(entertainmentGroups[0].title.indexOf('-：') < 0).assertTrue();
      expect(chatGroups[0].title.indexOf('-：') < 0).assertTrue();
    });

    it('normalizesBusinessTabTitlesUsingSourceStatePackageContext', 0, () => {
      let jd = demoIndexedEvent('e113', '京东键盘退换货', 'raw-source', 'other', '键盘退换货');
      jd.sources = ['raw-source'];
      jd.source_state_file = '2026-06/raw-source.md.state.json';
      jd.source_refs = ['2026-06-04/com.jd.harmony__basic-gui-task.md#1'];
      let ctrip = demoIndexedEvent('e114', '携程显示上海至苏州高铁票订单', 'raw-source', 'travel', '上海至苏州高铁');
      ctrip.sources = ['raw-source'];
      ctrip.source_state_file = '2026-06/raw-source.md.state.json';
      ctrip.source_refs = ['2026-06-06/com.ctrip.harmony__basic-gui-task.md#1'];
      let meituanLife = demoIndexedEvent('e115', '美团生活服务页面显示理发店和按摩店收藏', 'raw-source', 'live', '生活服务');
      meituanLife.sources = ['raw-source'];
      meituanLife.source_state_file = '2026-06/raw-source.md.state.json';
      meituanLife.source_refs = ['2026-06-04/com.sankuai.meituan__basic-gui-task.md#1'];
      let meituanTakeout = demoIndexedEvent('e116', '美团外卖订单 #88291045 已送达', 'raw-source', 'eat', '黄焖鸡');
      meituanTakeout.sources = ['raw-source'];
      meituanTakeout.source_state_file = '2026-06/raw-source.md.state.json';
      meituanTakeout.source_refs = ['2026-06-07/com.sankuai.meituan__basic-gui-task__llm-takeout-Meituan.md#1'];

      let shoppingGroups = normalizeCollectionGroups('shopping', '购物记录', [jd], [
        demoCollectionGroupState('g-jd', '键盘退换货', [jd])
      ]);
      let travelGroups = normalizeCollectionGroups('travel', '差旅记录', [ctrip], [
        demoCollectionGroupState('g-ctrip', '上海至苏州高铁', [ctrip])
      ]);
      let lifeGroups = normalizeCollectionGroups('life', '生活记录', [meituanLife], [
        demoCollectionGroupState('g-life', '生活服务', [meituanLife])
      ]);
      let takeoutGroups = normalizeCollectionGroups('takeout', '外卖记录', [meituanTakeout], [
        demoCollectionGroupState('g-takeout', '黄焖鸡', [meituanTakeout])
      ]);

      expect(shoppingGroups[0].title).assertEqual('京东-键盘退换货');
      expect(travelGroups[0].title).assertEqual('携程-上海至苏州高铁');
      expect(lifeGroups[0].title).assertEqual('美团-生活服务');
      expect(takeoutGroups[0].title).assertEqual('美团外卖-黄焖鸡');
    });

    it('heuristicChatGroupsDescribeGalleryChatImagesWithoutFakeContact', 0, () => {
      let galleryEvent = demoIndexedEvent('e1',
        '[gallery-item:gallery_438498275] 手机桌面生活记忆记录：手机屏幕显示生活记忆，包含多个应用图标和文字信息。',
        'photos', 'other', '聊天记录');
      galleryEvent.sources = ['photos', '聊天'];
      galleryEvent.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];

      let groups = heuristicCollectionGroups('chat', '聊天记录', [galleryEvent]);
      expect(groups.length).assertEqual(1);
      expect(groups[0].title.indexOf('图库聊天-') === 0 || groups[0].title.indexOf('图库-') === 0).assertTrue();
    });

    it('heuristicChatGroupsKeepGalleryChatAsScreenshotWhenPersonDetected', 0, () => {
      let galleryEvent = demoIndexedEvent('e1',
        '[gallery-item:gallery_438498275] 与联系人小赵沟通当前修复进度的微信截图。',
        'photos', 'other', '聊天记录');
      galleryEvent.sources = ['photos', '聊天'];
      galleryEvent.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];
      galleryEvent.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      galleryEvent.entities = ['person:小赵'];

      let groups = heuristicCollectionGroups('chat', '聊天记录', [galleryEvent]);
      expect(groups.length).assertEqual(1);
      expect(groups[0].title.indexOf('图库聊天-') === 0 || groups[0].title.indexOf('图库-') === 0).assertTrue();
    });

    it('collectionGroupFingerprintIncludesTitleSourceSignals', 0, () => {
      let base = demoIndexedEvent('e1', '用户查看一张聊天截图。', 'photos', 'other', '聊天记录');
      let sourceRefChanged = demoIndexedEvent('e1', '用户查看一张聊天截图。', 'photos', 'other', '聊天记录');
      sourceRefChanged.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];
      let stateFileChanged = demoIndexedEvent('e1', '用户查看一张聊天截图。', 'photos', 'other', '聊天记录');
      stateFileChanged.source_state_file = '2026-06/com.huawei.photos__gallery-analysis__聊天.md.state.json';
      let entityMentionChanged = demoIndexedEvent('e1', '用户查看一张聊天截图。', 'photos', 'other', '聊天记录');
      entityMentionChanged.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];

      let baseHash = collectionGroupEventInputFingerprint(base);
      expect(collectionGroupEventInputFingerprint(sourceRefChanged) !== baseHash).assertTrue();
      expect(collectionGroupEventInputFingerprint(stateFileChanged) !== baseHash).assertTrue();
      expect(collectionGroupEventInputFingerprint(entityMentionChanged) !== baseHash).assertTrue();
    });

    it('normalizeChatGroupsUsesGenericFallbackForLowInformationTitles', 0, () => {
      let events = [
        demoIndexedEvent('e1', '联系人甲讨论一个待处理事项，后续需要继续确认。', '联系人甲', 'work', '12'),
        demoIndexedEvent('e2', '联系人乙发来一张截图，并围绕截图里的信息继续沟通。', '联系人乙', 'work', '截图'),
        demoIndexedEvent('e3', '联系人丙围绕一个技术配置项和用户继续沟通。', '联系人丙', 'work', 'API')
      ];
      let candidates: CollectionGroupState[] = [
        { group_id: 'raw-1', title: '12讨论', source: '联系人甲', time: '', meta: '', status: '', domain: 'work', event_ids: ['e1'], source_input_hash: '', event_input_hashes: createStringMap() },
        { group_id: 'raw-2', title: '截图讨论', source: '联系人乙', time: '', meta: '', status: '', domain: 'work', event_ids: ['e2'], source_input_hash: '', event_input_hashes: createStringMap() },
        { group_id: 'raw-3', title: 'API讨论', source: '联系人丙', time: '', meta: '', status: '', domain: 'work', event_ids: ['e3'], source_input_hash: '', event_input_hashes: createStringMap() }
      ];
      let groups = normalizeCollectionGroups('chat', '最近聊天', events, candidates);
      let titles = groups.map((group: CollectionGroupState) => group.title).join('|');
      expect(titles.indexOf('12讨论') < 0).assertTrue();
      expect(titles.indexOf('截图讨论') < 0).assertTrue();
      expect(titles.indexOf('API讨论') < 0).assertTrue();
      expect(titles.indexOf('联系人甲-') >= 0).assertTrue();
      expect(titles.indexOf('联系人乙-') >= 0).assertTrue();
      expect(titles.indexOf('联系人丙-') >= 0).assertTrue();
    });

    it('normalizeChatGroupsRefreshesLegacyRunIdAndCategoryTitles', 0, () => {
      let wechatEvent = demoIndexedEvent('e1', '用户于2026-06-15与联系人小赵沟通工作UI优化任务', '微信', 'work', 'UI');
      wechatEvent.sources = ['微信', 'wechat-20260618T105024'];
      wechatEvent.source_refs = ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#1'];
      wechatEvent.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      wechatEvent.entities = ['person:小赵'];
      let galleryEvent = demoIndexedEvent('e2', '[gallery-item:gallery_438498275] 手机桌面生活记忆记录。', 'photos', 'other', '聊天记录');
      galleryEvent.sources = ['photos', '聊天'];
      galleryEvent.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];
      let candidates: CollectionGroupState[] = [
        { group_id: 'legacy-wechat', title: '与wechat-20260618T105024的对话', source: '微信', time: '', meta: '', status: '', domain: 'work', event_ids: ['e1'], source_input_hash: '', event_input_hashes: createStringMap() },
        { group_id: 'legacy-gallery', title: '与聊天的对话', source: 'photos', time: '', meta: '', status: '', domain: 'other', event_ids: ['e2'], source_input_hash: '', event_input_hashes: createStringMap() }
      ];

      let groups = normalizeCollectionGroups('chat', '聊天记录', [wechatEvent, galleryEvent], candidates);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('与wechat-20260618T105024的对话') < 0).assertTrue();
      expect(titles.indexOf('与聊天的对话') < 0).assertTrue();
      expect(titles.indexOf('小赵-') >= 0).assertTrue();
      expect(titles.indexOf('图库聊天-') >= 0 || titles.indexOf('图库-') >= 0).assertTrue();
    });

    it('normalizeChatGroupsOverridesGalleryChatContactTitle', 0, () => {
      let galleryEvent = demoIndexedEvent('e1',
        '[gallery-item:gallery_438498275] 与联系人小赵沟通当前修复进度的微信截图。',
        'photos', 'other', '聊天记录');
      galleryEvent.sources = ['photos', '聊天'];
      galleryEvent.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];
      galleryEvent.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      galleryEvent.entities = ['person:小赵'];
      let candidates: CollectionGroupState[] = [
        { group_id: 'gallery-contact', title: '与小赵的对话', source: 'photos', time: '', meta: '', status: '', domain: 'other', event_ids: ['e1'], source_input_hash: '', event_input_hashes: createStringMap() }
      ];

      let groups = normalizeCollectionGroups('chat', '聊天记录', [galleryEvent], candidates);
      expect(groups.length).assertEqual(1);
      expect(groups[0].title.indexOf('图库聊天-') === 0 || groups[0].title.indexOf('图库-') === 0).assertTrue();
    });

    it('incrementalChatGroupsRefreshLegacyRunIdAndCategoryTitles', 0, () => {
      let wechatEvent = demoIndexedEvent('e1', '用户于2026-06-15与联系人小赵沟通工作UI优化任务', '微信', 'work', 'UI');
      wechatEvent.sources = ['微信', 'wechat-20260618T105024'];
      wechatEvent.source_refs = ['2026-06-18/com.tencent.mm__wechat_auto_summary__wechat-20260618T105024.md#1'];
      wechatEvent.entity_mentions = [{ type: 'person', name: '小赵', aliases: [] }];
      wechatEvent.entities = ['person:小赵'];
      let galleryEvent = demoIndexedEvent('e2', '[gallery-item:gallery_438498275] 手机桌面生活记忆记录。', 'photos', 'other', '聊天记录');
      galleryEvent.sources = ['photos', '聊天'];
      galleryEvent.source_refs = ['2026-06-11/com.huawei.photos__gallery-analysis__聊天.md#613086288'];
      let previous = [
        demoCollectionGroupState('legacy-wechat', '与wechat-20260618T105024的对话', [wechatEvent]),
        demoCollectionGroupState('legacy-gallery', '与聊天的对话', [galleryEvent])
      ];

      let plan = prepareIncrementalCollectionGroups('chat', '聊天记录', [wechatEvent, galleryEvent], previous);
      let groups = applyIncrementalCollectionGroupAssignments('chat', '聊天记录', [wechatEvent, galleryEvent],
        plan.reusedGroups, plan.pendingEvents, []);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('与wechat-20260618T105024的对话') < 0).assertTrue();
      expect(titles.indexOf('与聊天的对话') < 0).assertTrue();
      expect(titles.indexOf('小赵-') >= 0).assertTrue();
      expect(titles.indexOf('图库聊天-') >= 0 || titles.indexOf('图库-') >= 0).assertTrue();
    });

    it('incrementalCollectionGroupsReusesOldGroupAndFallsBackForUnrelatedNewEvent', 0, () => {
      let e1 = demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐');
      let e2 = demoIndexedEvent('e2', '微信里继续讨论晚餐安排', '微信聊天', 'eat', '晚餐');
      let e3 = demoIndexedEvent('e3', '支付宝出现一条停车缴费通知', '支付宝', 'travel', '停车');
      e3.event_date = '2026-06-20';
      let previous = [demoCollectionGroupState('old-dinner', '晚餐计划', [e1, e2])];
      let plan = prepareIncrementalCollectionGroups('chat', '最近聊天', [e1, e2, e3], previous);
      expect(plan.reusedGroups.length).assertEqual(1);
      expect(plan.pendingEvents.length).assertEqual(1);
      expect(plan.pendingEvents[0].event_id).assertEqual('e3');

      let groups = applyIncrementalCollectionGroupAssignments('chat', '最近聊天', [e1, e2, e3], plan.reusedGroups, plan.pendingEvents, []);
      let oldGroup = groups.filter((group: CollectionGroupState): boolean => group.group_id === 'old-dinner')[0];
      expect(oldGroup.title).assertEqual('微信-晚餐计划');
      expect(oldGroup.event_ids.length).assertEqual(2);
      expect(oldGroup.event_ids.indexOf('e1') >= 0).assertTrue();
      expect(oldGroup.event_ids.indexOf('e2') >= 0).assertTrue();
      let newGroups = groups.filter((group: CollectionGroupState): boolean => group.group_id !== 'old-dinner');
      expect(newGroups.length).assertEqual(1);
      expect(newGroups[0].event_ids[0]).assertEqual('e3');
    });

    it('incrementalCollectionGroupsMarksChangedEventPending', 0, () => {
      let e1 = demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐');
      let oldE2 = demoIndexedEvent('e2', '微信里继续讨论晚餐安排', '微信聊天', 'eat', '晚餐');
      let changedE2 = demoIndexedEvent('e2', '微信里改成讨论周末出游路线', '微信聊天', 'travel', '出游');
      let previous = [demoCollectionGroupState('old-dinner', '晚餐计划', [e1, oldE2])];
      let plan = prepareIncrementalCollectionGroups('chat', '最近聊天', [e1, changedE2], previous);
      expect(plan.reusedGroups.length).assertEqual(1);
      expect(plan.reusedGroups[0].event_ids.join('|')).assertEqual('e1');
      expect(plan.pendingEvents.length).assertEqual(1);
      expect(plan.pendingEvents[0].event_id).assertEqual('e2');
    });

    it('incrementalCollectionGroupsRemovesDeletedEventsAndDropsEmptyGroups', 0, () => {
      let e1 = demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐');
      let e2 = demoIndexedEvent('e2', '微信里继续讨论晚餐安排', '微信聊天', 'eat', '晚餐');
      let e3 = demoIndexedEvent('e3', '淘宝浏览运动鞋', '淘宝', 'wear', '运动鞋');
      let previous = [
        demoCollectionGroupState('old-dinner', '晚餐计划', [e1, e2]),
        demoCollectionGroupState('old-shoes', '运动鞋记录', [e3])
      ];
      let plan = prepareIncrementalCollectionGroups('orders', '购物记录', [e1], previous);
      expect(plan.reusedGroups.length).assertEqual(1);
      expect(plan.reusedGroups[0].group_id).assertEqual('old-dinner');
      expect(plan.reusedGroups[0].event_ids.join('|')).assertEqual('e1');
      let groups = applyIncrementalCollectionGroupAssignments('orders', '购物记录', [e1], plan.reusedGroups, plan.pendingEvents, []);
      expect(groups.length).assertEqual(1);
      expect(groups[0].group_id).assertEqual('old-dinner');
    });

    it('incrementalCollectionGroupsAppendsAssignmentWithoutRenamingOldGroup', 0, () => {
      let e1 = demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐');
      let e2 = demoIndexedEvent('e2', '微信里补充晚餐人数', '微信聊天', 'eat', '晚餐');
      e2.event_date = '2026-05-30';
      let previous = [demoCollectionGroupState('old-dinner', '稳定晚餐标题', [e1])];
      let plan = prepareIncrementalCollectionGroups('chat', '最近聊天', [e1, e2], previous);
      let assignments: CollectionGroupAssignment[] = [{
        event_id: 'e2',
        group_id: 'old-dinner',
        title: '模型新标题不应覆盖',
        source: '微信聊天',
        domain: 'eat'
      }];
      let groups = applyIncrementalCollectionGroupAssignments('chat', '最近聊天', [e1, e2], plan.reusedGroups, plan.pendingEvents, assignments);
      let oldGroup = groups.filter((group: CollectionGroupState): boolean => group.group_id === 'old-dinner')[0];
      expect(oldGroup.title).assertEqual('微信-稳定晚餐标题');
      expect(oldGroup.event_ids.length).assertEqual(2);
      expect(oldGroup.event_ids.indexOf('e1') >= 0).assertTrue();
      expect(oldGroup.event_ids.indexOf('e2') >= 0).assertTrue();
    });

    it('incrementalCollectionGroupsRejectsAssignmentOutsideSevenDayWindow', 0, () => {
      let e1 = demoIndexedEvent('e1', '微信里讨论晚餐计划', '微信聊天', 'eat', '晚餐');
      let e2 = demoIndexedEvent('e2', '微信里讨论一个新的月底旅行计划', '微信聊天', 'travel', '旅行');
      e2.event_date = '2026-06-20';
      let previous = [demoCollectionGroupState('old-dinner', '稳定晚餐标题', [e1])];
      let plan = prepareIncrementalCollectionGroups('chat', '最近聊天', [e1, e2], previous);
      let assignments: CollectionGroupAssignment[] = [{
        event_id: 'e2',
        group_id: 'old-dinner',
        title: '旅行计划',
        source: '微信聊天',
        domain: 'travel'
      }];
      let groups = applyIncrementalCollectionGroupAssignments('chat', '最近聊天', [e1, e2], plan.reusedGroups, plan.pendingEvents, assignments);
      let oldGroup = groups.filter((group: CollectionGroupState): boolean => group.group_id === 'old-dinner')[0];
      expect(oldGroup.event_ids.length).assertEqual(1);
      let newGroups = groups.filter((group: CollectionGroupState): boolean => group.group_id !== 'old-dinner');
      expect(newGroups.length).assertEqual(1);
      expect(newGroups[0].event_ids[0]).assertEqual('e2');
    });

    it('normalizeCollectionGroupsDoesNotCompactPastTwelveGroups', 0, () => {
      let events: IndexedEvent[] = [];
      let candidates: CollectionGroupState[] = [];
      for (let index = 1; index <= 13; index++) {
        let event = demoIndexedEvent('e' + String(index), '第' + String(index) + '条独立记录', '来源' + String(index), 'other', '主题' + String(index));
        event.event_date = '2026-05-' + String(10 + index).padStart(2, '0');
        events.push(event);
        candidates.push({
          group_id: 'raw-' + String(index),
          title: '独立主题' + String(index),
          source: '来源' + String(index),
          time: '',
          meta: '',
          status: '',
          domain: 'other',
          event_ids: [event.event_id],
          source_input_hash: '',
          event_input_hashes: createStringMap()
        });
      }
      let groups = normalizeCollectionGroups('notifications', '通知记录', events, candidates);
      expect(groups.length).assertEqual(13);
      let titles = groups.map((group: CollectionGroupState): string => group.title).join('|');
      expect(titles.indexOf('其他已整理记录') < 0).assertTrue();
    });

    it('indexQueryLimitZeroReturnsAll', 0, () => {
      expect(resolveQueryLimit(2, 0)).assertEqual(2);
      expect(isQueryResultTruncated(2, 0)).assertFalse();
      expect(resolveQueryLimit(2, 1)).assertEqual(1);
      expect(isQueryResultTruncated(2, 1)).assertTrue();
    });

    it('indexQueryWithEventsCanIncludeTodoDeadlineInTimeRange', 0, () => {
      let service = demoIndexService('/tmp/index-query-with-events-deadline');
      let eventDateMatch = demoIndexedEvent('e1', '六月三日完成周报', '微信', 'work', '周报');
      eventDateMatch.event_date = '2026-06-03';
      let deadlineEarly = demoIndexedEvent('e2', '五月创建的咖啡待办', '微信', 'work', '咖啡');
      deadlineEarly.event_date = '2026-05-20';
      deadlineEarly.todo = {
        type: 'buy',
        deadline: '2026-06-02',
        text: '购买咖啡豆',
        agent_task: ''
      };
      let deadlineLate = demoIndexedEvent('e3', '五月创建的酒店待办', '微信', 'travel', '酒店');
      deadlineLate.event_date = '2026-05-21';
      deadlineLate.todo = {
        type: 'buy',
        deadline: '2026-06-05',
        text: '预订酒店',
        agent_task: ''
      };
      let outside = demoIndexedEvent('e4', '七月待办', '微信', 'work', '七月');
      outside.event_date = '2026-05-22';
      outside.todo = {
        type: 'buy',
        deadline: '2026-07-01',
        text: '七月处理',
        agent_task: ''
      };
      let events = demoEventMap([eventDateMatch, deadlineEarly, deadlineLate, outside]);
      let query = demoQueryOptions();
      query.startDate = '2026-06-01';
      query.endDate = '2026-06-30';

      let defaultResult = service.queryWithEvents(query, events);
      expect(defaultResult.total_events).assertEqual(1);
      expect(defaultResult.events[0].event_id).assertEqual('e1');

      query.includeTodoDeadlineInTimeRange = true;
      let expandedResult = service.queryWithEvents(query, events);
      expect(expandedResult.total_events).assertEqual(3);
      expect(expandedResult.events[0].event_id).assertEqual('e3');
      expect(expandedResult.events[1].event_id).assertEqual('e1');
      expect(expandedResult.events[2].event_id).assertEqual('e2');
    });

    it('indexQueryUsesHomeTodoDeadlineCandidatesWhenEnabled', 0, () => {
      let storage = new MemoryDataManagerStorage();
      let filesDir = 'memory/index-query-home-todo-deadline';
      storage.removeTree(filesDir);
      let paths = new DataManagerPaths(filesDir, storage);
      paths.ensureBaseDirs();
      storage.ensureDir(storage.join(paths.indexesRoot, 'home-todo'));
      let service = new IndexService(paths, storage, new DataPipelineModelClient());
      let eventDateOnly = demoIndexedEvent('e1', '五月普通记录', '微信', 'work', '普通');
      eventDateOnly.event_date = '2026-05-29';
      let deadlineCoffee = demoIndexedEvent('e2', '五月创建的咖啡待办', '微信', 'work', '咖啡');
      deadlineCoffee.event_date = '2026-05-20';
      deadlineCoffee.todo = {
        type: 'buy',
        deadline: '2026-06-02',
        text: '购买咖啡豆',
        agent_task: ''
      };
      let deadlineHotel = demoIndexedEvent('e3', '五月创建的酒店待办', '微信', 'travel', '酒店');
      deadlineHotel.event_date = '2026-05-21';
      deadlineHotel.todo = {
        type: 'buy',
        deadline: '2026-06-05',
        text: '预订酒店',
        agent_task: ''
      };
      let partition: EventPartition = {
        month: '2026-05',
        events: [eventDateOnly, deadlineCoffee, deadlineHotel]
      };
      storage.writeJsonAtomic(paths.eventPartitionPath('2026-05'), partition as Object);
      let temporalWeeks: Object[] = [];
      let temporalDocument: TestTemporalDocument = {
        month: '2026-06',
        event_ids: [],
        summary: demoTemporalSummary('month'),
        weeks: temporalWeeks
      };
      storage.writeJsonAtomic(paths.temporalPath('2026-06'), temporalDocument as Object);
      let deadlinePostings: Record<string, string[]> = new Object() as Record<string, string[]>;
      deadlinePostings['2026-06-02'] = ['e2'];
      deadlinePostings['2026-06-05'] = ['e3'];
      let typePostings: Record<string, string[]> = new Object() as Record<string, string[]>;
      typePostings.buy = ['e2', 'e3'];
      let homeTodoDocument: TestHomeTodoDocument = {
        deadline_postings: deadlinePostings,
        no_deadline_event_ids: [],
        type_postings: typePostings
      };
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'home-todo', 'index.json'), homeTodoDocument as Object);
      let invertedPostings: Record<string, string[]> = new Object() as Record<string, string[]>;
      invertedPostings['咖啡'] = ['e2'];
      let invertedDocument: TestStringArrayDocument = {
        postings: invertedPostings
      };
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'inverted', 'index.json'), invertedDocument as Object);
      let sourcePostings: Record<string, string[]> = new Object() as Record<string, string[]>;
      let sourceDocument: TestStringArrayDocument = {
        postings: sourcePostings
      };
      storage.writeJsonAtomic(storage.join(paths.indexesRoot, 'source', 'index.json'), sourceDocument as Object);
      let query = demoQueryOptions();
      query.startDate = '2026-06-01';
      query.endDate = '2026-06-30';

      let defaultResult = service.query(query);
      expect(defaultResult.total_events).assertEqual(0);

      query.includeTodoDeadlineInTimeRange = true;
      let expandedResult = service.query(query);
      expect(expandedResult.total_events).assertEqual(2);
      expect(expandedResult.events[0].event_id).assertEqual('e3');
      expect(expandedResult.events[1].event_id).assertEqual('e2');

      query.keywords = ['咖啡'];
      let keywordResult = service.query(query);
      expect(keywordResult.total_events).assertEqual(1);
      expect(keywordResult.events[0].event_id).assertEqual('e2');
      storage.removeTree(filesDir);
    });

    it('indexQueryDoesNotExpandTodoDeadlineWithoutTimeRange', 0, () => {
      let service = demoIndexService('/tmp/index-query-no-time-deadline');
      let event = demoIndexedEvent('e1', '五月创建的咖啡待办', '微信', 'work', '咖啡');
      event.event_date = '2026-05-20';
      event.workflow_scene_ids = [3];
      event.todo = {
        type: 'buy',
        deadline: '2026-06-02',
        text: '购买咖啡豆',
        agent_task: ''
      };
      let query = demoQueryOptions();
      query.includeTodoDeadlineInTimeRange = true;
      query.workflowSceneIds = [99];
      let result = service.queryWithEvents(query, demoEventMap([event]));
      expect(result.total_events).assertEqual(0);
    });

    it('galleryExifCoordinateParsesDmsAndRef', 0, () => {
      let latitude = GalleryExifUtils.coordinateFromExif('31/1, 12/1, 3000/100', 'N');
      let longitude = GalleryExifUtils.coordinateFromExif('121, 30, 0', 'E');
      expect(latitude !== undefined).assertTrue();
      expect(longitude !== undefined).assertTrue();
      expect(Math.abs((latitude as number) - 31.208333) < 0.00001).assertTrue();
      expect(Math.abs((longitude as number) - 121.5) < 0.00001).assertTrue();

      let west = GalleryExifUtils.coordinateFromExif('73/1, 59/1, 0/1', 'W');
      expect(west !== undefined).assertTrue();
      expect((west as number) < 0).assertTrue();

      let symbolLatitude = GalleryExifUtils.coordinateFromExif('31°12′30″', 'N');
      expect(symbolLatitude !== undefined).assertTrue();
      expect(Math.abs((symbolLatitude as number) - 31.208333) < 0.00001).assertTrue();
    });

    it('galleryExifRawGpsLocationFallback', 0, () => {
      let text = GalleryExifUtils.rawGpsLocationText({
        gpsLatitude: '31/1, 12/1, 3000/100',
        gpsLongitude: '121/1, 30/1, 0/1',
        gpsLatitudeRef: 'N',
        gpsLongitudeRef: 'E'
      });
      expect(text).assertEqual('31/1, 12/1, 3000/100 N, 121/1, 30/1, 0/1 E');
    });

    it('galleryExifLocationDirectionAndMapUrl', 0, () => {
      expect(GalleryExifUtils.directedLocationText(31.024267, 121.437828))
        .assertEqual('北纬 31.024267，东经 121.437828');
      expect(GalleryExifUtils.directedLocationText(-31.024267, -121.437828))
        .assertEqual('南纬 31.024267，西经 121.437828');
      let url = GalleryExifUtils.mapUrl(31.024267, 121.437828);
      expect(url.indexOf('position=121.437828,31.024267') >= 0).assertTrue();
    });

    it('galleryExifDateNormalizesOriginalTime', 0, () => {
      expect(GalleryExifUtils.dateFromExifDateTime('2024:06:17 14:03:02')).assertEqual('2024-06-17');
      expect(GalleryExifUtils.displayDateTime('2024:06:17 14:03:02')).assertEqual('2024-06-17 14:03:02');
      expect(GalleryExifUtils.dateFromExifDateTime('')).assertEqual('');
    });

    it('homeRecommendationTodoDeadlineFilter', 0, () => {
      expect(isCurrentOrFutureTodoDeadline('2026-06-06', '2026-06-05')).assertTrue();
      expect(isCurrentOrFutureTodoDeadline('2026-06-05', '2026-06-05')).assertTrue();
      expect(isCurrentOrFutureTodoDeadline('2026-06-04', '2026-06-05')).assertFalse();
      expect(isCurrentOrFutureTodoDeadline('', '2026-06-05')).assertFalse();
      expect(recommendationTodoDeadlineMeta('2026-06-06')).assertEqual('6月6日截止');
    });

    it('homeRecommendationSourceFingerprintTracksPlannerInputs', 0, () => {
      let event = demoPlannerEvent('e1', '2026-06-06');
      let fingerprint = homeRecommendationSourceInputFingerprint([event]);
      let changedTodo = demoPlannerEvent('e1', '2026-06-06');
      changedTodo.todo_text = '购买咖啡豆和滤纸';
      expect(homeRecommendationSourceInputFingerprint([changedTodo]) !== fingerprint).assertTrue();
      let changedSummary = demoPlannerEvent('e1', '2026-06-06');
      changedSummary.summary = '微信里提到要买咖啡豆和滤纸';
      expect(homeRecommendationSourceInputFingerprint([changedSummary]) !== fingerprint).assertTrue();
      let sameContent = demoPlannerEvent('e1', '2026-06-06');
      expect(homeRecommendationSourceInputFingerprint([sameContent])).assertEqual(fingerprint);
    });

    it('homeRecommendationSourceReuseRequiresCandidateHashAndNoOverlap', 0, () => {
      expect(isHomeRecommendationSourceReusable('hash-1', 'hash-1', ['e1'], ['e1', 'e2'], [])).assertTrue();
      expect(isHomeRecommendationSourceReusable('hash-1', 'hash-2', ['e1'], ['e1', 'e2'], [])).assertFalse();
      expect(isHomeRecommendationSourceReusable('hash-1', 'hash-1', ['e1'], ['e2'], [])).assertFalse();
      expect(isHomeRecommendationSourceReusable('hash-1', 'hash-1', ['e1'], ['e1', 'e2'], ['e1'])).assertFalse();
      expect(isHomeRecommendationSourceReusable('', 'hash-1', ['e1'], ['e1'], [])).assertFalse();
    });

    it('homeRecommendationPruneRemovesInactiveSources', 0, () => {
      let emptySource = demoRecommendationState('todo-empty', false);
      emptySource.source_event_ids = [];
      let missingSource = demoRecommendationState('todo-missing', false);
      missingSource.source_event_ids = ['missing'];
      let mixedSource = demoRecommendationState('todo-mixed', false);
      mixedSource.source_event_ids = ['e1', 'missing'];
      let active = demoRecommendationState('todo-active', false);
      active.source_event_ids = ['e1'];
      let document: HomeRecommendationsDocument = {
        generated_at: '2026-06-05T00:00:00',
        input_hash: 'same-input-hash',
        total_events: 4,
        recommendations: [emptySource, missingSource, mixedSource, active]
      };

      let result = pruneHomeRecommendationsDocument(document, ['e1', 'e2']);
      expect(result.prunedCount).assertEqual(3);
      expect(result.document.input_hash).assertEqual('same-input-hash');
      expect(result.document.total_events).assertEqual(2);
      expect(result.document.recommendations.length).assertEqual(1);
      expect(result.document.recommendations[0].id).assertEqual('todo-active');
    });

    it('homeRecommendationPruneKeepsActiveCompletedAndHashMismatch', 0, () => {
      let activeCompleted = demoRecommendationState('todo-completed', true);
      activeCompleted.source_event_ids = ['e1'];
      activeCompleted.source_input_hash = 'old-source-hash';
      let document: HomeRecommendationsDocument = {
        generated_at: '2026-06-05T00:00:00',
        input_hash: 'same-input-hash',
        total_events: 1,
        recommendations: [activeCompleted]
      };

      let result = pruneHomeRecommendationsDocument(document, ['e1']);
      expect(result.prunedCount).assertEqual(0);
      expect(result.document.recommendations.length).assertEqual(1);
      expect(result.document.recommendations[0].completed).assertTrue();
      expect(result.document.recommendations[0].source_input_hash).assertEqual('old-source-hash');
    });

    it('homeRecommendationCompletionDocumentToggle', 0, () => {
      let document: HomeRecommendationsDocument = {
        generated_at: '2026-06-05T00:00:00',
        input_hash: 'input',
        total_events: 1,
        recommendations: [demoRecommendationState('todo-1', false)]
      };
      expect(setHomeRecommendationCompletedInDocument(document, 'todo-1', true)).assertTrue();
      expect(document.recommendations[0].completed).assertTrue();
      expect(setHomeRecommendationCompletedInDocument(document, 'todo-1', false)).assertTrue();
      expect(document.recommendations[0].completed).assertFalse();
      expect(setHomeRecommendationCompletedInDocument(document, 'missing', true)).assertFalse();
      expect(document.recommendations[0].completed).assertFalse();
    });

    it('homeRecommendationViewFilterKeepsFutureDeadlineEvenWhenEventOld', 0, () => {
      let event = demoHomeRecommendationEvent('e1', '2026-05-01', '2026-06-10');
      let map = demoEventMap([event]);
      expect(shouldShowHomeRecommendationInView(['e1'], map, '2026-06-09')).assertTrue();
    });

    it('homeRecommendationViewFilterKeepsTodayDeadlineAndRejectsPastDeadline', 0, () => {
      let todayEvent = demoHomeRecommendationEvent('e1', '2026-06-09', '2026-06-09');
      let pastEvent = demoHomeRecommendationEvent('e2', '2026-06-08', '2026-06-08');
      expect(shouldShowHomeRecommendationInView(['e1'], demoEventMap([todayEvent]), '2026-06-09')).assertTrue();
      expect(shouldShowHomeRecommendationInView(['e2'], demoEventMap([pastEvent]), '2026-06-09')).assertFalse();
    });

    it('homeRecommendationViewFilterKeepsRecentNoDeadlineEvent', 0, () => {
      let event = demoHomeRecommendationEvent('e1', '2026-06-02', '');
      let map = demoEventMap([event]);
      expect(shouldShowHomeRecommendationInView(['e1'], map, '2026-06-09')).assertTrue();
    });

    it('homeRecommendationViewFilterRejectsOldNoDeadlineEvent', 0, () => {
      let event = demoHomeRecommendationEvent('e1', '2026-06-01', '');
      let map = demoEventMap([event]);
      expect(shouldShowHomeRecommendationInView(['e1'], map, '2026-06-09')).assertFalse();
    });

    it('homeRecommendationViewFilterRejectsMissingOrPartiallyExpiredSources', 0, () => {
      let recent = demoHomeRecommendationEvent('e1', '2026-06-08', '');
      let old = demoHomeRecommendationEvent('e2', '2026-06-01', '');
      expect(shouldShowHomeRecommendationInView(['missing'], demoEventMap([recent]), '2026-06-09')).assertFalse();
      expect(shouldShowHomeRecommendationInView(['e1', 'e2'], demoEventMap([recent, old]), '2026-06-09')).assertFalse();
    });

    it('homeRecommendationGenerationFilterUsesRecentNoDeadlineWindow', 0, () => {
      expect(isRecentNoDeadlineHomeTodoEvent('2026-06-02', '2026-06-09', 7)).assertTrue();
      expect(isRecentNoDeadlineHomeTodoEvent('2026-06-01', '2026-06-09', 7)).assertFalse();
      expect(isRecentNoDeadlineHomeTodoEvent('2026-06-08', '2026-06-09', 7)).assertTrue();
      expect(isRecentNoDeadlineHomeTodoEvent('', '2026-06-09', 7)).assertFalse();
    });

    it('homeTodoIndexAllowsChatBuyWithoutDeadline', 0, () => {
      let todo: IndexedEventTodo = { type: 'buy', deadline: '', text: '购买咖啡豆', agent_task: '在淘宝中购买咖啡豆' };
      expect(isHomeTodoIndexCandidate(todo, [3], [3])).assertTrue();
    });

    it('homeTodoIndexRejectsNonBuyChatWithoutDeadline', 0, () => {
      let todo: IndexedEventTodo = { type: 'plan', deadline: '', text: '安排周末聚餐', agent_task: '' };
      expect(isHomeTodoIndexCandidate(todo, [3], [3])).assertFalse();
    });

    it('agentTaskOnlyKeptForPureChatBuyTodo', 0, () => {
      expect(shouldKeepTodoAgentTask('buy', ['聊天'])).assertTrue();
      expect(shouldKeepTodoAgentTask('buy', ['聊天', '购物'])).assertFalse();
      expect(shouldKeepTodoAgentTask('buy', ['购物'])).assertFalse();
      expect(shouldKeepTodoAgentTask('plan', ['聊天'])).assertFalse();
    });

    it('factSplitPromptPreviewUsesSemanticBatchPayload', 0, () => {
      let entry: SourceEntry = {
        source_date: '2026-06-05',
        file_name: 'chat.md',
        entry_index: 7,
        entry_text: '微信聊天里提到今天买 iPhone 16 Pro，淘宝页面显示价格 7999 元。',
        workflow_metadata: createJsonMap(),
        workflow_scene_id: 3,
        source_ref: '2026-06-05/chat.md#7'
      };
      let preview = buildFactSplitPromptPreview([entry]);

      expect(preview.userPrompt.indexOf('"source_ref"') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('"source_date"') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('"workflow_scene_label"') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('"entry_text"') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('"file_name"') < 0).assertTrue();
      expect(preview.userPrompt.indexOf('"entry_index"') < 0).assertTrue();
      expect(preview.userPrompt.indexOf('"workflow_metadata"') < 0).assertTrue();
      expect(preview.userPrompt.indexOf('聊天') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('iPhone 16 Pro') >= 0).assertTrue();

      expect(preview.systemPrompt.indexOf('输入字段说明') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('source_ref：输入 entry 的唯一引用标识') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('source_date：daily-log 文件日期') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('workflow_scene_label：采集场景提示') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('工作流采集场景提示') < 0).assertTrue();
      expect(preview.systemPrompt.indexOf('差旅、文档、健康、办公、图库') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('差旅、餐饮、文档') < 0).assertTrue();
      expect(preview.systemPrompt.indexOf('entry_text：原始日志条目正文') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('"items"') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('"facts"') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('一条原始记录中如果包含多件不同事情') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('订单、账单、交易、消费记录') >= 0).assertTrue();
    });

    it('enrichPromptPreviewExplainsFieldsAndOmitsSceneIds', 0, () => {
      let chatEvent = demoIndexedEvent('e1', '微信里提到这周六要买咖啡豆', '微信', 'eat', '咖啡豆');
      chatEvent.workflow_scene_ids = [3];
      chatEvent.normalized_fact = '与朋友聊天时提到这周六要在淘宝购买咖啡豆';
      let shoppingEvent = demoIndexedEvent('e2', '淘宝浏览运动鞋', '淘宝', 'wear', '运动鞋');
      shoppingEvent.workflow_scene_ids = [0];
      shoppingEvent.normalized_fact = '在淘宝查看一双运动鞋商品详情';
      let events: IndexedEvent[] = [chatEvent, shoppingEvent];
      let preview = buildEnrichPromptPreview(events);

      expect(preview.userPrompt.indexOf('workflow_scene_labels') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('workflow_scene_ids') < 0).assertTrue();
      expect(preview.userPrompt.indexOf('微信里提到这周六要买咖啡豆') >= 0).assertTrue();
      expect(preview.userPrompt.indexOf('与朋友聊天时提到这周六要在淘宝购买咖啡豆') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('输入字段说明') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('workflow_scene_labels：采集场景提示') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('工作流采集场景提示') < 0).assertTrue();
      expect(preview.systemPrompt.indexOf('差旅、文档、健康、办公、图库') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('差旅、餐饮、文档') < 0).assertTrue();
      expect(preview.systemPrompt.indexOf('keywords 规则') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('domains 规则') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('eat|wear|live|travel|work|other') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('entities 规则') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('person') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('place') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('merchant') >= 0).assertTrue();
      expect(preview.systemPrompt.indexOf('聊天：提取两类待办') >= 0).assertTrue();
    });

    it('eventEnrichInputFingerprintIgnoresGeneratedTodo', 0, () => {
      let event = demoIndexedEvent('e1', '微信里提到要买咖啡豆', '微信', 'eat', '咖啡豆');
      event.source_refs = ['2026-06-05/demo.md#1'];
      event.workflow_scene_ids = [3];
      let fingerprint = eventEnrichInputFingerprint(event);
      event.todo = { type: 'buy', deadline: '', text: '购买咖啡豆', agent_task: '在淘宝中购买咖啡豆' };
      expect(eventEnrichInputFingerprint(event)).assertEqual(fingerprint);
    });

    it('eventEnrichInputFingerprintChangesWhenEnrichInputsChange', 0, () => {
      let event = demoIndexedEvent('e1', '微信里提到要买咖啡豆', '微信', 'eat', '咖啡豆');
      event.source_refs = ['2026-06-05/demo.md#1'];
      event.workflow_scene_ids = [3];
      event.image_paths = ['workflows/runs/demo/a.png'];
      let fingerprint = eventEnrichInputFingerprint(event);
      event.summary = '微信里提到要买咖啡豆和滤纸';
      expect(eventEnrichInputFingerprint(event) !== fingerprint).assertTrue();
      event.summary = '微信里提到要买咖啡豆';
      event.source_refs = ['2026-06-05/demo.md#1', '2026-06-05/demo.md#2'];
      expect(eventEnrichInputFingerprint(event) !== fingerprint).assertTrue();
      event.source_refs = ['2026-06-05/demo.md#1'];
      event.workflow_scene_ids = [3, 4];
      expect(eventEnrichInputFingerprint(event) !== fingerprint).assertTrue();
      event.workflow_scene_ids = [3];
      event.image_paths = ['workflows/runs/demo/b.png'];
      expect(eventEnrichInputFingerprint(event) !== fingerprint).assertTrue();
    });

    it('eventEnrichInputReuseRequiresMatchingHashAndPreviousEvent', 0, () => {
      expect(isEventEnrichInputReusable('hash-1', 'hash-1', true)).assertTrue();
      expect(isEventEnrichInputReusable('hash-1', 'hash-2', true)).assertFalse();
      expect(isEventEnrichInputReusable('hash-1', 'hash-1', false)).assertFalse();
      expect(isEventEnrichInputReusable('', 'hash-1', true)).assertFalse();
    });

    it('avatarHomeViewModelDefaultsToStaticFallbackState', 0, () => {
      let avatar = createEmptyAvatarHomeViewModel();
      expect(avatar.avatarUri).assertEqual('');
      expect(avatar.avatarForegroundUri).assertEqual('');
      expect(avatar.avatarMessageForegroundUri).assertEqual('');
      expect(avatar.avatarReferencePhotoUri).assertEqual('');
      expect(avatar.avatarStatus).assertEqual('empty');
      expect(avatar.avatarActionLabel).assertEqual('生成数字分身');
      expect(avatar.avatarVersionId).assertEqual('');
      expect(avatar.avatarUpdatedLabel).assertEqual('');
    });

    it('avatarErrorMessageHandlesNullSystemErrors', 0, () => {
      expect(avatarErrorMessage(null, 'fallback error')).assertEqual('fallback error');
      expect(avatarErrorMessage(undefined, 'fallback error')).assertEqual('fallback error');
      expect(avatarErrorMessage(new Error('real error'), 'fallback error')).assertEqual('real error');
      expect(avatarErrorMessage('plain error', 'fallback error')).assertEqual('plain error');
    });

    it('dataManagerPathsExposeAvatarStorageRoots', 0, () => {
      let paths = new DataManagerPaths('/tmp/demo-files', new DataManagerStorage());
      expect(paths.avatarRoot).assertEqual('/tmp/demo-files/workflows/avatar');
      expect(paths.avatarVersionsRoot).assertEqual('/tmp/demo-files/workflows/avatar/versions');
      expect(paths.avatarAssetsRoot).assertEqual('/tmp/demo-files/workflows/avatar/assets');
    });

    it('avatarPromptBuilderCreatesStableSnapshotAndPrompt', 0, () => {
      let builder = new AvatarPromptBuilder(new DataManagerStorage());
      let snapshot = builder.buildSnapshot(demoProfileStateForAvatar(), 100);
      expect(snapshot.domains.length).assertEqual(4);
      expect(snapshot.gender).assertEqual('男');
      expect(snapshot.age).assertEqual('');
      expect(snapshot.prompt_profile_text.indexOf('咖啡轻食') >= 0).assertTrue();
      let prompt = builder.buildPrompt(snapshot);
      expect(prompt.indexOf('3D 卡通风格个人数字形象') >= 0).assertTrue();
      expect(prompt.indexOf('4:3 横向首页场景图') >= 0).assertTrue();
      expect(prompt.indexOf('围绕人物自然融入适量 profile 相关物品和事项元素') >= 0).assertTrue();
      expect(prompt.indexOf('gender=male') >= 0).assertTrue();
      expect(prompt.indexOf('咖啡轻食') >= 0).assertTrue();
      expect(prompt.indexOf('要求无文字') >= 0).assertTrue();
      expect(prompt.indexOf('参考照片中的人物')).assertEqual(-1);
      expect(prompt.indexOf('event_id')).assertEqual(-1);
      expect(prompt.indexOf('API')).assertEqual(-1);
    });

    it('avatarPromptBuilderCentersReferencePhotoForImageToImage', 0, () => {
      let builder = new AvatarPromptBuilder(new DataManagerStorage());
      let snapshot = builder.buildSnapshot(demoProfileStateForAvatar(), 100);
      let prompt = builder.buildPrompt(snapshot, 'image_to_image');
      expect(prompt.indexOf('参考照片中的人物') >= 0).assertTrue();
      expect(prompt.indexOf('4:3 横向首页场景图') >= 0).assertTrue();
      expect(prompt.indexOf('围绕人物自然融入适量 profile 相关物品和事项元素') >= 0).assertTrue();
      expect(prompt.indexOf('不是生成另一个陌生角色') >= 0).assertTrue();
      expect(prompt.indexOf('不要让 profile 覆盖或替换参考照片中的人物身份特征') >= 0).assertTrue();
      expect(prompt.indexOf('咖啡轻食') >= 0).assertTrue();
      expect(prompt.indexOf('gender=male') >= 0).assertTrue();
    });

    it('avatarPromptBuilderHashChangesWhenProfileChanges', 0, () => {
      let builder = new AvatarPromptBuilder(new DataManagerStorage());
      let profile = demoProfileStateForAvatar();
      let first = builder.snapshotHash(builder.buildSnapshot(profile, 100));
      profile.domains['eat'].short_summary = '热咖啡党';
      let second = builder.snapshotHash(builder.buildSnapshot(profile, 100));
      expect(first === second).assertFalse();
    });

    it('avatarServiceMarksStaleWhenProfileHashChanges', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let service = new AvatarService(paths, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let profile = demoProfileStateForAvatar();
      let firstHash = service.previewProfileSnapshotHash(profile, 100);
      avatarStorage.saveVersion({
        version_id: 'v1',
        created_at: '2026-06-10 10:07:00',
        image_path: 'assets/v1.png',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'prompt',
        profile_snapshot: new AvatarPromptBuilder(storage).buildSnapshot(profile, 100),
        profile_snapshot_hash: firstHash,
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '',
          photo_source: ''
        }
      });
      let currentState = avatarStorage.emptyState();
      currentState.status = 'current';
      currentState.current_version_id = 'v1';
      currentState.profile_snapshot_hash = firstHash;
      currentState.updated_at = '2026-06-10 10:07:00';
      avatarStorage.saveState(currentState);

      profile.domains['eat'].short_summary = '热咖啡党';
      let view = service.homeView(profile, 100);
      let persistedState = avatarStorage.loadState();
      expect(view.avatarStatus).assertEqual('stale');
      expect(persistedState.status).assertEqual('stale');
      expect(persistedState.current_version_id).assertEqual('v1');
      expect(persistedState.profile_snapshot_hash).assertEqual(firstHash);
    });

    it('avatarServiceDetectsUnchangedProfileBeforeRegeneration', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let service = new AvatarService(paths, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let profile = demoProfileStateForAvatar();
      let hash = service.previewProfileSnapshotHash(profile, 100);
      let state = avatarStorage.emptyState();
      state.status = 'current';
      state.current_version_id = 'v1';
      state.profile_snapshot_hash = hash;
      avatarStorage.saveState(state);

      expect(service.isCurrentProfileSnapshotUnchanged(profile, 100)).assertTrue();
      profile.domains['eat'].short_summary = '热咖啡党';
      expect(service.isCurrentProfileSnapshotUnchanged(profile, 100)).assertFalse();
    });

    it('avatarServiceRecoversFailedStateWhenLatestVersionWasAlreadySaved', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-failed-state-recovery';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let service = new AvatarService(paths, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let profile = demoProfileStateForAvatar();
      let promptBuilder = new AvatarPromptBuilder(storage);
      let latestHash = service.previewProfileSnapshotHash(profile, 100);
      let snapshot = promptBuilder.buildSnapshot(profile, 100);
      avatarStorage.saveVersion({
        version_id: 'v-orphan',
        created_at: '2026-06-16T11:09:31',
        image_path: 'assets/v-orphan.jpg',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'prompt',
        profile_snapshot: snapshot,
        profile_snapshot_hash: latestHash,
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '',
          photo_source: ''
        }
      });
      let failedState = avatarStorage.emptyState();
      failedState.status = 'failed';
      failedState.current_version_id = '';
      failedState.profile_snapshot_hash = '';
      failedState.last_error_code = 'AVATAR_GENERATE_FAILED';
      failedState.last_error_message = 'Cannot read property message of null';
      failedState.updated_at = '2026-06-16T11:09:34';
      avatarStorage.saveState(failedState);

      let view = service.homeView(profile, 100);
      let persistedState = avatarStorage.loadState();
      expect(view.avatarStatus).assertEqual('current');
      expect(view.avatarVersionId).assertEqual('v-orphan');
      expect(view.avatarUri).assertEqual('file:///tmp/demo-avatar-failed-state-recovery/workflows/avatar/assets/v-orphan.jpg');
      expect(persistedState.status).assertEqual('current');
      expect(persistedState.current_version_id).assertEqual('v-orphan');
      expect(persistedState.profile_snapshot_hash).assertEqual(latestHash);
      expect(persistedState.last_error_message).assertEqual('');
    });

    it('avatarServiceBackfillsMessageForegroundWhenFullForegroundAlreadyExists', 0, async () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-message-foreground-backfill';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let service = new AvatarService(paths, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let onePixelPng = new Uint8Array([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
        8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 224, 18,
        145, 251, 15, 0, 1, 164, 1, 60, 147, 139, 14, 183, 0, 0, 0, 0, 73, 69, 78, 68, 174,
        66, 96, 130
      ]);
      avatarStorage.saveForegroundPng('v-existing', onePixelPng);
      avatarStorage.saveVersion({
        version_id: 'v-existing',
        created_at: '2026-06-10 10:07:00',
        image_path: 'assets/v-existing.png',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'prompt',
        profile_snapshot: new AvatarPromptBuilder(storage).buildSnapshot(demoProfileStateForAvatar(), 100),
        profile_snapshot_hash: 'hash',
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '',
          photo_source: ''
        }
      });
      let state = avatarStorage.emptyState();
      state.status = 'current';
      state.current_version_id = 'v-existing';
      state.profile_snapshot_hash = 'hash';
      avatarStorage.saveState(state);

      expect(avatarStorage.foregroundExists('v-existing')).assertTrue();
      expect(avatarStorage.messageForegroundExists('v-existing')).assertFalse();

      let view = await service.ensureCurrentForeground();

      expect(view.avatarForegroundUri)
        .assertEqual('file:///tmp/demo-avatar-message-foreground-backfill/workflows/avatar/assets/v-existing-foreground.png');
      expect(view.avatarMessageForegroundUri)
        .assertEqual('file:///tmp/demo-avatar-message-foreground-backfill/workflows/avatar/assets/v-existing-message-foreground.png');
      expect(avatarStorage.messageForegroundExists('v-existing')).assertTrue();
    });

    it('avatarGenerateRequestKeepsOriginalPhotoSourceInConsent', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let service = new AvatarService(paths, storage);
      let request = service.buildGenerateRequest(demoProfileStateForAvatar(), 100, 'image_to_image',
        'data:image/jpeg;base64,AQID', '2026-06-10T10:07:00.000Z', 'file://photo/reference.jpg');
      expect(request.sourceImage).assertEqual('data:image/jpeg;base64,AQID');
      expect(request.consent.photo_used).assertTrue();
      expect(request.consent.photo_source).assertEqual('file://photo/reference.jpg');
    });

    it('avatarStorageListsVersionViewModelsWithEvidence', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-version-view';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let profile = demoProfileStateForAvatar();
      let snapshot = new AvatarPromptBuilder(storage).buildSnapshot(profile, 100);
      avatarStorage.saveVersion({
        version_id: 'v-history',
        created_at: '2026-06-10 10:07:00',
        image_path: 'assets/v-history.jpg',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'avatar prompt',
        profile_snapshot: snapshot,
        profile_snapshot_hash: 'hash',
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '2026-06-10T10:07:00.000Z',
          photo_source: ''
        }
      });

      let versions = avatarStorage.listVersionViewModels();
      expect(versions.length).assertEqual(1);
      expect(versions[0].versionId).assertEqual('v-history');
      expect(versions[0].imageUri).assertEqual('file:///tmp/demo-avatar-version-view/workflows/avatar/assets/v-history.jpg');
      expect(versions[0].model).assertEqual('doubao-seedream-4-5-251128');
      expect(versions[0].promptSnapshot).assertEqual('avatar prompt');
      expect(versions[0].profileSnapshot.domains.length).assertEqual(4);
      expect(versions[0].profileSnapshot.domains[0].claims.length > 0).assertTrue();
      expect(versions[0].generationParams.output_format).assertEqual('jpeg');
      expect(versions[0].consentSnapshot.photo_used).assertFalse();
    });

    it('avatarStorageBuildsVersionUriAndActionLabels', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let emptyView = avatarStorage.homeViewFromState(avatarStorage.emptyState(), null);
      expect(emptyView.avatarStatus).assertEqual('empty');
      expect(emptyView.avatarActionLabel).assertEqual('生成数字分身');
      let currentState = avatarStorage.emptyState();
      currentState.status = 'current';
      currentState.current_version_id = 'v1';
      currentState.updated_at = '2026-06-10 10:07:00';
      let view = avatarStorage.homeViewFromState(currentState, {
        version_id: 'v1',
        created_at: '2026-06-10 10:07:00',
        image_path: 'assets/v1.png',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'prompt',
        profile_snapshot: new AvatarPromptBuilder(storage).buildSnapshot(demoProfileStateForAvatar(), 100),
        profile_snapshot_hash: 'hash',
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '',
          photo_source: ''
        }
      });
      expect(view.avatarUri).assertEqual('file:///tmp/demo-files/workflows/avatar/assets/v1.png');
      expect(view.avatarForegroundUri).assertEqual('');
      expect(view.avatarActionLabel).assertEqual('数字分身已更新');
    });

    it('avatarStoragePersistsReferencePhotoForHomeView', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-reference-photo';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let bytes: Uint8Array = new Uint8Array([137, 80, 78, 71]);
      let relativePath = avatarStorage.saveReferencePhotoBytes(bytes, 'file://photo/reference.png');
      let state = avatarStorage.emptyState();
      state.reference_photo_path = relativePath;
      avatarStorage.saveState(state);

      let persistedState = avatarStorage.loadState();
      let view = avatarStorage.homeViewFromState(persistedState, null);

      expect(relativePath.startsWith('assets/reference-photo-')).assertTrue();
      expect(relativePath.endsWith('.png')).assertTrue();
      expect(persistedState.reference_photo_path).assertEqual(relativePath);
      expect(view.avatarReferencePhotoUri)
        .assertEqual('file:///tmp/demo-avatar-reference-photo/workflows/avatar/' + relativePath);
    });

    it('emptyHomeViewModelRestoresSavedAvatarReferencePhoto', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-empty-home-reference-photo';
      storage.removeTree(root);
      let facade = new DataManagerFacade(root);
      facade.ensureReady();
      let avatarStorage = new AvatarStorage(facade.paths, facade.storage);
      let bytes: Uint8Array = new Uint8Array([255, 216, 255]);
      let relativePath = avatarStorage.saveReferencePhotoBytes(bytes, 'reference.jpg');
      let state = avatarStorage.emptyState();
      state.reference_photo_path = relativePath;
      avatarStorage.saveState(state);

      let home = facade.loadHomeViewModel();

      expect(home.empty).assertTrue();
      expect(home.avatarReferencePhotoUri)
        .assertEqual('file:///tmp/demo-empty-home-reference-photo/workflows/avatar/' + relativePath);
    });

    it('avatarStorageUsesFreshReferencePhotoPathForPreviewRefresh', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-reference-refresh';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let firstBytes: Uint8Array = new Uint8Array([1, 2, 3]);
      let secondBytes: Uint8Array = new Uint8Array([4, 5, 6]);

      let firstPath = avatarStorage.saveReferencePhotoBytes(firstBytes, 'first.jpg');
      let secondPath = avatarStorage.saveReferencePhotoBytes(secondBytes, 'second.jpg');

      expect(firstPath === secondPath).assertFalse();
      expect(avatarStorage.referencePhotoDisplayUri(secondPath) === avatarStorage.referencePhotoDisplayUri(firstPath))
        .assertFalse();
    });

    it('avatarStorageSaveAssetBase64ReturnsDisplayableVersionUri', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let relativePath = avatarStorage.saveAssetBase64('v1', 'AQID');
      expect(relativePath).assertEqual('assets/v1.png');
      expect(avatarStorage.displayUri(relativePath)).assertEqual('file:///tmp/demo-files/workflows/avatar/assets/v1.png');
    });

    it('avatarStorageSaveAssetBase64UsesJpegExtensionForJpegOutputFormat', 0, () => {
      let storage = new DataManagerStorage();
      let paths = new DataManagerPaths('/tmp/demo-files', storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      let relativePath = avatarStorage.saveAssetBase64('v2', 'AQID', 'jpeg');
      expect(relativePath).assertEqual('assets/v2.jpg');
      expect(avatarStorage.displayUri(relativePath)).assertEqual('file:///tmp/demo-files/workflows/avatar/assets/v2.jpg');
    });

    it('avatarStorageBuildsForegroundPngCachePathAndUri', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-foreground';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      expect(avatarStorage.foregroundAssetPath('v-main')).assertEqual('/tmp/demo-avatar-foreground/workflows/avatar/assets/v-main-foreground.png');
      expect(avatarStorage.relativeAvatarForegroundPath('v-main')).assertEqual('assets/v-main-foreground.png');
      expect(avatarStorage.foregroundExists('v-main')).assertFalse();
      avatarStorage.saveForegroundPng('v-main', new Uint8Array([137, 80, 78, 71]));
      expect(avatarStorage.foregroundExists('v-main')).assertTrue();
      expect(avatarStorage.foregroundDisplayUri('v-main')).assertEqual('file:///tmp/demo-avatar-foreground/workflows/avatar/assets/v-main-foreground.png');
    });

    it('avatarStorageBuildsMessageForegroundCachePathAndUri', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-message-foreground';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      expect(avatarStorage.messageForegroundAssetPath('v-main'))
        .assertEqual('/tmp/demo-avatar-message-foreground/workflows/avatar/assets/v-main-message-foreground.png');
      expect(avatarStorage.relativeAvatarMessageForegroundPath('v-main'))
        .assertEqual('assets/v-main-message-foreground.png');
      expect(avatarStorage.messageForegroundExists('v-main')).assertFalse();
      avatarStorage.saveMessageForegroundPng('v-main', new Uint8Array([137, 80, 78, 71]));
      expect(avatarStorage.messageForegroundExists('v-main')).assertTrue();
      expect(avatarStorage.messageForegroundDisplayUri('v-main'))
        .assertEqual('file:///tmp/demo-avatar-message-foreground/workflows/avatar/assets/v-main-message-foreground.png');
    });

    it('avatarHomeViewUsesMessageForegroundWhenCacheExists', 0, () => {
      let storage = new DataManagerStorage();
      let root = '/tmp/demo-avatar-message-home-view';
      storage.removeTree(root);
      let paths = new DataManagerPaths(root, storage);
      let avatarStorage = new AvatarStorage(paths, storage);
      avatarStorage.saveForegroundPng('v1', new Uint8Array([137, 80, 78, 71]));
      avatarStorage.saveMessageForegroundPng('v1', new Uint8Array([137, 80, 78, 71]));
      let state = avatarStorage.emptyState();
      state.status = 'current';
      state.current_version_id = 'v1';

      let view = avatarStorage.homeViewFromState(state, {
        version_id: 'v1',
        created_at: '2026-06-10 10:07:00',
        image_path: 'assets/v1.png',
        thumbnail_path: '',
        mode: 'text_to_image',
        provider: 'seedream',
        model: 'doubao-seedream-4-5-251128',
        generation_params: {
          size: '2K',
          response_format: 'url',
          output_format: 'jpeg',
          sequential_image_generation: 'disabled',
          stream: false,
          watermark: true
        },
        prompt_snapshot: 'prompt',
        profile_snapshot: new AvatarPromptBuilder(storage).buildSnapshot(demoProfileStateForAvatar(), 100),
        profile_snapshot_hash: 'hash',
        consent_snapshot: {
          mode: 'text_to_image',
          photo_used: false,
          consented_at: '',
          photo_source: ''
        }
      });

      expect(view.avatarForegroundUri)
        .assertEqual('file:///tmp/demo-avatar-message-home-view/workflows/avatar/assets/v1-foreground.png');
      expect(view.avatarMessageForegroundUri)
        .assertEqual('file:///tmp/demo-avatar-message-home-view/workflows/avatar/assets/v1-message-foreground.png');
    });

    it('dataManagerStorageWriteBytesOnlyWritesProvidedViewRange', 0, () => {
      let storage = new DataManagerStorage();
      let path = '/tmp/demo-byte-writes/exact.bin';
      try {
        fs.unlinkSync(path);
      } catch (e) {
      }
      try {
        fs.unlinkSync(path + '.tmp');
      } catch (e) {
      }
      let source = new Uint8Array([9, 1, 2, 3, 8]);
      storage.writeBytesAtomic(path, source.subarray(1, 4));
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let buffer = new ArrayBuffer(3);
      try {
        fs.readSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      let bytes = new Uint8Array(buffer);
      expect(bytes.length).assertEqual(3);
      expect(bytes[0]).assertEqual(1);
      expect(bytes[1]).assertEqual(2);
      expect(bytes[2]).assertEqual(3);
      expect(fs.statSync(path).size).assertEqual(3);
    });

    it('seedreamTextToImageRequestBodyMatchesArkShape', 0, () => {
      let body = createSeedreamRequestBody('doubao-seedream-4-5-251128', '生成数字分身', '',
        createDefaultAvatarGenerationParams('2K', 'url', false));
      expect(String(body['model'])).assertEqual('doubao-seedream-4-5-251128');
      expect(String(body['prompt'])).assertEqual('生成数字分身');
      expect(String(body['sequential_image_generation'])).assertEqual('disabled');
      expect(String(body['response_format'])).assertEqual('url');
      expect(body['output_format'] === undefined).assertTrue();
      expect(String(body['size'])).assertEqual('2K');
      expect(Boolean(body['stream'])).assertFalse();
      expect(Boolean(body['watermark'])).assertTrue();
      expect(body['image'] === undefined).assertTrue();
    });

    it('seedreamImageToImageRequestBodyIncludesImage', 0, () => {
      let body = createSeedreamRequestBody('doubao-seedream-4-5-251128', '照片增强数字分身', 'https://example.com/photo.png', createDefaultAvatarGenerationParams('2K', 'url', true));
      expect(String(body['image'])).assertEqual('https://example.com/photo.png');
    });

    it('seedreamResponseNormalizersReadFirstDataItem', 0, () => {
      let url = normalizeSeedreamImageUrl('{"data":[{"url":"https://example.com/avatar.png"}]}');
      expect(url).assertEqual('https://example.com/avatar.png');
      let base64 = normalizeSeedreamImageBase64('{"data":[{"b64_json":"aGVsbG8="}]}');
      expect(base64).assertEqual('aGVsbG8=');
    });

    it('seedreamResponseNormalizersIgnoreMalformedDataShapes', 0, () => {
      expect(normalizeSeedreamImageUrl('{"data":null}')).assertEqual('');
      expect(normalizeSeedreamImageUrl('{"data":{}}')).assertEqual('');
      expect(normalizeSeedreamImageUrl('{"data":[null]}')).assertEqual('');
      expect(normalizeSeedreamImageUrl('{"data":[{"url":123}]}')).assertEqual('');
      expect(normalizeSeedreamImageBase64('{"data":null}')).assertEqual('');
      expect(normalizeSeedreamImageBase64('{"data":{}}')).assertEqual('');
      expect(normalizeSeedreamImageBase64('{"data":[null]}')).assertEqual('');
      expect(normalizeSeedreamImageBase64('{"data":[{"b64_json":123}]}')).assertEqual('');
    });

    it('homeViewModelKeepsAvatarDefaultsForNonEmptyProfile', 0, () => {
      let facade = new DataManagerFacade('/tmp/demo-home-profile-avatar');
      let profile: ProfileState = {
        generated_at: '2026-06-10T10:00:00',
        event_count: 1,
        event_date_range: createStringMap(),
        domains: new Object() as Record<string, ProfileDomainState>,
        claim_count: 0
      };
      facade.storage.writeJsonAtomic(facade.storage.join(facade.paths.indexesRoot, 'profile', 'state.json'), profile as Object);

      let home = facade.loadHomeViewModel();
      expect(home.empty).assertFalse();
      expect(home.avatarUri).assertEqual('');
      expect(home.avatarStatus).assertEqual('empty');
      expect(home.avatarActionLabel).assertEqual('生成数字分身');
      expect(home.avatarVersionId).assertEqual('');
      expect(home.avatarUpdatedLabel).assertEqual('');
      expect(home.avatarForegroundUri).assertEqual('');
    });
  });
}
