import fs from '@ohos.file.fs';
import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { CollectionGalleryDetailViewModel, JsonMap, createJsonMap } from '../../datamanager/DataManagerTypes';
import { parseJsonCompat, stringifyJsonCompat } from '../JsonCompat';
import { GalleryExifUtils } from './GalleryExifUtils';
import { GalleryAnalysisResult } from './GalleryTypes';

const GALLERY_LOG_DIR: string = 'gallery-log';
const GALLERY_ITEMS_DIR: string = 'items';
const GALLERY_ITEMS_INDEX_FILE: string = 'items-index.json';
const WORKFLOWS_DIR: string = 'workflows';
const DAILY_LOG_DIR: string = 'daily-log';
const GALLERY_DAILY_PREFIX: string = 'com.huawei.photos__gallery-analysis__';
const GALLERY_DAILY_SUFFIX: string = '.md';
const GALLERY_DAILY_INDEX_FILE: string = 'gallery-analysis-index.json';
const METADATA_START: string = '<!-- DAILY_LOG_METADATA';
const METADATA_END: string = '-->';
type ListFileEntry = string | Record<string, Object | string | number | boolean | null>;

export interface GalleryMemorySyncResult {
  scannedItemCount: number;
  validItemCount: number;
  skippedItemCount: number;
  exportedFileCount: number;
  exportedEntryCount: number;
  deletedFileCount: number;
}

interface GalleryExportGroup {
  date: string;
  category: string;
  items: GalleryAnalysisResult[];
}

interface GallerySourceRefParts {
  date: string;
  fileName: string;
  entryIndex: number;
  category: string;
}

interface GalleryEntryBinding {
  item: GalleryAnalysisResult;
  entryIndex: number;
}

interface GalleryLoadedResults {
  scanned: number;
  valid: GalleryAnalysisResult[];
}

interface GalleryItemsIndexDocument {
  items: string[];
}

interface GalleryDailyExportIndexDocument {
  files: string[];
}

interface GalleryRecoveredModelFields {
  title: string;
  category: string;
  summary: string;
  details: string[];
  tags: string[];
}

// 图库分类复用原有工作流场景时保持同一个 sceneId；工作流未覆盖的图库补充类使用 7 之后的独立编号。
export function galleryMemorySceneIdForCategory(category: string): number {
  let normalized = normalizeGalleryCategory(category);
  if (normalized === '聊天') {
    return 3;
  }
  if (normalized === '购物') {
    return 0;
  }
  if (normalized === '出行') {
    return 6;
  }
  if (normalized === '餐饮') {
    return 1;
  }
  if (normalized === '文档') {
    return 8;
  }
  if (normalized === '健康') {
    return 9;
  }
  if (normalized === '工作') {
    return 10;
  }
  return 11;
}

export class GalleryMemorySync {
  static hasNewValidResultsSince(filesDir: string, lastSyncMs: number): boolean {
    let storage = new DataManagerStorage();
    return GalleryMemorySync.loadValidResults(filesDir, storage).valid.some((item: GalleryAnalysisResult): boolean =>
      Number.isFinite(item.createdAt) && item.createdAt > lastSyncMs);
  }

  // 将图库分析结果转换为 workflows/daily-log 输入，是图库进入 DataManager 记忆管线的唯一写入入口。
  // 每次同步会先读取旧导出中的 entry index，再删除旧导出并重建，确保图库清空、重分类或分析失败时不会残留过期 mem 输入。
  static sync(filesDir: string): GalleryMemorySyncResult {
    let storage = new DataManagerStorage();
    let dailyLogRoot = GalleryMemorySync.dailyLogRoot(filesDir, storage);
    let previousIndexes = GalleryMemorySync.readExistingEntryIndexes(dailyLogRoot, storage);
    let deleted = GalleryMemorySync.deleteOldGalleryDailyLogs(dailyLogRoot, storage);
    GalleryMemorySync.exportedFilesForCurrentSync = [];
    let loaded = GalleryMemorySync.loadValidResults(filesDir, storage);
    let groups = GalleryMemorySync.groupResults(loaded.valid);
    let exportedFiles = 0;
    let exportedEntries = 0;

    groups.forEach((group: GalleryExportGroup) => {
      let bindings = GalleryMemorySync.bindEntryIndexes(group, previousIndexes);
      if (bindings.length === 0) {
        return;
      }
      let path = storage.join(dailyLogRoot, group.date, GalleryMemorySync.fileNameForCategory(group.category));
      storage.writeTextAtomic(path, GalleryMemorySync.renderDailyLog(group, bindings));
      GalleryMemorySync.appendExportedFile(group.date + '/' + GalleryMemorySync.fileNameForCategory(group.category));
      exportedFiles += 1;
      exportedEntries += bindings.length;
    });
    GalleryMemorySync.writeExportIndex(dailyLogRoot, storage);

    return {
      scannedItemCount: loaded.scanned,
      validItemCount: loaded.valid.length,
      skippedItemCount: loaded.scanned - loaded.valid.length,
      exportedFileCount: exportedFiles,
      exportedEntryCount: exportedEntries,
      deletedFileCount: deleted
    };
  }

