import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { DataPipelineModelClient } from './DataPipelineModelClient';
import { ConsolidationService, sourceEntryProcessingHash } from './ConsolidationService';
import { IndexService } from './IndexService';
import { CollectionGroupingBuildResult, CollectionGroupingService, collectionTabSpecByIndex, collectionTabSpecs, heuristicCollectionGroups } from './CollectionGroupingService';
import { HomeRecommendationBuildResult, HomeRecommendationService } from './HomeRecommendationService';
import { dataManagerInfo } from './DataManagerLog';
import { DataManagerImageResolver } from './DataManagerImageResolver';
import { AvatarService } from './avatar/AvatarService';
import { GalleryMemorySync } from '../utils/gallery/GalleryMemorySync';
import { ChatMemorySync } from './ChatMemorySync';
import {
  AvatarGenerateRequest,
  AvatarHomeViewModel,
  AvatarProviderConfig,
  AvatarVersionViewModel,
  createEmptyAvatarHomeViewModel
} from './avatar/AvatarTypes';
import {
  CollectionEventViewModel,
  CollectionGroupState,
  CollectionGroupViewModel,
  CollectionImageViewModel,
  CollectionInsightViewModel,
  CollectionRowViewModel,
  CollectionViewModel,
  ConsolidatedState,
  DataManagerModelConfig,
  DOMAIN_DISPLAY_NAMES,
  HomeDomainViewModel,
  HomeProfileViewModel,
  HomeRecommendationsDocument,
  HomeRecommendationState,
  HomeRecommendationViewModel,
  IndexedEvent,
  ProfileClaim,
  ProfileDomainState,
  ProfileState,
  QueryOptions,
  QueryResult,
  RefreshSummary,
  DataManagerProgressCallback,
  NumberMap,
  StringMap,
  createDataManagerProgress,
  createStringMap
} from './DataManagerTypes';
import {
  displayDomainName,
  monthKeyFromDate,
  normalizeFreeText,
  nowIsoLocal,
  parseDailyLogDocument,
  parseNumberedEntries,
  sourceAppDisplayName,
  sourceDisplayName,
  sourceRef,
  stableUnique,
  addDays,
  isIsoDate,
  workflowSceneIdFromMetadata
} from './DataManagerUtils';

interface DailyLogSnapshotFile {
  path: string;
  sha256: string;
  entry_count: number;
}

interface DailyLogSnapshot {
  generated_at: string;
  root: string;
  file_count: number;
  entry_count: number;
  tree_hash: string;
  files: DailyLogSnapshotFile[];
}

const DAILY_LOG_SNAPSHOT_FILE_NAME: string = 'daily-log-snapshot.json';

function createHomeProfileAvatarDefaults(): AvatarHomeViewModel {
  let avatar = createEmptyAvatarHomeViewModel();
  return {
    avatarUri: avatar.avatarUri,
    avatarForegroundUri: avatar.avatarForegroundUri,
    avatarMessageForegroundUri: avatar.avatarMessageForegroundUri,
    avatarReferencePhotoUri: avatar.avatarReferencePhotoUri,
    avatarStatus: avatar.avatarStatus,
    avatarUpdatedLabel: avatar.avatarUpdatedLabel,
    avatarActionLabel: avatar.avatarActionLabel,
    avatarVersionId: avatar.avatarVersionId
  };
}

export function createEmptyHomeProfileViewModel(): HomeProfileViewModel {
  let avatar = createHomeProfileAvatarDefaults();
  return {
    avatarUri: avatar.avatarUri,
    avatarForegroundUri: avatar.avatarForegroundUri,
    avatarMessageForegroundUri: avatar.avatarMessageForegroundUri,
    avatarReferencePhotoUri: avatar.avatarReferencePhotoUri,
    avatarStatus: avatar.avatarStatus,
    avatarUpdatedLabel: avatar.avatarUpdatedLabel,
    avatarActionLabel: avatar.avatarActionLabel,
    avatarVersionId: avatar.avatarVersionId,
    updatedLabel: '暂无画像',
    completeness: 0,
    totalEvents: 0,
    domains: defaultHomeDomains(),
    recommendations: defaultRecommendations(),
    empty: true
  };
}

export function createEmptyCollectionViewModels(): CollectionViewModel[] {
  return collectionTabSpecs().map((spec) => emptyCollectionViewModel(spec.tabIndex));
}

// 汇总页的 tabIndex 是稳定 sceneId，不保证从 0 连续递增；这里统一把 sceneId 映射到 viewModels 数组位置。
export function collectionViewModelByTabIndex(viewModels: CollectionViewModel[], tabIndex: number): CollectionViewModel {
  let specs = collectionTabSpecs();
  let targetSpec = collectionTabSpecByIndex(tabIndex);
  let targetIndex = 0;
  for (let index = 0; index < specs.length; index++) {
    if (specs[index].tabIndex === targetSpec.tabIndex) {
      targetIndex = index;
      break;
    }
  }
  if (targetIndex < viewModels.length) {
    return viewModels[targetIndex];
  }
  let emptyViews = createEmptyCollectionViewModels();
  if (targetIndex < emptyViews.length) {
    return emptyViews[targetIndex];
  }
  return emptyViews[0];
}

function defaultHomeDomains(): HomeDomainViewModel[] {
  let eat: HomeDomainViewModel = { domain: 'eat', icon: 'Eat', title: '吃', desc: '暂无数据', fullDesc: '暂无数据', claims: [], color: '#39C2A2', eventCount: 0 };
  let wear: HomeDomainViewModel = { domain: 'wear', icon: 'Wear', title: '穿', desc: '暂无数据', fullDesc: '暂无数据', claims: [], color: '#7669FF', eventCount: 0 };
  let live: HomeDomainViewModel = { domain: 'live', icon: 'Live', title: '住', desc: '暂无数据', fullDesc: '暂无数据', claims: [], color: '#FF963D', eventCount: 0 };
  let travel: HomeDomainViewModel = { domain: 'travel', icon: 'Go', title: '行', desc: '暂无数据', fullDesc: '暂无数据', claims: [], color: '#4B9BFF', eventCount: 0 };
  return [eat, wear, live, travel];
}

