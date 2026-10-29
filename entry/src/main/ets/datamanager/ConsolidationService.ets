import { JSON as ArkJSON } from '@kit.ArkTS';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { DataPipelineModelClient } from './DataPipelineModelClient';
import { dataManagerInfo, dataManagerWarn } from './DataManagerLog';
import {
  AggregatedRecord,
  CandidateFact,
  ConsolidatedMetadata,
  ConsolidatedState,
  DataManagerModelConfig,
  DataManagerProgressCallback,
  DedupDecision,
  SourceEntry,
  JsonMap,
  StringMap,
  createDataManagerProgress,
  createJsonMap,
  createStringMap
} from './DataManagerTypes';
import {
  createNewRecord,
  findExactExistingMatch,
  monthKeyFromDate,
  normalizeDedupText,
  normalizeFreeText,
  nowIsoLocal,
  parseDailyLogDocument,
  parseNumberedEntries,
  RECENT_MATCH_DAYS,
  RECENT_MATCH_MAX_RECORDS,
  renderConsolidatedMarkdown,
  runLimitedTasks,
  selectRecentScopeRecords,
  sourceRef,
  stableUnique,
  stableUniqueNumbers,
  updateExistingRecord,
  workflowSceneIdFromMetadata
} from './DataManagerUtils';
import { GalleryMemorySync } from '../utils/gallery/GalleryMemorySync';
import { ChatMemorySync } from './ChatMemorySync';
import { normalizeMemorySceneIds } from '../utils/WorkflowSceneConfig';

export interface ConsolidationResult {
  sourceEntries: number;
  outputFiles: number;
  totalRecords: number;
  updatedAt: string;
}

interface EntryGroup {
  month: string;
  fileName: string;
  entries: SourceEntry[];
}

function groupStateKey(group: EntryGroup): string { return group.month + '/' + group.fileName + '.state.json'; }

interface ConsolidationGroupResult {
  recordCount: number;
  outputFileCount: number;
}

interface EntryGroupPlan {
  group: EntryGroup;
  pendingEntryCount: number;
  existingRecordCount: number;
}

interface ConsolidationOutputStateIndex {
  schema: string;
  generated_at: string;
  state_paths: string[];
  record_counts?: Record<string, number>;
}
interface KnownDailySource { path: string; }
interface KnownDailySources { files: KnownDailySource[]; }
interface PublishedSourceIndex { sources: Record<string, Object>; }

const DEFAULT_CONSOLIDATION_GROUP_CONCURRENCY: number = 4;
const OUTPUT_STATE_INDEX_FILE_NAME: string = 'state-index.json';

export function sourceEntryProcessingHash(storage: DataManagerStorage, entry: SourceEntry): string {
  return storage.sha256Text(normalizeFreeText(entry.entry_text) + '\u001f' + String(entry.workflow_scene_id));
}