  // IndexService 只保存 source_ref。这里基于图库导出的 source_ref 反查原始 item，并生成可由 DataManagerImageResolver 解析的图片引用。
  static imageRefsForSourceRefs(filesDir: string, dailyLogRoot: string, sourceRefs: string[]): string[] {
    let bindings = GalleryMemorySync.bindingsForSourceRefs(filesDir, dailyLogRoot, sourceRefs);
    let refs: string[] = [];
    bindings.forEach((binding: GalleryEntryBinding) => {
      refs.push(GALLERY_LOG_DIR + '/' + GALLERY_ITEMS_DIR + '/' + binding.item.date + '/' + binding.item.id + '.json#uri');
    });
    return GalleryMemorySync.stableUnique(refs);
  }

  // Collection 详情页使用该接口从 source_ref 拉取图库专属字段，避免把 OCR/EXIF/位置等长字段塞进通用 IndexedEvent。
  static detailsForSourceRefs(filesDir: string, dailyLogRoot: string, sourceRefs: string[]): CollectionGalleryDetailViewModel[] {
    let bindings = GalleryMemorySync.bindingsForSourceRefs(filesDir, dailyLogRoot, sourceRefs);
    let details: CollectionGalleryDetailViewModel[] = [];
    bindings.forEach((binding: GalleryEntryBinding) => {
      details.push(GalleryMemorySync.detailViewModel(binding.item));
    });
    return details;
  }

  // 记录图库导出的 daily-log 相对路径，补足部分测试/沙箱环境中递归目录枚举不稳定的问题。
  static dailyLogRelativePaths(dailyLogRoot: string): string[] {
    let storage = new DataManagerStorage();
    return GalleryMemorySync.readExportIndex(dailyLogRoot, storage);
  }

  private static bindingsForSourceRefs(filesDir: string, dailyLogRoot: string, sourceRefs: string[]): GalleryEntryBinding[] {
    if (!GalleryMemorySync.hasGallerySourceRefs(sourceRefs)) {
      return [];
    }
    let storage = new DataManagerStorage();
    let results = GalleryMemorySync.loadValidResults(filesDir, storage).valid;
    let groups = GalleryMemorySync.groupResults(results);
    let previousIndexes = GalleryMemorySync.readExistingEntryIndexes(dailyLogRoot, storage);
    let bindingMap: Record<string, GalleryEntryBinding> = new Object() as Record<string, GalleryEntryBinding>;
    groups.forEach((group: GalleryExportGroup) => {
      GalleryMemorySync.bindEntryIndexes(group, previousIndexes).forEach((binding: GalleryEntryBinding) => {
        let sourceRef = group.date + '/' + GalleryMemorySync.fileNameForCategory(group.category) + '#' + String(binding.entryIndex);
        bindingMap[sourceRef] = binding;
      });
    });

    let bindings: GalleryEntryBinding[] = [];
    let seen: Record<string, boolean> = new Object() as Record<string, boolean>;
    sourceRefs.forEach((sourceRef: string) => {
      let parts = GalleryMemorySync.parseSourceRef(sourceRef);
      if (parts === null) {
        return;
      }
      let normalizedRef = parts.date + '/' + parts.fileName + '#' + String(parts.entryIndex);
      let binding = bindingMap[normalizedRef];
      if (!binding) {
        return;
      }
      let key = binding.item.date + '/' + binding.item.id;
      if (!seen[key]) {
        seen[key] = true;
        bindings.push(binding);
      }
    });
    return bindings;
  }

  private static hasGallerySourceRefs(sourceRefs: string[]): boolean {
    for (let sourceRef of sourceRefs) {
      if (GalleryMemorySync.parseSourceRef(sourceRef) !== null) {
        return true;
      }
    }
    return false;
  }

  private static loadValidResults(filesDir: string, storage: DataManagerStorage): GalleryLoadedResults {
    let results = GalleryMemorySync.loadGalleryItems(filesDir, storage);
    let valid: GalleryAnalysisResult[] = [];
    results.forEach((item: GalleryAnalysisResult) => {
      if (GalleryMemorySync.isValidResult(item)) {
        valid.push(GalleryMemorySync.normalizeResult(item));
      }
    });
    valid.sort((left: GalleryAnalysisResult, right: GalleryAnalysisResult) => {
      let keyLeft = left.date + '\n' + normalizeGalleryCategory(left.category) + '\n' + left.id;
      let keyRight = right.date + '\n' + normalizeGalleryCategory(right.category) + '\n' + right.id;
      return keyLeft.localeCompare(keyRight);
    });
    let loaded: GalleryLoadedResults = {
      scanned: results.length,
      valid: valid
    };
    return loaded;
  }