function defaultRecommendations(): HomeRecommendationViewModel[] {
  return [];
}

export function shouldShowHomeRecommendationInView(sourceEventIds: string[], eventMap: Record<string, IndexedEvent>, today: string): boolean {
  if (!isIsoDate(today)) {
    return false;
  }
  let eventIds = stableUnique((sourceEventIds || []).map((id: string): string => normalizeFreeText(id))).filter((id: string): boolean => id.length > 0);
  if (eventIds.length === 0) {
    return false;
  }
  let recentLowerBoundExclusive = addDays(today, -7);
  for (let eventId of eventIds) {
    let event = eventMap[eventId];
    if (!event) {
      return false;
    }
    let deadline = normalizeFreeText(event.todo.deadline);
    if (isIsoDate(deadline)) {
      if (deadline < today) {
        return false;
      }
      continue;
    }
    let eventDate = normalizeFreeText(event.event_date);
    if (!isIsoDate(eventDate) || eventDate <= recentLowerBoundExclusive) {
      return false;
    }
  }
  return true;
}

export function setHomeRecommendationCompletedInDocument(document: HomeRecommendationsDocument, id: string, completed: boolean): boolean {
  let targetId = normalizeFreeText(id);
  if (targetId.length === 0) {
    return false;
  }
  let matched = false;
  (document.recommendations || []).forEach((item: HomeRecommendationState) => {
    if (normalizeFreeText(item.id) !== targetId) {
      return;
    }
    matched = true;
    item.completed = completed;
  });
  return matched;
}

export function homeProfileDomainDescription(doc: ProfileDomainState | undefined): string {
  if (!doc || doc.event_count === 0) {
    return '暂无数据';
  }
  let shortSummary = normalizeFreeText(doc.short_summary);
  if (shortSummary.length > 0) {
    return shortSummary;
  }
  let summary = normalizeFreeText(doc.summary);
  let claims = doc.claims || [];
  if (summary.length > 0 || claims.length > 0) {
    return '查看画像';
  }
  return '暂无数据';
}

export function homeProfileDomainFullDescription(doc: ProfileDomainState | undefined): string {
  if (!doc || doc.event_count === 0) {
    return '暂无数据';
  }
  let summary = normalizeFreeText(doc.summary);
  if (summary.length > 0) {
    return summary;
  }
  return '暂无数据';
}

export function homeProfileCompleteness(domains: HomeDomainViewModel[]): number {
  let total = 4;
  let count = 0;
  domains.slice(0, total).forEach((domain: HomeDomainViewModel) => {
    if (normalizeFreeText(domain.desc) !== '暂无数据') {
      count++;
    }
  });
  return Math.round(count * 100 / total);
}

function emptyCollectionViewModel(index: number): CollectionViewModel {
  let title = collectionTabSpecByIndex(index).title || '采集记录';
  return {
    title: title,
    countLabel: '0 条',
    lastUpdatedLabel: '暂无同步',
    groups: [],
    rows: [],
    insights: defaultInsights(),
    insightSummary: '同步后，这里会展示采集数据和聊天中提取的相关信息。',
    empty: true
  };
}

function defaultInsights(): CollectionInsightViewModel[] {
  let eat: CollectionInsightViewModel = { color: '#8066FF', name: '吃', value: '0%', widthValue: '0%' };
  let travel: CollectionInsightViewModel = { color: '#5B8DFF', name: '行', value: '0%', widthValue: '0%' };
  let live: CollectionInsightViewModel = { color: '#FFB14B', name: '住', value: '0%', widthValue: '0%' };
  let work: CollectionInsightViewModel = { color: '#42C995', name: '办公', value: '0%', widthValue: '0%' };
  return [eat, travel, live, work];
}

export class DataManagerFacade {
  readonly storage: DataManagerStorage;
  readonly paths: DataManagerPaths;
  private modelClient: DataPipelineModelClient;
  private consolidationService: ConsolidationService;
  private indexService: IndexService;
  private collectionGroupingService: CollectionGroupingService;
  private homeRecommendationService: HomeRecommendationService;
  private imageResolver: DataManagerImageResolver;
  private avatarService: AvatarService;

  constructor(filesDir: string) {
    this.storage = new DataManagerStorage();
    this.paths = new DataManagerPaths(filesDir, this.storage);
    this.modelClient = new DataPipelineModelClient();
    this.consolidationService = new ConsolidationService(this.paths, this.storage, this.modelClient);
    this.indexService = new IndexService(this.paths, this.storage, this.modelClient);
    this.collectionGroupingService = new CollectionGroupingService(this.paths, this.storage, this.modelClient, this.indexService);
    this.homeRecommendationService = new HomeRecommendationService(this.paths, this.storage, this.modelClient, this.indexService);
    this.imageResolver = new DataManagerImageResolver(this.paths, this.storage);
    this.avatarService = new AvatarService(this.paths, this.storage);
  }

  ensureReady(): void {
    this.paths.ensureBaseDirs();
    this.avatarService.ensureReady();
    dataManagerInfo('DataManagerFacade ensureReady: root=' + this.paths.rootDir);
  }

  hasBuiltIndexes(): boolean {
    this.ensureReady();
    return this.storage.exists(this.storage.join(this.paths.indexesRoot, 'manifest.json'));
  }

  queryIndexedEvents(options: QueryOptions): QueryResult {
    this.ensureReady();
    return this.indexService.query(options);
  }

  loadProfileMarkdown(): string {
    this.ensureReady();
    return this.indexService.loadProfileMarkdown();
  }

  hasDailyLogData(): boolean {
    this.ensureReady();
    let files = this.storage.findFiles(this.paths.dailyLogRoot, '.md');
    for (let path of files) {
      let content = this.storage.readText(path, '');
      let document = parseDailyLogDocument(content);
      if (parseNumberedEntries(document.body).length > 0) {
        return true;
      }
    }
    return false;
  }

  hasDataToSync(): boolean {
    return this.hasDailyLogData() || new ChatMemorySync(this.paths, this.storage, this.modelClient).hasDataToSync();
  }