export class ConsolidationService {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private modelClient: DataPipelineModelClient;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage, modelClient: DataPipelineModelClient) {
    this.paths = paths;
    this.storage = storage;
    this.modelClient = modelClient;
  }

  async consolidateAll(modelConfig: DataManagerModelConfig, dedupWindow: number = 5, progress?: DataManagerProgressCallback): Promise<ConsolidationResult> {
    this.paths.ensureBaseDirs();
    this.emitProgress(progress, '扫描日志', '正在扫描 daily-log', 0, 100, 5);
    dataManagerInfo(`Consolidation start: dailyRoot=${this.paths.dailyLogRoot}, dedupWindow=${dedupWindow}, modelEnabled=${modelConfig.enabled}`);
    let entries = this.collectSourceEntries();
    let groups = this.groupEntriesByMonth(entries);
    this.writeOutputStateIndex(groups);
    this.emitProgress(progress, '扫描日志', `发现 ${entries.length} 条 daily-log`, 1, 100, 10);
    dataManagerInfo(`Consolidation collected: entries=${entries.length}, groups=${groups.length}`);
    if (entries.length === 0) {
      dataManagerWarn('Consolidation found no daily-log entries. Check fixture import path and file format.');
    }
    let plans = this.planEntryGroups(groups);
    let counts: Record<string, number> = {};
    plans.forEach((plan: EntryGroupPlan) => counts[groupStateKey(plan.group)] = plan.existingRecordCount);
    let pendingPlans = plans.filter((plan: EntryGroupPlan) => plan.pendingEntryCount > 0);
    let skippedRecords = 0;
    plans.forEach((plan: EntryGroupPlan) => {
      if (plan.pendingEntryCount === 0) {
        skippedRecords += plan.existingRecordCount;
      }
    });
    dataManagerInfo(`Consolidation pending groups: pending=${pendingPlans.length}, skipped=${groups.length - pendingPlans.length}`);
    if (pendingPlans.length === 0) {
      this.saveOutputCatalog(groups, counts);
      this.emitProgress(progress, '整理日志', 'daily-log 无新增整理项', groups.length, Math.max(1, groups.length), 58);
      return {
        sourceEntries: entries.length,
        outputFiles: groups.length,
        totalRecords: skippedRecords,
        updatedAt: nowIsoLocal()
      };
    }
    let completedGroups = 0;
    let detailedProgress = pendingPlans.length === 1 ? progress : undefined;
    let tasks = pendingPlans.map((plan: EntryGroupPlan): (() => Promise<ConsolidationGroupResult>) => {
      return async (): Promise<ConsolidationGroupResult> => {
        this.emitProgress(progress, '整理日志', `整理 ${plan.group.fileName}`, completedGroups, pendingPlans.length,
          10 + Math.round(completedGroups * 45 / Math.max(1, pendingPlans.length)));
        dataManagerInfo(`Consolidation group start: month=${plan.group.month}, file=${plan.group.fileName}, entries=${plan.group.entries.length}, pending=${plan.pendingEntryCount}`);
        let result = await this.consolidateGroup(plan.group, modelConfig, dedupWindow, detailedProgress);
        completedGroups++;
        dataManagerInfo(`Consolidation group done: month=${plan.group.month}, file=${plan.group.fileName}, records=${result.records.length}, completed=${completedGroups}/${pendingPlans.length}`);
        this.emitProgress(progress, '整理日志', `已整理 ${completedGroups}/${pendingPlans.length} 个新增日志文件`, completedGroups, pendingPlans.length,
          10 + Math.round(completedGroups * 45 / Math.max(1, pendingPlans.length)));
        return {
          recordCount: result.records.length,
          outputFileCount: 1
        };
      };
    });
    let results = await runLimitedTasks<ConsolidationGroupResult>(tasks, DEFAULT_CONSOLIDATION_GROUP_CONCURRENCY);
    let totalRecords = skippedRecords;
    let outputFiles = groups.length - pendingPlans.length;
    results.forEach((result: ConsolidationGroupResult) => {
      totalRecords += result.recordCount;
      outputFiles += result.outputFileCount;
    });
    results.forEach((result: ConsolidationGroupResult, index: number) => counts[groupStateKey(pendingPlans[index].group)] = result.recordCount);
    this.saveOutputCatalog(groups, counts);
    this.emitProgress(progress, '整理日志', `整理完成，生成 ${totalRecords} 条记录`, 100, 100, 58);
    return {
      sourceEntries: entries.length,
      outputFiles: outputFiles,
      totalRecords: totalRecords,
      updatedAt: nowIsoLocal()
    };
  }

  async consolidateChat(modelConfig: DataManagerModelConfig, progress?: DataManagerProgressCallback): Promise<string[]> {
    this.paths.ensureBaseDirs();
    let groups = this.groupEntriesByMonth(this.collectSourceEntries(true));
    let pending = this.planEntryGroups(groups).filter((plan: EntryGroupPlan): boolean => plan.pendingEntryCount > 0);
    this.emitProgress(progress, '整理聊天', '需更新 ' + pending.length + ' 个聊天记录分组', 0, pending.length, 10);
    for (let index = 0; index < pending.length; index++) {
      await this.consolidateGroup(pending[index].group, modelConfig, 5, progress,
        10 + 45 * index / pending.length, 10 + 45 * (index + 1) / pending.length);
    }
    this.emitProgress(progress, '整理聊天', '聊天记录整理完成', pending.length, pending.length, 58);
    let relativePaths = groups.map((group: EntryGroup): string =>
      this.storage.relativePath(this.paths.outputsRoot, this.paths.outputStatePath(group.month, group.fileName)));
    let path = this.storage.join(this.paths.outputsRoot, OUTPUT_STATE_INDEX_FILE_NAME);
    let previous = this.storage.readJson<ConsolidationOutputStateIndex | null>(path, null);
    let oldPaths: string[];
    if (previous) {
      if (previous.schema !== 'datamanager-consolidation-output-state-index-v1' || !Array.isArray(previous.state_paths)) {
        throw new Error('日志整理清单损坏，请手动同步检查');
      }
      oldPaths = previous.state_paths;
    } else {
      let published = this.storage.readJson<PublishedSourceIndex>(this.storage.join(this.paths.indexesRoot, 'manifest.json'), { sources: {} });
      oldPaths = Object.keys(published.sources);
    }
    let retained = oldPaths.filter((relative: string): boolean =>
      !/^app-chat__(local|cloud)__\d+\.md\.state\.json$/.test(this.storage.basename(relative)));
    let payload: ConsolidationOutputStateIndex = { schema: 'datamanager-consolidation-output-state-index-v1',
      generated_at: nowIsoLocal(), state_paths: stableUnique(retained.concat(relativePaths)).sort() };
    if (previous && previous.record_counts) {
      let previousCounts = previous.record_counts;
      let counts: Record<string, number> = {};
      retained.forEach((path: string) => counts[path] = previousCounts[path] || 0);
      groups.forEach((group: EntryGroup) => counts[groupStateKey(group)] =
        this.readConsolidatedState(this.paths.outputStatePath(group.month, group.fileName)).records.length);
      payload.record_counts = counts;
    }
    this.storage.writeJsonAtomic(path, payload);
    return relativePaths.map((relative: string): string => this.storage.join(this.paths.outputsRoot, relative));
  }

  async consolidateChanged(modelConfig: DataManagerModelConfig, changedPaths: string[], allPaths: string[],
    progress?: DataManagerProgressCallback): Promise<ConsolidationResult> {
    let catalogPath = this.storage.join(this.paths.outputsRoot, OUTPUT_STATE_INDEX_FILE_NAME);
    let previous = this.storage.readJson<ConsolidationOutputStateIndex | null>(catalogPath, null);
    if (!previous || previous.schema !== 'datamanager-consolidation-output-state-index-v1' || !previous.record_counts) {
      return await this.consolidateAll(modelConfig, 5, progress);
    }
    let previousCounts = previous.record_counts;
    let affected = stableUnique(changedPaths.map((path: string): string => path.substring(0, 7) + '/' + this.storage.basename(path) + '.state.json'));
    let selected = allPaths.filter((path: string): boolean =>
      affected.indexOf(path.substring(0, 7) + '/' + this.storage.basename(path) + '.state.json') >= 0);
    let entries = this.collectSourceEntries(false, selected);
    let groups = this.groupEntriesByMonth(entries);
    let counts: Record<string, number> = {};
    let retained = previous.state_paths.filter((path: string): boolean => affected.indexOf(path) < 0);
    retained.forEach((path: string) => counts[path] = previousCounts[path] || 0);
    let tasks = groups.map((group: EntryGroup): (() => Promise<number>) => async (): Promise<number> => {
      this.emitProgress(progress, '整理变化日志', '整理 ' + group.fileName, 0, groups.length, 25);
      return (await this.consolidateGroup(group, modelConfig, 5, progress)).records.length;
    });
    let results = await runLimitedTasks<number>(tasks, DEFAULT_CONSOLIDATION_GROUP_CONCURRENCY);
    groups.forEach((group: EntryGroup, index: number) => { let key = groupStateKey(group); retained.push(key); counts[key] = results[index]; });
    let document: ConsolidationOutputStateIndex = { schema: 'datamanager-consolidation-output-state-index-v1',
      generated_at: nowIsoLocal(), state_paths: stableUnique(retained).sort(), record_counts: counts };
    this.storage.writeJsonAtomic(catalogPath, document);
    dataManagerInfo('SYNC_CONSOLIDATE mode=journal readFiles=' + selected.length + ' affectedGroups=' + affected.length);
    return { sourceEntries: entries.length, outputFiles: document.state_paths.length,
      totalRecords: Object.keys(counts).reduce((total: number, key: string): number => total + counts[key], 0), updatedAt: nowIsoLocal() };
  }

  private saveOutputCatalog(groups: EntryGroup[], counts: Record<string, number>): void {
    let document: ConsolidationOutputStateIndex = { schema: 'datamanager-consolidation-output-state-index-v1',
      generated_at: nowIsoLocal(), state_paths: groups.map((group: EntryGroup): string => groupStateKey(group)).sort(), record_counts: counts };
    this.storage.writeJsonAtomic(this.storage.join(this.paths.outputsRoot, OUTPUT_STATE_INDEX_FILE_NAME), document);
  }

  private collectSourceEntries(chatOnly: boolean = false, selectedPaths?: string[]): SourceEntry[] {
    let entries: SourceEntry[] = [];
    let exportedPaths = selectedPaths || ChatMemorySync.dailyLogRelativePaths(this.paths.dailyLogRoot, this.storage);
    if (!chatOnly && !selectedPaths) { exportedPaths = exportedPaths.concat(GalleryMemorySync.dailyLogRelativePaths(this.paths.dailyLogRoot)); }
    let previous: KnownDailySources = chatOnly || selectedPaths !== undefined ? { files: [] } : this.storage.readJson<KnownDailySources>(
      this.storage.join(this.paths.consolidationRoot, 'daily-log-snapshot.json'), { files: [] });
    if (!chatOnly && previous && Array.isArray(previous.files)) {
      previous.files.forEach((source: KnownDailySource) => {
        if (/^\d{4}-\d{2}-\d{2}\/[^/\\]+\.md$/.test(source.path) &&
          this.storage.exists(this.storage.join(this.paths.dailyLogRoot, source.path))) { exportedPaths.push(source.path); }
      });
    }
    let daySet: Record<string, boolean> = new Object() as Record<string, boolean>;
    (chatOnly || selectedPaths !== undefined ? [] : this.storage.listDir(this.paths.dailyLogRoot))
      .filter((name: string) => /^\d{4}-\d{2}-\d{2}$/.test(name))
      .forEach((name: string) => daySet[name] = true);
    exportedPaths.forEach((relativePath: string) => {
      let slash = relativePath.indexOf('/');
      if (slash > 0) {
        let day = relativePath.substring(0, slash);
        if (/^\d{4}-\d{2}-\d{2}$/.test(day)) {
          daySet[day] = true;
        }
      }
    });
    let dayDirs = Object.keys(daySet).sort();
    dataManagerInfo(`Consolidation daily dirs: count=${dayDirs.length}, names=${dayDirs.slice(0, 8).join(',')}`);
    for (let day of dayDirs) {
      let dayDir = this.storage.join(this.paths.dailyLogRoot, day);
      let fileSet: Record<string, boolean> = new Object() as Record<string, boolean>;
      if (!chatOnly && !selectedPaths) {
        this.storage.listDir(dayDir).filter((name: string) => name.endsWith('.md')).forEach((name: string) => fileSet[name] = true);
      }
      exportedPaths.forEach((relativePath: string) => {
        if (relativePath.startsWith(day + '/')) {
          let fileName = relativePath.substring(day.length + 1);
          if (fileName.endsWith('.md')) {
            fileSet[fileName] = true;
          }
        }
      });
      let files = Object.keys(fileSet).sort();
      dataManagerInfo(`Consolidation day scan: day=${day}, mdFiles=${files.length}`);
      for (let fileName of files) {
        let path = this.storage.join(dayDir, fileName);
        if (!this.storage.exists(path)) { continue; }
        let content = this.storage.readText(path, '\u0000SYNC_UNREADABLE\u0000');
        if (content === '\u0000SYNC_UNREADABLE\u0000') { throw new Error('读取采集日志失败，请重试同步'); }
        if (content.length === 0) {
          continue;
        }
        let document = parseDailyLogDocument(content);
        let body = normalizeFreeText(document.body);
        let rawBody = document.body;
        let numberedEntries = parseNumberedEntries(rawBody);
        for (let item of numberedEntries) {
          let index = Number(item.index);
          let text = normalizeFreeText(item.text);
          if (text.length === 0 || isNaN(index)) {
            continue;
          }
          let metadata: JsonMap = document.workflow_metadata || createJsonMap();
          entries.push({
            source_date: day,
            file_name: fileName,
            entry_index: index,
            entry_text: text,
            workflow_metadata: metadata,
            workflow_scene_id: workflowSceneIdFromMetadata(metadata),
            source_ref: sourceRef(day, fileName, index)
          });
        }
      }
    }
    entries.sort((left: SourceEntry, right: SourceEntry) => {
      return `${left.source_date}/${left.file_name}#${left.entry_index}`.localeCompare(`${right.source_date}/${right.file_name}#${right.entry_index}`);
    });
    return entries;
  }

  private groupEntriesByMonth(entries: SourceEntry[]): EntryGroup[] {
    let groups: Record<string, EntryGroup> = {};
    for (let entry of entries) {
      let month = monthKeyFromDate(entry.source_date);
      if (month.length === 0) {
        continue;
      }
      let key = month + '\n' + entry.file_name;
      if (!groups[key]) {
        let entryGroup: EntryGroup = {
          month: month,
          fileName: entry.file_name,
          entries: []
        };
        groups[key] = entryGroup;
      }
      groups[key].entries.push(entry);
    }
    return Object.keys(groups).sort().map((key: string) => groups[key]);
  }

  private planEntryGroups(groups: EntryGroup[]): EntryGroupPlan[] {
    return groups.map((group: EntryGroup): EntryGroupPlan => {
      let statePath = this.paths.outputStatePath(group.month, group.fileName);
      let state = this.readConsolidatedState(statePath);
      let pending = this.pendingEntries(group.entries, state);
      return {
        group: group,
        pendingEntryCount: this.requiresGroupRebuild(group, state) ? group.entries.length : pending.length,
        existingRecordCount: state.records.length
      };
    });
  }

  private writeOutputStateIndex(groups: EntryGroup[]): void {
    let relativePaths = groups.map((group: EntryGroup): string => {
      return this.storage.relativePath(this.paths.outputsRoot, this.paths.outputStatePath(group.month, group.fileName));
    });
    let payload: ConsolidationOutputStateIndex = {
      schema: 'datamanager-consolidation-output-state-index-v1',
      generated_at: nowIsoLocal(),
      state_paths: stableUnique(relativePaths).sort()
    };
    // 记录本轮整理产物清单，目录枚举不可用时索引阶段仍能找到最新的 state 文件；图库清空时这里会写入空清单。
    this.storage.writeJsonAtomic(this.storage.join(this.paths.outputsRoot, OUTPUT_STATE_INDEX_FILE_NAME), payload as Object);
  }

  private async consolidateGroup(group: EntryGroup, modelConfig: DataManagerModelConfig, dedupWindow: number, progress?: DataManagerProgressCallback, startPercent: number = 12, endPercent: number = 55): Promise<ConsolidatedState> {
    let statePath = this.paths.outputStatePath(group.month, group.fileName);
    let markdownPath = this.paths.outputMarkdownPath(group.month, group.fileName);
    let state = this.readConsolidatedState(statePath);
    if (this.requiresGroupRebuild(group, state)) {
      // A merged record cannot be safely "subtracted" when one source changes.
      // Rebuild only this month/source group from current inputs instead.
      state = { metadata: this.emptyMetadata(group.month, [group.fileName], dedupWindow), records: [] };
      dataManagerInfo('SYNC_SOURCE_REBUILD month=' + group.month + ' entries=' + group.entries.length);
    }
    let records = state.records;
    let nextRecordId = this.nextRecordId(records);
    let pendingEntries = this.pendingEntries(group.entries, state);
    if (pendingEntries.length === 0) {
      this.emitProgress(progress, '整理日志', `跳过 ${group.fileName}`, group.entries.length, group.entries.length, endPercent);
      dataManagerInfo(`Consolidation group skipped: month=${group.month}, file=${group.fileName}, entries=${group.entries.length}`);
      return state;
    }
    this.emitProgress(progress, '拆分事实', `批量拆分 ${pendingEntries.length} 条日志`, 0, pendingEntries.length, startPercent);
    let factsBySource = await this.modelClient.splitEntriesIntoFacts(pendingEntries, modelConfig);
    let totalFacts = 0;
    pendingEntries.forEach((entry: SourceEntry) => {
      totalFacts += (factsBySource[entry.source_ref] || []).length;
    });
    let processedFacts = 0;
    for (let entry of pendingEntries) {
      let facts = factsBySource[entry.source_ref] || [];
      for (let fact of facts) {
        processedFacts++;
        let percent = startPercent + Math.round((endPercent - startPercent) * processedFacts / Math.max(1, totalFacts));
        this.emitProgress(progress, '语义去重', `整理 ${group.fileName} (${processedFacts}/${Math.max(1, totalFacts)})`, processedFacts, Math.max(1, totalFacts), percent);
        let scopedRecords = selectRecentScopeRecords(records, fact);
        let exactMatch = findExactExistingMatch(scopedRecords, fact);
        if (exactMatch !== null) {
          let exactDecision: DedupDecision = {
            decision: 'duplicate',
            matched_record_ids: [exactMatch.record_id],
            reason: 'exact_existing_match',
            merged_summary: '',
            merged_fact: '',
            merged_tags: []
          };
          updateExistingRecord(exactMatch, fact, exactDecision);
          continue;
        }
        let decision = await this.modelClient.decideDedup(fact, scopedRecords, modelConfig, dedupWindow);
        let matchedRecord = this.findMatchedRecord(records, decision);
        let decisionText = normalizeFreeText(decision.decision);
        if ((decisionText === 'duplicate' || decisionText === 'merge_with_existing') && matchedRecord !== null) {
          updateExistingRecord(matchedRecord, fact, decision);
        } else if (decisionText === 'skip_ambiguous') {
          continue;
        } else {
          records.push(createNewRecord(nextRecordId, fact, decision));
          nextRecordId++;
        }
      }
    }
    records.sort((left: AggregatedRecord, right: AggregatedRecord) => {
      if (left.first_seen_date !== right.first_seen_date) {
        return left.first_seen_date.localeCompare(right.first_seen_date);
      }
      return left.record_id - right.record_id;
    });
    let metadata = this.buildMetadata(group, records, dedupWindow);
    let nextState: ConsolidatedState = {
      metadata: metadata,
      records: records
    };
    this.storage.writeJsonAtomic(statePath, nextState as Object);
    this.storage.writeTextAtomic(markdownPath, renderConsolidatedMarkdown(records));
    return nextState;
  }

  private emitProgress(progress: DataManagerProgressCallback | undefined, stage: string, message: string, current: number, total: number, percent: number): void {
    if (!progress) {
      return;
    }
    progress(createDataManagerProgress(stage, message, current, total, percent));
  }

  private readConsolidatedState(statePath: string): ConsolidatedState {
    let empty: ConsolidatedState = {
      metadata: this.emptyMetadata('', [], 5),
      records: []
    };
    let payload = this.storage.readJson<ConsolidatedState>(statePath, empty);
    if (!payload || !Array.isArray(payload.records)) {
      return empty;
    }
    let records: AggregatedRecord[] = [];
    for (let item of payload.records) {
      if (!item || typeof item !== 'object') {
        continue;
      }
      item.dedup_text = normalizeDedupText(item.dedup_text || item.normalized_fact || '');
      item.source_refs = Array.isArray(item.source_refs) ? item.source_refs : [];
      item.source_dates = Array.isArray(item.source_dates) ? item.source_dates : [];
      item.workflow_scene_ids = Array.isArray(item.workflow_scene_ids) ? normalizeMemorySceneIds(stableUniqueNumbers(item.workflow_scene_ids)) : [];
      item.raw_excerpts = Array.isArray(item.raw_excerpts) ? item.raw_excerpts : [];
      item.tags = Array.isArray(item.tags) ? item.tags : [];
      item.model_notes = Array.isArray(item.model_notes) ? item.model_notes : [];
      records.push(item);
    }
    return {
      metadata: this.normalizeMetadata(payload.metadata || empty.metadata),
      records: records
    };
  }

  private normalizeMetadata(metadata: ConsolidatedMetadata): ConsolidatedMetadata {
    if (!metadata.processed_entry_hashes) {
      metadata.processed_entry_hashes = createStringMap();
    }
    return metadata;
  }

  private requiresGroupRebuild(group: EntryGroup, state: ConsolidatedState): boolean {
    let current: StringMap = {};
    group.entries.forEach((entry: SourceEntry) => current[entry.source_ref] = sourceEntryProcessingHash(this.storage, entry));
    let previous = state.metadata.processed_entry_hashes || createStringMap();
    if (Object.keys(previous).some((ref: string): boolean => !current[ref] || previous[ref] !== current[ref])) { return true; }
    return state.records.some((record: AggregatedRecord): boolean =>
      (record.source_refs || []).some((ref: string): boolean => !current[ref] || !previous[ref]));
  }

  private pendingEntries(entries: SourceEntry[], state: ConsolidatedState): SourceEntry[] {
    let processedByHash = state.metadata.processed_entry_hashes || createStringMap();
    let processedRefs: Record<string, boolean> = new Object() as Record<string, boolean>;
    state.records.forEach((record: AggregatedRecord) => {
      (record.source_refs || []).forEach((ref: string) => processedRefs[ref] = true);
    });
    return entries.filter((entry: SourceEntry) => {
      let currentHash = sourceEntryProcessingHash(this.storage, entry);
      let previousHash = processedByHash[entry.source_ref] || '';
      if (previousHash.length > 0) {
        return previousHash !== currentHash;
      }
      return processedRefs[entry.source_ref] !== true;
    });
  }

  private nextRecordId(records: AggregatedRecord[]): number {
    let maxId = 0;
    for (let record of records) {
      if (record.record_id > maxId) {
        maxId = record.record_id;
      }
    }
    return maxId + 1;
  }

  private findMatchedRecord(records: AggregatedRecord[], decision: DedupDecision): AggregatedRecord | null {
    let ids = decision.matched_record_ids;
    if (ids.length === 0) {
      return null;
    }
    let id = Number(ids[0]);
    if (isNaN(id)) {
      return null;
    }
    for (let record of records) {
      if (record.record_id === id) {
        return record;
      }
    }
    return null;
  }

  private buildMetadata(group: EntryGroup, records: AggregatedRecord[], dedupWindow: number): ConsolidatedMetadata {
    let dates = stableUnique(group.entries.map((entry: SourceEntry) => entry.source_date)).sort();
    let dateRange: StringMap = createStringMap();
    dateRange['start_date'] = dates.length > 0 ? dates[0] : '';
    dateRange['end_date'] = dates.length > 0 ? dates[dates.length - 1] : '';
    let entryHashes: StringMap = createStringMap();
    group.entries.forEach((entry: SourceEntry) => {
      entryHashes[entry.source_ref] = sourceEntryProcessingHash(this.storage, entry);
    });
    let metadata: ConsolidatedMetadata = {
      source_date_range: dateRange,
      source_files: [group.fileName],
      processed_entry_hashes: entryHashes,
      latest_record_index: this.nextRecordId(records) - 1,
      dedup_window_size: dedupWindow,
      updated_at: nowIsoLocal(),
      total_records: records.length,
      month: group.month,
      recent_match_days: RECENT_MATCH_DAYS,
      recent_match_max_records: RECENT_MATCH_MAX_RECORDS
    };
    return metadata;
  }

  private emptyMetadata(month: string, sourceFiles: string[], dedupWindow: number): ConsolidatedMetadata {
    let dateRange: StringMap = createStringMap();
    let metadata: ConsolidatedMetadata = {
      source_date_range: dateRange,
      source_files: sourceFiles,
      processed_entry_hashes: createStringMap(),
      latest_record_index: 0,
      dedup_window_size: dedupWindow,
      updated_at: '',
      total_records: 0,
      month: month,
      recent_match_days: RECENT_MATCH_DAYS,
      recent_match_max_records: RECENT_MATCH_MAX_RECORDS
    };
    return metadata;
  }
}