  private static loadGalleryItems(filesDir: string, storage: DataManagerStorage): GalleryAnalysisResult[] {
    let root = storage.join(filesDir, GALLERY_LOG_DIR, GALLERY_ITEMS_DIR);
    let results: GalleryAnalysisResult[] = [];
    GalleryMemorySync.listNames(root, storage).forEach((dateName: string) => {
      let dateDir = storage.join(root, dateName);
      GalleryMemorySync.listNames(dateDir, storage)
        .filter((fileName: string) => fileName.endsWith('.json'))
        .forEach((fileName: string) => {
          let content = storage.readText(storage.join(dateDir, fileName), '');
          if (content.length === 0) {
            return;
          }
          try {
            results.push(parseJsonCompat<GalleryAnalysisResult>(content));
          } catch (e) {
          }
        });
    });
    if (results.length === 0) {
      results = GalleryMemorySync.loadGalleryItemsFromIndex(filesDir, storage);
    }
    return results;
  }

  private static loadGalleryItemsFromIndex(filesDir: string, storage: DataManagerStorage): GalleryAnalysisResult[] {
    let path = storage.join(filesDir, GALLERY_LOG_DIR, GALLERY_ITEMS_INDEX_FILE);
    let content = storage.readText(path, '');
    if (content.length === 0) {
      return [];
    }
    try {
      let document = parseJsonCompat<GalleryItemsIndexDocument>(content);
      if (!document || !Array.isArray(document.items)) {
        return [];
      }
      let results: GalleryAnalysisResult[] = [];
      document.items.forEach((relativePath: string) => {
        let normalized = relativePath.replace(/\\/g, '/').replace(/^\/+/g, '');
        if (!normalized.startsWith(GALLERY_LOG_DIR + '/' + GALLERY_ITEMS_DIR + '/') || !normalized.endsWith('.json')) {
          return;
        }
        let itemContent = storage.readText(storage.join(filesDir, normalized), '');
        if (itemContent.length === 0) {
          return;
        }
        try {
          results.push(parseJsonCompat<GalleryAnalysisResult>(itemContent));
        } catch (e) {
        }
      });
      return results;
    } catch (e) {
      return [];
    }
  }