  async refresh(modelConfig: DataManagerModelConfig, progress?: DataManagerProgressCallback, groupingModelConfig?: DataManagerModelConfig): Promise<RefreshSummary> {
    this.ensureReady();
    let groupingConfig = groupingModelConfig ? groupingModelConfig : modelConfig;
    this.emitProgress(progress, '准备', '正在准备数据目录', 0, 100, 2);
    dataManagerInfo(`DataManagerFacade refresh start: modelEnabled=${modelConfig.enabled}, groupingModelEnabled=${groupingConfig.enabled}, dailyRoot=${this.paths.dailyLogRoot}`);
    GalleryMemorySync.sync(this.paths.filesDir);
    let chatSummary = await new ChatMemorySync(this.paths, this.storage, this.modelClient).sync(modelConfig, progress);
    let chatMessage = chatSummary.processedParts > 0 ?
      `已检查近 7 天未处理聊天，提取 ${chatSummary.factCount} 条相关信息` : '';
    let currentSnapshot = this.buildDailyLogSnapshot();
    let previousSnapshot = this.loadDailyLogSnapshot();
    if (this.canSkipRefresh(previousSnapshot, currentSnapshot)) {
      this.emitProgress(progress, '索引', '正在更新采集分组', 96, 100, 96);
      let groups = await this.collectionGroupingService.buildAll(groupingConfig, progress);
      let recommendations = await this.homeRecommendationService.build(groupingConfig, progress, true);
      this.writeDailyLogSnapshot(currentSnapshot);
      let skipped = this.skippedRefreshSummary(currentSnapshot);
      if (chatMessage.length > 0) {
        skipped.skipped = false;
        skipped.message = chatMessage;
      }
      if (groups.updatedGroupDocs > 0 || !recommendations.reused || recommendations.prunedCount > 0) {
        let actions: string[] = [];
        if (groups.updatedGroupDocs > 0) {
          actions.push(`补充更新 ${groups.updatedGroupDocs} 个采集分组`);
        }
        if (!recommendations.reused) {
          actions.push(`生成 ${recommendations.recommendationCount} 条待办推荐`);
        }
        if (recommendations.prunedCount > 0) {
          actions.push(`清理 ${recommendations.prunedCount} 条过期待办推荐`);
        }
        skipped.skipped = false;
        skipped.message = [chatMessage, `daily-log 无新增，${actions.join('，')}`].filter((text: string) => text.length > 0).join('；');
      }
      dataManagerInfo(`DataManagerFacade refresh skipped: daily-log unchanged, treeHash=${currentSnapshot.tree_hash}, events=${skipped.eventCount}, collectionGroups=${groups.groupCount}, groupDocsUpdated=${groups.updatedGroupDocs}, recommendations=${recommendations.recommendationCount}, prunedRecommendations=${recommendations.prunedCount}`);
      this.emitProgress(progress, '完成', skipped.message, 100, 100, 100);
      return skipped;
    }
    if (this.canRecoverIndexesFromConsolidatedOutputs(previousSnapshot, currentSnapshot)) {
      this.emitProgress(progress, '索引', '已整理日志存在，正在重建索引', 0, 100, 60);
      dataManagerInfo(`DataManagerFacade index recovery start: dailyEntries=${currentSnapshot.entry_count}, outputsRoot=${this.paths.outputsRoot}`);
      let index = await this.indexService.build(modelConfig, progress);
      dataManagerInfo(`DataManagerFacade index recovery done: sourceFiles=${index.sourceFiles}, eventCount=${index.eventCount}, profileClaimCount=${index.profileClaimCount}`);
      this.emitProgress(progress, '索引', '正在生成采集分组', 96, 100, 96);
      let collectionGroups = await this.collectionGroupingService.buildAll(groupingConfig, progress);
      dataManagerInfo(`DataManagerFacade recovery collection groups done: tabs=${collectionGroups.tabCount}, groups=${collectionGroups.groupCount}, events=${collectionGroups.eventCount}, reused=${collectionGroups.reusedGroupDocs}, updated=${collectionGroups.updatedGroupDocs}`);
      let recommendations: HomeRecommendationBuildResult = await this.homeRecommendationService.build(groupingConfig, progress);
      dataManagerInfo(`DataManagerFacade recovery home recommendations done: events=${recommendations.totalEvents}, recommendations=${recommendations.recommendationCount}, reused=${recommendations.reused}`);
      this.writeDailyLogSnapshot(currentSnapshot);
      this.emitProgress(progress, '完成', `重建 ${index.eventCount} 条索引事件`, 100, 100, 100);
      return {
        dailyEntryCount: currentSnapshot.entry_count,
        consolidatedRecordCount: this.countConsolidatedRecords(),
        eventCount: index.eventCount,
        profileClaimCount: index.profileClaimCount,
        updatedAt: index.updatedAt,
        message: (chatMessage.length > 0 ? chatMessage + '；' : '') + `基于已整理日志重建 ${index.eventCount} 条索引事件`,
        skipped: false
      };
    }
    let consolidation = await this.consolidationService.consolidateAll(modelConfig, 5, progress);
    this.emitProgress(progress, '索引', '开始构建索引', 0, 100, 60);
    dataManagerInfo(`DataManagerFacade consolidation done: sourceEntries=${consolidation.sourceEntries}, outputFiles=${consolidation.outputFiles}, totalRecords=${consolidation.totalRecords}`);
    let index = await this.indexService.build(modelConfig, progress);
    dataManagerInfo(`DataManagerFacade index done: sourceFiles=${index.sourceFiles}, eventCount=${index.eventCount}, profileClaimCount=${index.profileClaimCount}`);
    this.emitProgress(progress, '索引', '正在生成采集分组', 96, 100, 96);
    let collectionGroups = await this.collectionGroupingService.buildAll(groupingConfig, progress);
    dataManagerInfo(`DataManagerFacade collection groups done: tabs=${collectionGroups.tabCount}, groups=${collectionGroups.groupCount}, events=${collectionGroups.eventCount}, reused=${collectionGroups.reusedGroupDocs}, updated=${collectionGroups.updatedGroupDocs}`);
    let recommendations: HomeRecommendationBuildResult = await this.homeRecommendationService.build(groupingConfig, progress);
    dataManagerInfo(`DataManagerFacade home recommendations done: events=${recommendations.totalEvents}, recommendations=${recommendations.recommendationCount}, reused=${recommendations.reused}`);
    this.writeDailyLogSnapshot(currentSnapshot);
    this.emitProgress(progress, '完成', `生成 ${index.eventCount} 条索引事件`, 100, 100, 100);
    return {
      dailyEntryCount: consolidation.sourceEntries,
      consolidatedRecordCount: consolidation.totalRecords,
      eventCount: index.eventCount,
      profileClaimCount: index.profileClaimCount,
      updatedAt: index.updatedAt,
      message: (chatMessage.length > 0 ? chatMessage + '；' : '') +
        `整理 ${consolidation.sourceEntries} 条日志，生成 ${index.eventCount} 条索引事件`,
      skipped: false
    };
  }

  async regroup(modelConfig: DataManagerModelConfig, progress?: DataManagerProgressCallback): Promise<string> {
    this.ensureReady();
    this.emitProgress(progress, '索引', '正在清空采集分组', 0, 100, 94);
    this.collectionGroupingService.clearPersistedGroups();
    this.emitProgress(progress, '索引', '正在重新生成采集分组', 0, 100, 96);
    let result: CollectionGroupingBuildResult = await this.collectionGroupingService.buildAll(modelConfig, progress, true);
    this.emitProgress(progress, '完成', '采集分组已重建', 100, 100, 100);
    return `重建 ${result.groupCount} 个采集分组，覆盖 ${result.eventCount} 条记录`;
  }

  private emitProgress(progress: DataManagerProgressCallback | undefined, stage: string, message: string, current: number, total: number, percent: number): void {
    if (!progress) {
      return;
    }
    progress(createDataManagerProgress(stage, message, current, total, percent));
  }

  private dailyLogSnapshotPath(): string {
    return this.storage.join(this.paths.consolidationRoot, DAILY_LOG_SNAPSHOT_FILE_NAME);
  }

  private legacyDailyLogSnapshotPath(): string {
    return this.storage.join(this.paths.indexesRoot, DAILY_LOG_SNAPSHOT_FILE_NAME);
  }

  private emptyDailyLogSnapshot(): DailyLogSnapshot {
    return {
      generated_at: '',
      root: 'workflows/daily-log',
      file_count: 0,
      entry_count: 0,
      tree_hash: '',
      files: []
    };
  }

  private buildDailyLogSnapshot(): DailyLogSnapshot {
    let files: DailyLogSnapshotFile[] = [];
    let paths = this.storage.findFiles(this.paths.dailyLogRoot, '.md');
    GalleryMemorySync.dailyLogRelativePaths(this.paths.dailyLogRoot).forEach((relativePath: string) => {
      paths.push(this.storage.join(this.paths.dailyLogRoot, relativePath));
    });
    ChatMemorySync.dailyLogRelativePaths(this.paths.dailyLogRoot, this.storage).forEach((relativePath: string) => {
      paths.push(this.storage.join(this.paths.dailyLogRoot, relativePath));
    });
    stableUnique(paths).forEach((path: string) => {
      let relative = this.storage.relativePath(this.paths.dailyLogRoot, path).replace(/\\/g, '/');
      let content = this.storage.readText(path, '');
      let document = parseDailyLogDocument(content);
      let entryCount = parseNumberedEntries(document.body).length;
      files.push({
        path: relative,
        sha256: this.storage.sha256Text(content),
        entry_count: entryCount
      });
    });
    files.sort((left: DailyLogSnapshotFile, right: DailyLogSnapshotFile) => left.path.localeCompare(right.path));
    let fingerprint = files.map((file: DailyLogSnapshotFile) => {
      return [file.path, file.sha256, String(file.entry_count)].join('\u001f');
    }).join('\u001e');
    let snapshot: DailyLogSnapshot = {
      generated_at: nowIsoLocal(),
      root: 'workflows/daily-log',
      file_count: files.length,
      entry_count: files.reduce((total: number, file: DailyLogSnapshotFile) => total + file.entry_count, 0),
      tree_hash: this.storage.sha256Text(fingerprint),
      files: files
    };
    return snapshot;
  }

  private loadDailyLogSnapshot(): DailyLogSnapshot {
    let snapshot = this.storage.readJson<DailyLogSnapshot>(this.dailyLogSnapshotPath(), this.emptyDailyLogSnapshot());
    if (snapshot.tree_hash.length === 0 && !this.storage.exists(this.dailyLogSnapshotPath())) {
      snapshot = this.storage.readJson<DailyLogSnapshot>(this.legacyDailyLogSnapshotPath(), this.emptyDailyLogSnapshot());
    }
    if (!snapshot || !Array.isArray(snapshot.files)) {
      return this.emptyDailyLogSnapshot();
    }
    return snapshot;
  }

  private writeDailyLogSnapshot(snapshot: DailyLogSnapshot): void {
    this.storage.writeJsonAtomic(this.dailyLogSnapshotPath(), snapshot as Object);
  }

  private canSkipRefresh(previous: DailyLogSnapshot, current: DailyLogSnapshot): boolean {
    if (previous.tree_hash.length === 0 || previous.tree_hash !== current.tree_hash) {
      return false;
    }
    if (previous.file_count !== current.file_count || previous.entry_count !== current.entry_count) {
      return false;
    }
    return this.hasGeneratedDataForSnapshot(current);
  }

  private hasGeneratedDataForSnapshot(snapshot: DailyLogSnapshot): boolean {
    if (snapshot.entry_count === 0) {
      return false;
    }
    let profile = this.indexService.loadProfileState();
    let eventCount = Object.keys(this.indexService.loadEvents()).length;
    return eventCount > 0 && profile.event_count > 0;
  }