  private static listNames(path: string, storage: DataManagerStorage): string[] {
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      return (fs.listFileSync(path) as ListFileEntry[])
        .map((entry: ListFileEntry): string => GalleryMemorySync.listEntryName(entry, storage))
        .filter((name: string): boolean => name.length > 0)
        .sort();
    } catch (e) {
      return [];
    }
  }

  private static listEntryName(entry: ListFileEntry, storage: DataManagerStorage): string {
    if (typeof entry === 'string') {
      return storage.basename(entry);
    }
    let record = entry as Record<string, Object | string | number | boolean | null>;
    let keys: string[] = ['fileName', 'filename', 'name', 'path', 'uri'];
    for (let key of keys) {
      let value = record[key];
      if (typeof value === 'string' && value.length > 0) {
        return storage.basename(value);
      }
    }
    let dynamicKeys = Object.keys(record);
    for (let key of dynamicKeys) {
      let value = record[key];
      if (typeof value === 'string' && value.length > 0) {
        return storage.basename(value);
      }
    }
    return '';
  }

  private static normalizeResult(result: GalleryAnalysisResult): GalleryAnalysisResult {
    let date = sanitizePathPart(result.date && result.date.length > 0 ? result.date : 'unknown-date');
    let recovered = GalleryMemorySync.recoverModelFields(result);
    let title = normalizeInlineText(result.title);
    if (GalleryMemorySync.isGenericTitle(title) && recovered.title.length > 0) {
      title = recovered.title;
    }
    let category = normalizeGalleryCategory(result.category);
    if (category === '其他' && recovered.category.length > 0) {
      category = normalizeGalleryCategory(recovered.category);
    }
    let summary = normalizeInlineText(result.summary);
    if ((summary.length === 0 || GalleryMemorySync.looksLikeModelPayload(summary)) && recovered.summary.length > 0) {
      summary = recovered.summary;
    }
    let baseDetails: string[] = result.details ? result.details.slice() : [];
    let baseTags: string[] = result.tags ? result.tags.slice() : [];
    let details: string[] = GalleryMemorySync.mergeNonEmptyLists(baseDetails, recovered.details);
    let tags: string[] = GalleryMemorySync.mergeNonEmptyLists(baseTags, recovered.tags);
    return {
      id: sanitizePathPart(result.id),
      uri: result.uri ? result.uri : '',
      thumbnailUri: result.thumbnailUri ? result.thumbnailUri : '',
      title: title,
      category: category,
      summary: summary,
      details: details,
      tags: tags,
      ocrText: result.ocrText ? result.ocrText : '',
      rawModelText: result.rawModelText ? result.rawModelText : '',
      keywords: result.keywords ? result.keywords.slice() : [],
      date: date,
      embeddingRef: result.embeddingRef ? result.embeddingRef : '',
      embeddingStatus: result.embeddingStatus ? result.embeddingStatus : '',
      embeddingDimension: result.embeddingDimension,
      error: result.error ? result.error : '',
      latitude: result.latitude,
      longitude: result.longitude,
      exif: result.exif,
      location: result.location,
      createdAt: result.createdAt
    };
  }

  // 兼容早期图库结果：模型原文可能保存在 rawModelText 或 summary 中，结构化字段仍是“图库图片/其他/空数组”。
  private static recoverModelFields(result: GalleryAnalysisResult): GalleryRecoveredModelFields {
    let recovered = GalleryMemorySync.emptyRecoveredModelFields();
    let sources: string[] = [GalleryMemorySync.rawText(result.rawModelText), GalleryMemorySync.rawText(result.summary)];
    sources.forEach((source: string) => {
      if (source.length === 0) {
        return;
      }
      recovered = GalleryMemorySync.mergeRecoveredModelFields(recovered, GalleryMemorySync.recoverModelFieldsFromText(source));
    });
    return recovered;
  }

  private static emptyRecoveredModelFields(): GalleryRecoveredModelFields {
    return {
      title: '',
      category: '',
      summary: '',
      details: [],
      tags: []
    };
  }

  private static mergeRecoveredModelFields(left: GalleryRecoveredModelFields, right: GalleryRecoveredModelFields): GalleryRecoveredModelFields {
    return {
      title: left.title.length > 0 ? left.title : right.title,
      category: left.category.length > 0 ? left.category : right.category,
      summary: left.summary.length > 0 ? left.summary : right.summary,
      details: GalleryMemorySync.mergeNonEmptyLists(left.details, right.details),
      tags: GalleryMemorySync.mergeNonEmptyLists(left.tags, right.tags)
    };
  }

  private static mergeNonEmptyLists(left: string[], right: string[]): string[] {
    let output: string[] = [];
    left.concat(right).forEach((value: string) => {
      let text = normalizeInlineText(value);
      if (text.length > 0 && output.indexOf(text) < 0) {
        output.push(text);
      }
    });
    return output;
  }

  private static recoverModelFieldsFromText(raw: string): GalleryRecoveredModelFields {
    let recovered = GalleryMemorySync.recoverModelFieldsFromJson(raw);
    recovered = GalleryMemorySync.mergeRecoveredModelFields(recovered, {
      title: GalleryMemorySync.extractLooseField(raw, 'title'),
      category: GalleryMemorySync.extractLooseField(raw, 'category'),
      summary: GalleryMemorySync.extractLooseField(raw, 'summary'),
      details: GalleryMemorySync.extractStringArray(raw, 'details'),
      tags: GalleryMemorySync.extractStringArray(raw, 'tags')
    });
    return recovered;
  }

  private static recoverModelFieldsFromJson(raw: string): GalleryRecoveredModelFields {
    try {
      let payload = parseJsonCompat<JsonMap>(raw);
      if (!payload || typeof payload !== 'object') {
        return GalleryMemorySync.emptyRecoveredModelFields();
      }
      return {
        title: normalizeInlineText(payload['title']),
        category: normalizeInlineText(payload['category']),
        summary: normalizeInlineText(payload['summary']),
        details: GalleryMemorySync.jsonStringList(payload['details']),
        tags: GalleryMemorySync.jsonStringList(payload['tags'])
      };
    } catch (e) {
      return GalleryMemorySync.emptyRecoveredModelFields();
    }
  }

  private static jsonStringList(value: Object | string | number | boolean | null | undefined): string[] {
    if (!Array.isArray(value)) {
      return [];
    }
    let output: string[] = [];
    (value as string[]).forEach((item: string) => {
      let text = normalizeInlineText(item);
      if (text.length > 0 && output.indexOf(text) < 0) {
        output.push(text);
      }
    });
    return output;
  }

  private static extractLooseField(raw: string, key: string): string {
    let quoted = GalleryMemorySync.extractQuotedField(raw, key);
    if (quoted.length > 0) {
      return quoted;
    }
    let marker = '"' + key + '"';
    let markerIndex = raw.indexOf(marker);
    if (markerIndex < 0) {
      return '';
    }
    let colonIndex = raw.indexOf(':', markerIndex + marker.length);
    if (colonIndex < 0) {
      return '';
    }
    let tail = raw.substring(colonIndex + 1).trim();
    let end = GalleryMemorySync.looseFieldEnd(tail);
    let value = tail.substring(0, end).trim();
    if (value.endsWith(',')) {
      value = value.substring(0, value.length - 1).trim();
    }
    return normalizeInlineText(value.replace(/^"+/g, '').replace(/"+$/g, ''));
  }

  private static extractQuotedField(raw: string, key: string): string {
    let pattern = new RegExp('"' + key + '"\\s*:\\s*"([\\s\\S]*?)"');
    let match = pattern.exec(raw);
    if (!match || match.length < 2) {
      return '';
    }
    return normalizeInlineText(match[1]);
  }

  private static looseFieldEnd(tail: string): number {
    let end = tail.length;
    let markers: string[] = [
      ',\n  "category"', ',\n  "summary"', ',\n  "details"', ',\n  "tags"', ',\n  "importance"',
      ',\n"', '\n}', '}'
    ];
    markers.forEach((marker: string) => {
      let index = tail.indexOf(marker);
      if (index >= 0 && index < end) {
        end = index;
      }
    });
    return end;
  }

  private static extractStringArray(raw: string, key: string): string[] {
    let marker = '"' + key + '"';
    let markerIndex = raw.indexOf(marker);
    if (markerIndex < 0) {
      return [];
    }
    let openIndex = raw.indexOf('[', markerIndex + marker.length);
    if (openIndex < 0) {
      return [];
    }
    let closeIndex = raw.indexOf(']', openIndex + 1);
    if (closeIndex < 0) {
      return [];
    }
    let body = raw.substring(openIndex + 1, closeIndex);
    let output: string[] = [];
    let pattern = /"([^"]+)"/g;
    let match: RegExpExecArray | null = pattern.exec(body);
    while (match !== null) {
      let text = normalizeInlineText(match[1]);
      if (text.length > 0 && output.indexOf(text) < 0) {
        output.push(text);
      }
      match = pattern.exec(body);
    }
    return output;
  }

  private static isGenericTitle(title: string): boolean {
    return title.length === 0 || title === '图库图片' || title === '图片分析';
  }

  private static looksLikeModelPayload(value: string): boolean {
    let text = value.trim();
    return text.startsWith('{') && (text.indexOf('"summary"') >= 0 || text.indexOf('"details"') >= 0 ||
      text.indexOf('"title"') >= 0);
  }

  private static rawText(value: string): string {
    if (value === null || value === undefined) {
      return '';
    }
    return String(value).trim();
  }

  private static isValidResult(result: GalleryAnalysisResult): boolean {
    if (normalizeInlineText(result.error).length > 0) {
      return false;
    }
    if (normalizeInlineText(result.title).length > 0 || normalizeInlineText(result.summary).length > 0 ||
      normalizeInlineText(result.ocrText).length > 0) {
      return true;
    }
    if (!result.details) {
      return false;
    }
    for (let detail of result.details) {
      if (normalizeInlineText(detail).length > 0) {
        return true;
      }
    }
    return false;
  }

  private static groupResults(results: GalleryAnalysisResult[]): GalleryExportGroup[] {
    let map: Record<string, GalleryExportGroup> = new Object() as Record<string, GalleryExportGroup>;
    results.forEach((item: GalleryAnalysisResult) => {
      let date = sanitizePathPart(item.date);
      let category = normalizeGalleryCategory(item.category);
      let key = date + '\n' + category;
      if (!map[key]) {
        map[key] = {
          date: date,
          category: category,
          items: []
        };
      }
      map[key].items.push(item);
    });
    return Object.keys(map).sort().map((key: string): GalleryExportGroup => map[key]);
  }

  private static bindEntryIndexes(group: GalleryExportGroup, previousIndexes: Record<string, number>): GalleryEntryBinding[] {
    let used: Record<string, boolean> = new Object() as Record<string, boolean>;
    let bindings: GalleryEntryBinding[] = [];
    let sorted = group.items.slice().sort((left: GalleryAnalysisResult, right: GalleryAnalysisResult) => left.id.localeCompare(right.id));
    sorted.forEach((item: GalleryAnalysisResult) => {
      let key = GalleryMemorySync.entryKey(group.date, group.category, item.id);
      let previous = previousIndexes[key];
      let preferred = previous && previous > 0 ? previous : stableEntryIndexFromId(item.id);
      let entryIndex = GalleryMemorySync.availableEntryIndex(preferred, used);
      used[String(entryIndex)] = true;
      bindings.push({
        item: item,
        entryIndex: entryIndex
      });
    });
    bindings.sort((left: GalleryEntryBinding, right: GalleryEntryBinding) => {
      if (left.entryIndex !== right.entryIndex) {
        return left.entryIndex - right.entryIndex;
      }
      return left.item.id.localeCompare(right.item.id);
    });
    return bindings;
  }

  // item id 派生的编号让新增图片不会改变旧图片 source_ref；极少数 hash 冲突用顺延编号解决。
  private static availableEntryIndex(preferred: number, used: Record<string, boolean>): number {
    let current = preferred > 0 ? preferred : 1;
    while (used[String(current)]) {
      current += 1;
    }
    return current;
  }

  private static renderDailyLog(group: GalleryExportGroup, bindings: GalleryEntryBinding[]): string {
    let workflowMetadata: JsonMap = createJsonMap();
    workflowMetadata['task_scene_id'] = galleryMemorySceneIdForCategory(group.category);
    workflowMetadata['source_kind'] = 'gallery';
    workflowMetadata['gallery_category'] = group.category;
    let latest = 0;
    bindings.forEach((binding: GalleryEntryBinding) => {
      if (binding.entryIndex > latest) {
        latest = binding.entryIndex;
      }
    });
    let metadata: JsonMap = createJsonMap();
    metadata['workflow_metadata'] = workflowMetadata;
    metadata['latest_entry_index'] = latest;

    let lines: string[] = [
      METADATA_START,
      stringifyJsonCompat(metadata, 2),
      METADATA_END,
      '',
      '# 图库分析 / ' + group.date + ' / ' + group.category,
      ''
    ];
    bindings.forEach((binding: GalleryEntryBinding) => {
      lines = lines.concat(GalleryMemorySync.renderEntry(binding));
      lines.push('');
    });
    return lines.join('\n');
  }

  private static renderEntry(binding: GalleryEntryBinding): string[] {
    let item = binding.item;
    let title = item.title.length > 0 ? item.title : '图库图片';
    let summary = item.summary.length > 0 ? item.summary : GalleryMemorySync.firstNonEmptyDetail(item);
    let firstLine = String(binding.entryIndex) + '. [gallery-item:' + item.id + '] ' + title;
    if (summary.length > 0) {
      firstLine += '：' + summary;
    }
    let lines: string[] = [firstLine];
    GalleryMemorySync.nonEmptyList(item.details).forEach((detail: string) => lines.push('   - 细节：' + detail));
    let tags = GalleryMemorySync.nonEmptyList(item.tags);
    if (tags.length > 0) {
      lines.push('   - 标签：' + tags.join('、'));
    }
    let ocrText = normalizeInlineText(item.ocrText);
    if (ocrText.length > 0) {
      lines.push('   - OCR：' + ocrText);
    }
    let captureTime = GalleryExifUtils.displayDateTime(item.exif ? item.exif.dateTimeOriginal : undefined);
    if (captureTime.length > 0) {
      lines.push('   - 拍摄时间：' + captureTime);
    }
    let captureDevice = GalleryExifUtils.deviceText(item.exif);
    if (captureDevice.length > 0) {
      lines.push('   - 拍摄设备：' + captureDevice);
    }
    let captureLocation = GalleryMemorySync.captureLocationText(item);
    if (captureLocation.length > 0) {
      lines.push('   - 拍摄位置：' + captureLocation);
    }
    if (item.location && normalizeInlineText(item.location.formattedAddress).length > 0) {
      lines.push('   - 地址：' + normalizeInlineText(item.location.formattedAddress));
    }
    if (item.location && normalizeInlineText(item.location.poiName).length > 0) {
      lines.push('   - 附近地点：' + normalizeInlineText(item.location.poiName));
    }
    let mapUrl = GalleryMemorySync.mapUrl(item);
    if (mapUrl.length > 0) {
      lines.push('   - 地图：' + mapUrl);
    }
    return lines;
  }

  private static detailViewModel(item: GalleryAnalysisResult): CollectionGalleryDetailViewModel {
    return {
      id: item.id,
      uri: item.uri,
      title: item.title,
      category: item.category,
      summary: item.summary,
      details: GalleryMemorySync.nonEmptyList(item.details),
      tags: GalleryMemorySync.nonEmptyList(item.tags),
      ocrText: normalizeInlineText(item.ocrText),
      date: item.date,
      captureTime: GalleryExifUtils.displayDateTime(item.exif ? item.exif.dateTimeOriginal : undefined),
      captureDevice: GalleryExifUtils.deviceText(item.exif),
      captureLocation: GalleryMemorySync.captureLocationText(item),
      address: item.location ? normalizeInlineText(item.location.formattedAddress) : '',
      poiName: item.location ? normalizeInlineText(item.location.poiName) : '',
      mapUrl: GalleryMemorySync.mapUrl(item)
    };
  }

  private static captureLocationText(item: GalleryAnalysisResult): string {
    let latitude = item.latitude;
    let longitude = item.longitude;
    if (latitude === undefined && item.exif && item.exif.latitude !== undefined) {
      latitude = item.exif.latitude;
    }
    if (longitude === undefined && item.exif && item.exif.longitude !== undefined) {
      longitude = item.exif.longitude;
    }
    let directed = GalleryExifUtils.directedLocationText(latitude, longitude);
    if (directed.length > 0) {
      return directed;
    }
    return GalleryExifUtils.rawGpsLocationText(item.exif);
  }

  private static mapUrl(item: GalleryAnalysisResult): string {
    let latitude = item.latitude;
    let longitude = item.longitude;
    if (item.location && GalleryExifUtils.isValidLocation(item.location.amapLatitude, item.location.amapLongitude)) {
      latitude = item.location.amapLatitude;
      longitude = item.location.amapLongitude;
    }
    return GalleryExifUtils.mapUrl(latitude, longitude);
  }

  private static firstNonEmptyDetail(item: GalleryAnalysisResult): string {
    let details = GalleryMemorySync.nonEmptyList(item.details);
    return details.length > 0 ? details[0] : '';
  }

  private static nonEmptyList(values: string[]): string[] {
    let output: string[] = [];
    values.forEach((value: string) => {
      let text = normalizeInlineText(value);
      if (text.length > 0 && output.indexOf(text) < 0) {
        output.push(text);
      }
    });
    return output;
  }

  private static readExistingEntryIndexes(dailyLogRoot: string, storage: DataManagerStorage): Record<string, number> {
    let map: Record<string, number> = new Object() as Record<string, number>;
    let paths: string[] = [];
    storage.findFiles(dailyLogRoot, GALLERY_DAILY_SUFFIX).forEach((path: string) => paths.push(path));
    GalleryMemorySync.readExportIndex(dailyLogRoot, storage).forEach((relativePath: string) => {
      paths.push(storage.join(dailyLogRoot, relativePath));
    });
    GalleryMemorySync.stableUnique(paths).forEach((path: string) => {
      let fileName = storage.basename(path);
      let category = GalleryMemorySync.categoryFromFileName(fileName);
      if (category.length === 0) {
        return;
      }
      let date = GalleryMemorySync.dateFromDailyPath(dailyLogRoot, path, storage);
      if (date.length === 0) {
        return;
      }
      GalleryMemorySync.readEntryMarkers(storage.readText(path, '')).forEach((binding: GalleryEntryBinding) => {
        map[GalleryMemorySync.entryKey(date, category, binding.item.id)] = binding.entryIndex;
      });
    });
    return map;
  }

  private static readEntryMarkers(content: string): GalleryEntryBinding[] {
    let bindings: GalleryEntryBinding[] = [];
    let pattern: RegExp = /(?:^|\n\s*\n)(\d+)\.\s+\[gallery-item:([^\]]+)\]/g;
    let match: RegExpExecArray | null = pattern.exec(content);
    while (match !== null) {
      let index = Number(match[1]);
      let id = match[2];
      if (!isNaN(index) && index > 0 && id.length > 0) {
        bindings.push({
          item: GalleryMemorySync.placeholderItem(id),
          entryIndex: index
        });
      }
      match = pattern.exec(content);
    }
    return bindings;
  }

  private static placeholderItem(id: string): GalleryAnalysisResult {
    return {
      id: id,
      uri: '',
      thumbnailUri: '',
      title: '',
      category: '其他',
      summary: '',
      details: [],
      tags: [],
      ocrText: '',
      rawModelText: '',
      keywords: [],
      date: '',
      embeddingRef: '',
      embeddingStatus: '',
      embeddingDimension: 0,
      error: '',
      createdAt: 0
    };
  }

  private static deleteOldGalleryDailyLogs(dailyLogRoot: string, storage: DataManagerStorage): number {
    let deleted = 0;
    let paths: string[] = [];
    storage.findFiles(dailyLogRoot, GALLERY_DAILY_SUFFIX).forEach((path: string) => paths.push(path));
    GalleryMemorySync.readExportIndex(dailyLogRoot, storage).forEach((relativePath: string) => {
      paths.push(storage.join(dailyLogRoot, relativePath));
    });
    GalleryMemorySync.stableUnique(paths).forEach((path: string) => {
      if (!storage.basename(path).startsWith(GALLERY_DAILY_PREFIX)) {
        return;
      }
      let existed = storage.exists(path);
      storage.removeFile(path);
      if (existed) {
        deleted += 1;
      }
    });
    return deleted;
  }

  private static exportedFilesForCurrentSync: string[] = [];

  private static appendExportedFile(relativePath: string): void {
    if (GalleryMemorySync.exportedFilesForCurrentSync.indexOf(relativePath) < 0) {
      GalleryMemorySync.exportedFilesForCurrentSync.push(relativePath);
    }
  }

  private static writeExportIndex(dailyLogRoot: string, storage: DataManagerStorage): void {
    let document: GalleryDailyExportIndexDocument = {
      files: GalleryMemorySync.exportedFilesForCurrentSync.slice().sort()
    };
    storage.writeTextAtomic(storage.join(dailyLogRoot, GALLERY_DAILY_INDEX_FILE), stringifyJsonCompat(document as Object, 2));
    GalleryMemorySync.exportedFilesForCurrentSync = [];
  }

  private static readExportIndex(dailyLogRoot: string, storage: DataManagerStorage): string[] {
    let content = storage.readText(storage.join(dailyLogRoot, GALLERY_DAILY_INDEX_FILE), '');
    if (content.length === 0) {
      return [];
    }
    try {
      let document = parseJsonCompat<GalleryDailyExportIndexDocument>(content);
      if (!document || !Array.isArray(document.files)) {
        return [];
      }
      return document.files.slice();
    } catch (e) {
      return [];
    }
  }

  private static parseSourceRef(sourceRef: string): GallerySourceRefParts | null {
    let hashIndex = sourceRef.lastIndexOf('#');
    if (hashIndex < 0) {
      return null;
    }
    let entryIndex = Number(sourceRef.substring(hashIndex + 1));
    if (isNaN(entryIndex) || entryIndex <= 0) {
      return null;
    }
    let path = sourceRef.substring(0, hashIndex).replace(/\\/g, '/');
    let slashIndex = path.lastIndexOf('/');
    if (slashIndex < 0) {
      return null;
    }
    let date = path.substring(0, slashIndex);
    let fileName = path.substring(slashIndex + 1);
    let category = GalleryMemorySync.categoryFromFileName(fileName);
    if (date.length === 0 || category.length === 0) {
      return null;
    }
    return {
      date: date,
      fileName: fileName,
      entryIndex: entryIndex,
      category: category
    };
  }

  private static categoryFromFileName(fileName: string): string {
    if (!fileName.startsWith(GALLERY_DAILY_PREFIX) || !fileName.endsWith(GALLERY_DAILY_SUFFIX)) {
      return '';
    }
    let category = fileName.substring(GALLERY_DAILY_PREFIX.length, fileName.length - GALLERY_DAILY_SUFFIX.length);
    return normalizeGalleryCategory(category);
  }

  private static dateFromDailyPath(dailyLogRoot: string, path: string, storage: DataManagerStorage): string {
    let relative = storage.relativePath(dailyLogRoot, path);
    let slashIndex = relative.indexOf('/');
    if (slashIndex <= 0) {
      return '';
    }
    return relative.substring(0, slashIndex);
  }

  private static dailyLogRoot(filesDir: string, storage: DataManagerStorage): string {
    return storage.join(filesDir, WORKFLOWS_DIR, DAILY_LOG_DIR);
  }

  private static fileNameForCategory(category: string): string {
    return GALLERY_DAILY_PREFIX + normalizeGalleryCategory(category) + GALLERY_DAILY_SUFFIX;
  }

  private static entryKey(date: string, category: string, id: string): string {
    return date + '\n' + normalizeGalleryCategory(category) + '\n' + id;
  }

  private static stableUnique(values: string[]): string[] {
    let output: string[] = [];
    values.forEach((value: string) => {
      if (value.length > 0 && output.indexOf(value) < 0) {
        output.push(value);
      }
    });
    return output;
  }
}

function normalizeGalleryCategory(category: string): string {
  let value = normalizeInlineText(category);
  if (value === '聊天' || value === '购物' || value === '出行' || value === '餐饮' ||
    value === '文档' || value === '健康' || value === '工作') {
    return value;
  }
  return '其他';
}

function normalizeInlineText(value: Object | string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) {
    return '';
  }
  return String(value).replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
}

function sanitizePathPart(value: string): string {
  let text = normalizeInlineText(value).replace(/[\\/:*?"<>|]+/g, '_');
  return text.length > 0 ? text : 'unknown';
}

function stableEntryIndexFromId(id: string): number {
  let hash = 2166136261;
  for (let index = 0; index < id.length; index++) {
    hash ^= id.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % 900000000 + 100000;
}