  private canRecoverIndexesFromConsolidatedOutputs(previous: DailyLogSnapshot, snapshot: DailyLogSnapshot): boolean {
    if (snapshot.entry_count === 0) {
      return false;
    }
    if (this.sameDailyLogSnapshot(previous, snapshot) && this.hasConsolidatedOutputFilesForSnapshot(snapshot)) {
      dataManagerInfo(`DataManagerFacade index recovery available from persisted snapshot: entries=${snapshot.entry_count}`);
      return true;
    }
    let coveredEntries = 0;
    let stateCache: Record<string, ConsolidatedState> = new Object() as Record<string, ConsolidatedState>;
    let dayDirs = this.storage.listDir(this.paths.dailyLogRoot)
      .filter((name: string) => /^\d{4}-\d{2}-\d{2}$/.test(name));
    for (let day of dayDirs) {
      let month = monthKeyFromDate(day);
      if (month.length === 0) {
        return false;
      }
      let dayDir = this.storage.join(this.paths.dailyLogRoot, day);
      let files = this.storage.listDir(dayDir).filter((name: string) => name.endsWith('.md'));
      for (let fileName of files) {
        let stateKey = month + '\u001f' + fileName;
        if (!stateCache[stateKey]) {
          let statePath = this.paths.outputStatePath(month, fileName);
          if (!this.storage.exists(statePath)) {
            dataManagerInfo(`DataManagerFacade index recovery unavailable: missing state=${statePath}`);
            return false;
          }
          stateCache[stateKey] = this.readConsolidatedStateForCoverage(statePath);
        }
        let state = stateCache[stateKey];
        let processed = state.metadata.processed_entry_hashes || createStringMap();
        let processedRefs: Record<string, boolean> = new Object() as Record<string, boolean>;
        (state.records || []).forEach((record) => {
          (record.source_refs || []).forEach((ref: string) => processedRefs[ref] = true);
        });
        let path = this.storage.join(dayDir, fileName);
        let content = this.storage.readText(path, '');
        if (content.length === 0) {
          continue;
        }
        let document = parseDailyLogDocument(content);
        let numberedEntries = parseNumberedEntries(document.body);
        for (let item of numberedEntries) {
          let index = Number(item.index);
          let text = normalizeFreeText(item.text);
          if (text.length === 0 || isNaN(index)) {
            continue;
          }
          let ref = sourceRef(day, fileName, index);
          let metadata = document.workflow_metadata;
          let currentHash = sourceEntryProcessingHash(this.storage, {
            source_date: day,
            file_name: fileName,
            entry_index: index,
            entry_text: text,
            workflow_metadata: metadata,
            workflow_scene_id: workflowSceneIdFromMetadata(metadata),
            source_ref: ref
          });
          let previousHash = processed[ref] || '';
          let covered = previousHash.length > 0 ? previousHash === currentHash : processedRefs[ref] === true;
          if (!covered) {
            dataManagerInfo(`DataManagerFacade index recovery unavailable: uncovered ref=${ref}, hasHash=${previousHash.length > 0}`);
            return false;
          }
          coveredEntries++;
        }
      }
    }
    let canRecover = coveredEntries === snapshot.entry_count && coveredEntries > 0;
    if (canRecover) {
      dataManagerInfo(`DataManagerFacade index recovery available: coveredEntries=${coveredEntries}`);
    }
    return canRecover;
  }

  private sameDailyLogSnapshot(previous: DailyLogSnapshot, current: DailyLogSnapshot): boolean {
    return previous.tree_hash.length > 0 && previous.tree_hash === current.tree_hash &&
      previous.file_count === current.file_count && previous.entry_count === current.entry_count;
  }

  private hasConsolidatedOutputFilesForSnapshot(snapshot: DailyLogSnapshot): boolean {
    for (let file of snapshot.files || []) {
      let parts = file.path.split('/');
      if (parts.length < 2) {
        return false;
      }
      let day = parts[0];
      let fileName = parts[parts.length - 1];
      let month = monthKeyFromDate(day);
      if (month.length === 0) {
        return false;
      }
      let statePath = this.paths.outputStatePath(month, fileName);
      if (!this.storage.exists(statePath)) {
        dataManagerInfo(`DataManagerFacade index recovery unavailable: snapshot state missing=${statePath}`);
        return false;
      }
    }
    return true;
  }

  private readConsolidatedStateForCoverage(statePath: string): ConsolidatedState {
    return this.storage.readJson<ConsolidatedState>(statePath, {
      metadata: {
        source_date_range: createStringMap(),
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
    });
  }

  private skippedRefreshSummary(snapshot: DailyLogSnapshot): RefreshSummary {
    let profile = this.indexService.loadProfileState();
    let events = this.indexService.loadEvents();
    return {
      dailyEntryCount: snapshot.entry_count,
      consolidatedRecordCount: this.countConsolidatedRecords(),
      eventCount: Object.keys(events).length,
      profileClaimCount: profile.claim_count,
      updatedAt: snapshot.generated_at,
      message: '无新增日志，跳过同步',
      skipped: true
    };
  }

  private countConsolidatedRecords(): number {
    let total = 0;
    this.storage.findFiles(this.paths.outputsRoot, '.md.state.json').forEach((path: string) => {
      let state = this.storage.readJson<ConsolidatedState>(path, {
        metadata: {
          source_date_range: createStringMap(),
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
      });
      total += Array.isArray(state.records) ? state.records.length : 0;
    });
    return total;
  }

  loadHomeViewModel(): HomeProfileViewModel {
    this.homeRecommendationService.pruneInactiveRecommendationsForToday();
    let profile = this.indexService.loadProfileState();
    if (!profile || profile.event_count === 0) {
      let empty = createEmptyHomeProfileViewModel();
      let avatar = this.avatarService.currentHomeView();
      empty.avatarReferencePhotoUri = avatar.avatarReferencePhotoUri;
      empty.avatarMessageForegroundUri = avatar.avatarMessageForegroundUri;
      return empty;
    }
    let domains = this.homeProfileDomains(profile);
    let recommendations = this.homeRecommendations();
    let completeness = homeProfileCompleteness(domains);
    let avatar = this.avatarService.homeView(profile, completeness);
    return {
      avatarUri: avatar.avatarUri,
      avatarForegroundUri: avatar.avatarForegroundUri,
      avatarMessageForegroundUri: avatar.avatarMessageForegroundUri,
      avatarReferencePhotoUri: avatar.avatarReferencePhotoUri,
      avatarStatus: avatar.avatarStatus,
      avatarUpdatedLabel: avatar.avatarUpdatedLabel,
      avatarActionLabel: avatar.avatarActionLabel,
      avatarVersionId: avatar.avatarVersionId,
      updatedLabel: this.lastSyncLabel([]),
      completeness: completeness,
      totalEvents: profile.event_count,
      domains: domains,
      recommendations: recommendations,
      empty: false
    };
  }

  setHomeRecommendationCompleted(id: string, completed: boolean): boolean {
    let targetId = normalizeFreeText(id);
    if (targetId.length === 0) {
      return false;
    }
    let document = this.homeRecommendationService.loadDocument();
    let beforeCompleted = false;
    (document.recommendations || []).forEach((item: HomeRecommendationState) => {
      if (normalizeFreeText(item.id) === targetId) {
        beforeCompleted = item.completed === true;
      }
    });
    let matched = setHomeRecommendationCompletedInDocument(document, targetId, completed);
    if (!matched) {
      return false;
    }
    if (beforeCompleted === completed) {
      return true;
    }
    this.storage.writeJsonAtomic(this.paths.homeRecommendationsPath(), document as Object);
    dataManagerInfo(`Home recommendation completed updated: id=${targetId}, completed=${completed}`);
    return true;
  }

  buildAvatarGenerateRequest(mode: 'text_to_image' | 'image_to_image', sourceImage: string,
    consentedAt: string, photoSource?: string): AvatarGenerateRequest {
    let profile = this.indexService.loadProfileState();
    return this.avatarService.buildGenerateRequest(profile, this.profileCompleteness(profile), mode, sourceImage, consentedAt, photoSource);
  }

  isAvatarProfileSnapshotUnchanged(): boolean {
    let profile = this.indexService.loadProfileState();
    return this.avatarService.isCurrentProfileSnapshotUnchanged(profile, this.profileCompleteness(profile));
  }

  async generateAvatar(config: AvatarProviderConfig, request: AvatarGenerateRequest): Promise<AvatarHomeViewModel> {
    return this.avatarService.generate(config, request);
  }

  async saveAvatarReferencePhoto(sourceUri: string): Promise<AvatarHomeViewModel> {
    return await this.avatarService.saveReferencePhoto(sourceUri);
  }

  async ensureCurrentAvatarForeground(): Promise<AvatarHomeViewModel> {
    return await this.avatarService.ensureCurrentForeground();
  }

  listAvatarVersions(): AvatarVersionViewModel[] {
    return this.avatarService.listVersionViewModels();
  }

  loadCollectionViewModels(): CollectionViewModel[] {
    return collectionTabSpecs().map((spec) => this.loadCollectionViewModel(spec.tabIndex));
  }

  loadCollectionViewModel(tabIndex: number): CollectionViewModel {
    let spec = collectionTabSpecByIndex(tabIndex);
    let result = this.indexService.query(spec.query);
    return this.collectionViewModelFromQueryResult(tabIndex, result.events, result.total_events);
  }

  loadCollectionGroupViewModel(tabIndex: number, groupId: string): CollectionGroupViewModel | null {
    let targetGroupId = normalizeFreeText(groupId);
    if (targetGroupId.length === 0) {
      return null;
    }
    let document = this.collectionGroupingService.loadGroupsDocument(tabIndex);
    for (let group of document.groups) {
      if (group.group_id === targetGroupId) {
        let eventMap = this.indexService.loadEventsByIds(group.event_ids || []);
        let view = this.collectionGroupView(group, eventMap);
        return view.events.length > 0 ? view : null;
      }
    }
    let viewModel = this.loadCollectionViewModel(tabIndex);
    for (let group of viewModel.groups) {
      if (group.id === targetGroupId) {
        return group;
      }
    }
    return null;
  }

  private collectionViewModelFromQueryResult(tabIndex: number, events: IndexedEvent[], totalEvents: number): CollectionViewModel {
    let spec = collectionTabSpecByIndex(tabIndex);
    let document = this.collectionGroupingService.loadGroupsDocument(tabIndex);
    let groupStates = document.groups.length > 0 ? document.groups : heuristicCollectionGroups(spec.tabId, spec.title, events);
    let eventMap = this.eventMapFromEvents(events);
    let groups = groupStates
      .map((group: CollectionGroupState): CollectionGroupViewModel => this.collectionGroupView(group, eventMap))
      .filter((group: CollectionGroupViewModel) => group.events.length > 0);
    if (groups.length === 0 && events.length > 0) {
      groups = heuristicCollectionGroups(spec.tabId, spec.title, events)
        .map((group: CollectionGroupState): CollectionGroupViewModel => this.collectionGroupView(group, eventMap))
        .filter((group: CollectionGroupViewModel) => group.events.length > 0);
    }
    let rows: CollectionRowViewModel[] = [];
    groups.forEach((group: CollectionGroupViewModel) => {
      group.events.forEach((event: CollectionEventViewModel) => {
        rows.push({
          id: event.id,
          title: event.summary,
          source: event.source,
          time: event.time,
          meta: event.meta,
          status: event.status,
          domain: event.domain
        });
      });
    });
    return {
      title: spec.title,
      countLabel: `${totalEvents} 条`,
      lastUpdatedLabel: this.lastSyncLabel(events),
      groups: groups,
      rows: rows,
      insights: this.collectionInsights(events),
      insightSummary: this.collectionInsightSummary(events, groups),
      empty: totalEvents === 0
    };
  }

  private collectionEventView(event: IndexedEvent): CollectionEventViewModel {
    let primaryDomain = event.domains.length > 0 ? event.domains[0] : 'other';
    let fullText = normalizeFreeText(event.normalized_fact || event.summary);
    let summary = normalizeFreeText(event.summary || event.normalized_fact);
    let images: CollectionImageViewModel[] = this.imageResolver.resolveAll(event.image_paths || []);
    let thumbnailUri = '';
    for (let image of images) {
      if (image.available && image.uri.length > 0) {
        thumbnailUri = image.uri;
        break;
      }
    }
    let row: CollectionEventViewModel = {
      id: event.event_id,
      summary: summary,
      fullText: fullText.length > 0 ? fullText : summary,
      normalizedFact: fullText.length > 0 ? fullText : summary,
      source: event.sources.length > 0 ? event.sources.join('、') : sourceDisplayName(event.source_state_file),
      time: event.event_date,
      firstSeenTime: event.event_date,
      lastSeenTime: event.last_seen_date,
      meta: this.eventMeta(event),
      status: '已整理',
      domain: primaryDomain,
      imageRefs: images,
      galleryDetails: GalleryMemorySync.detailsForSourceRefs(this.paths.filesDir, this.paths.dailyLogRoot, event.source_refs || []),
      thumbnailUri: thumbnailUri
    };
    return row;
  }

  private eventMapFromEvents(events: IndexedEvent[]): Record<string, IndexedEvent> {
    let eventMap: Record<string, IndexedEvent> = new Object() as Record<string, IndexedEvent>;
    events.forEach((event: IndexedEvent) => eventMap[event.event_id] = event);
    return eventMap;
  }

  private collectionGroupView(group: CollectionGroupState, eventMap: Record<string, IndexedEvent>): CollectionGroupViewModel {
    let events: CollectionEventViewModel[] = [];
    group.event_ids.forEach((eventId: string) => {
      let event = eventMap[eventId];
      if (!event) {
        return;
      }
      events.push(this.collectionEventView(event));
    });
    let thumbnailUri = this.collectionGroupThumbnail(events);
    let view: CollectionGroupViewModel = {
      id: group.group_id,
      title: group.title,
      source: this.collectionGroupAppSource(group, eventMap),
      time: group.time,
      meta: group.meta.length > 0 ? group.meta : `${events.length} 条`,
      status: group.status.length > 0 ? group.status : '已整理',
      domain: group.domain,
      eventCount: events.length,
      thumbnailUri: thumbnailUri,
      events: events
    };
    return view;
  }

  private collectionGroupThumbnail(events: CollectionEventViewModel[]): string {
    for (let event of events) {
      if (event.thumbnailUri.length > 0) {
        return event.thumbnailUri;
      }
    }
    return '';
  }

  private collectionGroupAppSource(group: CollectionGroupState, eventMap: Record<string, IndexedEvent>): string {
    let appSources: string[] = [];
    (group.event_ids || []).forEach((eventId: string) => {
      let event = eventMap[eventId];
      if (event) {
        appSources.push(sourceAppDisplayName(event.source_state_file));
      }
    });
    let unique = stableUnique(appSources);
    return unique.length > 0 ? unique.join('、') : group.source;
  }

  private eventMeta(event: IndexedEvent): string {
    if (event.entities.length > 0) {
      return event.entities[0].split(':').slice(1).join(':');
    }
    if (event.keywords.length > 0) {
      return event.keywords.slice(0, 2).join('、');
    }
    return displayDomainName(event.domains.length > 0 ? event.domains[0] : 'other');
  }

  private latestEventLabel(events: IndexedEvent[]): string {
    if (events.length === 0) {
      return '暂无同步';
    }
    let latest = events[0].event_date;
    for (let event of events) {
      if (event.event_date > latest) {
        latest = event.event_date;
      }
    }
    return latest;
  }

  private lastSyncLabel(events: IndexedEvent[]): string {
    let snapshot = this.loadDailyLogSnapshot();
    if (normalizeFreeText(snapshot.generated_at).length > 0) {
      return this.formatHomeUpdatedLabel(snapshot.generated_at);
    }
    let profile = this.indexService.loadProfileState();
    if (normalizeFreeText(profile.generated_at).length > 0) {
      return this.formatHomeUpdatedLabel(profile.generated_at);
    }
    return this.latestEventLabel(events);
  }

  private collectionInsights(events: IndexedEvent[]): CollectionInsightViewModel[] {
    if (events.length === 0) {
      return defaultInsights();
    }
    let colors: StringMap = createStringMap();
    colors['eat'] = '#8066FF';
    colors['travel'] = '#5B8DFF';
    colors['live'] = '#FFB14B';
    colors['work'] = '#42C995';
    colors['wear'] = '#FF6B96';
    colors['other'] = '#8B93A4';
    let counts: NumberMap = {};
    events.forEach((event: IndexedEvent) => {
      let domains = event.domains.length > 0 ? event.domains : ['other'];
      domains.forEach((domain: string) => {
        counts[domain] = (counts[domain] || 0) + 1;
      });
    });
    return Object.keys(counts).sort((a: string, b: string) => counts[b] - counts[a]).slice(0, 4).map((domain: string) => {
      let percent = Math.round(counts[domain] * 100 / Math.max(1, events.length));
      let insight: CollectionInsightViewModel = {
        color: colors[domain] || '#8B93A4',
        name: DOMAIN_DISPLAY_NAMES[domain] || domain,
        value: `${percent}%`,
        widthValue: `${Math.max(8, percent)}%`
      };
      return insight;
    });
  }

  private collectionInsightSummary(events: IndexedEvent[], groups: CollectionGroupViewModel[]): string {
    if (events.length === 0) {
      return '暂无可展示的采集数据。';
    }
    if (groups.length > 0) {
      return `已整理 ${groups.length} 个分组，覆盖 ${events.length} 条记录。`;
    }
    let latest = events[0];
    return `最近整理了 ${events.length} 条记录，最新来自 ${latest.sources.join('、') || '本地日志'}。`;
  }

  private domainClaimStatements(doc: ProfileDomainState | undefined): string[] {
    if (!doc || doc.event_count === 0) {
      return [];
    }
    return (doc.claims || [])
      .map((claim: ProfileClaim): string => normalizeFreeText(claim.statement))
      .filter((statement: string) => statement.length > 0)
      .slice(0, 5);
  }

  private formatHomeUpdatedLabel(value: string): string {
    let normalized = normalizeFreeText(value);
    if (normalized.length === 0) {
      return '已生成画像';
    }
    let date = this.parseLocalDate(normalized);
    if (isNaN(date.getTime())) {
      return normalized.length > 16 ? normalized.substring(0, 16).replace('T', ' ') : normalized.replace('T', ' ');
    }
    let now = new Date();
    let hour = String(date.getHours());
    let minute = String(date.getMinutes()).padStart(2, '0');
    if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()) {
      return `今天${hour}:${minute}`;
    }
    let month = String(date.getMonth() + 1);
    let day = String(date.getDate());
    if (date.getFullYear() === now.getFullYear()) {
      return `${month}-${day} ${hour}:${minute}`;
    }
    return `${date.getFullYear()}-${month}-${day} ${hour}:${minute}`;
  }

  private parseLocalDate(value: string): Date {
    let normalized = value.replace('T', ' ');
    let match = /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?/.exec(normalized);
    if (match) {
      return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6] || '0'));
    }
    return new Date(value);
  }

  private profileCompleteness(profile: ProfileState): number {
    return homeProfileCompleteness(this.homeProfileDomains(profile));
  }

  private homeProfileDomains(profile: ProfileState): HomeDomainViewModel[] {
    return defaultHomeDomains().map((item: HomeDomainViewModel) => {
      let doc = profile.domains[item.domain];
      let domain: HomeDomainViewModel = {
        domain: item.domain,
        icon: item.icon,
        title: item.title,
        desc: homeProfileDomainDescription(doc),
        fullDesc: homeProfileDomainFullDescription(doc),
        claims: this.domainClaimStatements(doc),
        color: item.color,
        eventCount: doc ? doc.event_count : 0
      };
      return domain;
    });
  }

  private homeRecommendations(): HomeRecommendationViewModel[] {
    let colors: StringMap = createStringMap();
    colors['eat'] = '#39C2A2';
    colors['wear'] = '#7669FF';
    colors['live'] = '#FF963D';
    colors['travel'] = '#4B9BFF';
    colors['work'] = '#E35D6A';
    colors['other'] = '#8B93A4';
    let document = this.homeRecommendationService.loadDocument();
    let allEventIds: string[] = [];
    (document.recommendations || []).forEach((item: HomeRecommendationState) => {
      allEventIds = allEventIds.concat(item.source_event_ids || []);
    });
    let eventMap = this.indexService.loadEventsByIds(stableUnique(allEventIds));
    let today = nowIsoLocal().substring(0, 10);
    let result: HomeRecommendationViewModel[] = [];
    (document.recommendations || []).forEach((item: HomeRecommendationState) => {
      if (!shouldShowHomeRecommendationInView(item.source_event_ids || [], eventMap, today)) {
        return;
      }
      let domain = normalizeFreeText(item.domain) || 'other';
      let imageRefs = this.recommendationImages(item, eventMap);
      let recommendation: HomeRecommendationViewModel = {
        id: normalizeFreeText(item.id),
        domain: domain,
        tag: this.recommendationTag(item.tag, item.source_event_ids || [], eventMap),
        title: normalizeFreeText(item.title),
        desc: normalizeFreeText(item.desc),
        meta: this.recommendationMeta(item.meta),
        color: colors[domain] || '#8066FF',
        imageRefs: imageRefs,
        thumbnailUri: this.recommendationThumbnail(imageRefs),
        sourceEventIds: (item.source_event_ids || []).slice(),
        detail: this.recommendationDetail(item, eventMap),
        agentTask: this.firstAgentTask(item.source_event_ids || [], eventMap),
        completed: item.completed === true
      };
      if (recommendation.id.length > 0 && recommendation.title.length > 0) {
        result.push(recommendation);
      }
    });
    return result;
  }

  private recommendationTag(value: string, eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    let tag = normalizeFreeText(value);
    if (tag.length >= 2 && tag.length <= 6) {
      return tag;
    }
    return this.todoTypeTag(this.firstTodoType(eventIds, eventMap), this.hasRecommendationDeadline(eventIds, eventMap));
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

  private firstAgentTask(eventIds: string[], eventMap: Record<string, IndexedEvent>): string {
    for (let id of eventIds) {
      let event = eventMap[id];
      let task = event ? normalizeFreeText(event.todo.agent_task) : '';
      if (task.length > 0) {
        return task;
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

  private hasRecommendationDeadline(eventIds: string[], eventMap: Record<string, IndexedEvent>): boolean {
    for (let id of eventIds) {
      let event = eventMap[id];
      if (event && /^\d{4}-\d{2}-\d{2}$/.test(normalizeFreeText(event.todo.deadline))) {
        return true;
      }
    }
    return false;
  }

  private recommendationMeta(value: string): string {
    let meta = normalizeFreeText(value);
    if (/^\d{4}-\d{2}-\d{2}$/.test(meta) || /^\d{1,2}-\d{1,2}(\s+\d{1,2}:\d{2})?$/.test(meta)) {
      return '';
    }
    return meta;
  }

  private recommendationDetail(item: HomeRecommendationState, eventMap: Record<string, IndexedEvent>): string {
    let lines: string[] = [];
    let desc = normalizeFreeText(item.desc);
    if (desc.length > 0) {
      lines.push(desc);
    }
    let meta = this.recommendationMeta(item.meta);
    if (meta.length > 0) {
      lines.push('信息：' + meta);
    }
    let evidence: string[] = [];
    for (let eventId of item.source_event_ids || []) {
      let event = eventMap[eventId];
      if (!event) {
        continue;
      }
      let todoText = normalizeFreeText(event.todo.text);
      if (todoText.length > 0) {
        evidence.push(todoText);
      }
      let text = normalizeFreeText(event.normalized_fact || event.summary);
      if (text.length > 0) {
        evidence.push(text);
      }
      if (evidence.length >= 3) {
        break;
      }
    }
    if (evidence.length > 0) {
      lines.push('相关记录');
      evidence.forEach((text: string) => {
        lines.push(text);
      });
    }
    return lines.join('\n');
  }

  private recommendationImages(item: HomeRecommendationState, eventMap: Record<string, IndexedEvent>): CollectionImageViewModel[] {
    let result: CollectionImageViewModel[] = [];
    let seen: StringMap = createStringMap();
    for (let eventId of item.source_event_ids || []) {
      let event = eventMap[eventId];
      if (!event) {
        continue;
      }
      let images: CollectionImageViewModel[] = this.imageResolver.resolveAll(event.image_paths || []);
      for (let image of images) {
        let key = normalizeFreeText(image.ref) + '|' + normalizeFreeText(image.uri);
        if (seen[key] === '1') {
          continue;
        }
        seen[key] = '1';
        result.push(image);
      }
    }
    return result;
  }

  private recommendationThumbnail(images: CollectionImageViewModel[]): string {
    for (let image of images) {
      if (image.available && image.uri.length > 0) {
        return image.uri;
      }
    }
    return '';
  }
}
