import fs from '@ohos.file.fs';
import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { MemoryChangeJournal } from '../../datamanager/MemoryChangeJournal';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { decodeUtf8Compat, encodeUtf8Compat } from '../TextEncodingCompat';
import {
  GalleryAnalysisResult,
  GalleryEmbeddingRecord,
  GalleryLocationCacheRecord,
  GalleryMonthSummaryCacheRecord,
  GalleryScanSession
} from './GalleryTypes';
import { GalleryExifUtils } from './GalleryExifUtils';

const GALLERY_LOG_DIR = 'gallery-log';
const DAILY_LOG_DIR = 'daily-log';
const ITEMS_DIR = 'items';
const EMBEDDINGS_DIR = 'embeddings';
const SCAN_SESSION_FILE = 'scan-session.json';
const MONTHLY_SUMMARIES_FILE = 'monthly-summaries.json';
const LOCATION_CACHE_FILE = 'location-cache.json';
const METADATA_START = '<!-- DAILY_LOG_METADATA';
const METADATA_END = '-->';

interface GalleryDailyMetadata {
  source: string;
  date: string;
  category: string;
  latest_entry_index: number;
  item_count: number;
}

export class GalleryStorage {
  static rootDir(filesDir: string): string {
    return filesDir + '/' + GALLERY_LOG_DIR;
  }

  static dailyRoot(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + DAILY_LOG_DIR;
  }

  static itemRoot(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + ITEMS_DIR;
  }

  static embeddingRoot(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + EMBEDDINGS_DIR;
  }

  static scanSessionPath(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + SCAN_SESSION_FILE;
  }

  // 月度总结单独落盘，避免重新进入图库页时只依赖页面内存导致总结丢失。
  static monthlySummariesPath(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + MONTHLY_SUMMARIES_FILE;
  }

  // 经纬度逆地理编码缓存独立落盘，避免每次打开详情页都请求第三方地图服务。
  static locationCachePath(filesDir: string): string {
    return GalleryStorage.rootDir(filesDir) + '/' + LOCATION_CACHE_FILE;
  }

  static itemPath(filesDir: string, result: GalleryAnalysisResult): string {
    return GalleryStorage.itemPathById(filesDir, result.date, result.id);
  }

  static embeddingPath(filesDir: string, record: GalleryEmbeddingRecord): string {
    return GalleryStorage.embeddingPathById(filesDir, record.date, record.id);
  }

  static embeddingRef(record: GalleryEmbeddingRecord): string {
    return GalleryStorage.embeddingRefById(record.date, record.id);
  }

  static embeddingRefById(date: string, id: string): string {
    return GALLERY_LOG_DIR + '/' + EMBEDDINGS_DIR + '/' + GalleryStorage.safeDate(date) + '/' + id + '.json';
  }

  static itemPathById(filesDir: string, date: string, id: string): string {
    return GalleryStorage.itemDateDir(filesDir, date) + '/' + id + '.json';
  }

  static embeddingPathById(filesDir: string, date: string, id: string): string {
    return GalleryStorage.embeddingDateDir(filesDir, date) + '/' + id + '.json';
  }

  static hasResult(filesDir: string, date: string, id: string): boolean {
    try {
      return fs.accessSync(GalleryStorage.itemPathById(filesDir, date, id));
    } catch (e) {
      return false;
    }
  }

  static loadResult(filesDir: string, date: string, id: string): GalleryAnalysisResult | null {
    try {
      if (!GalleryStorage.hasResult(filesDir, date, id)) {
        return null;
      }
      return ArkJSON.parse(GalleryStorage.readText(GalleryStorage.itemPathById(filesDir, date, id))) as GalleryAnalysisResult;
    } catch (e) {
      return null;
    }
  }

  static ensureDirectory(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path);
      }
    } catch (e) {
      try {
        fs.mkdirSync(path);
      } catch (err) {
      }
    }
  }

  static ensureWorkspace(filesDir: string): void {
    GalleryStorage.ensureDirectory(GalleryStorage.rootDir(filesDir));
    GalleryStorage.ensureDirectory(GalleryStorage.itemRoot(filesDir));
    GalleryStorage.ensureDirectory(GalleryStorage.embeddingRoot(filesDir));
  }

  static readText(path: string): string {
    try {
      let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        let stat = fs.statSync(path);
        let buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        return decodeUtf8Compat(new Uint8Array(buf));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  static writeText(path: string, content: string): void {
    try {
      let byteStr = encodeUtf8Compat(content);
      let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, byteStr.buffer);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  static writeBytes(path: string, data: ArrayBuffer): void {
    try {
      let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  static loadResults(filesDir: string): GalleryAnalysisResult[] {
    GalleryStorage.ensureWorkspace(filesDir);
    let results: GalleryAnalysisResult[] = [];
    GalleryStorage.collectItems(GalleryStorage.itemRoot(filesDir), results);
    GalleryStorage.sortResultsByRecent(results);
    return results;
  }

  static loadScanSession(filesDir: string): GalleryScanSession | null {
    GalleryStorage.ensureWorkspace(filesDir);
    let path = GalleryStorage.scanSessionPath(filesDir);
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      return ArkJSON.parse(GalleryStorage.readText(path)) as GalleryScanSession;
    } catch (e) {
      return null;
    }
  }

  // 保存全量扫描进度；暂停、恢复和异常退出后都以该文件作为可信恢复来源。
  static saveScanSession(filesDir: string, session: GalleryScanSession): void {
    GalleryStorage.ensureWorkspace(filesDir);
    session.updatedAt = new Date().getTime();
    GalleryStorage.writeText(GalleryStorage.scanSessionPath(filesDir), ArkJSON.stringify(session, null, 2));
  }

  static clearScanSession(filesDir: string): void {
    try {
      fs.unlinkSync(GalleryStorage.scanSessionPath(filesDir));
    } catch (e) {
    }
  }

  // 读取月度 AI 总结缓存，解析失败时返回空对象，避免缓存损坏影响图库主流程。
  static loadMonthlySummaries(filesDir: string): Record<string, GalleryMonthSummaryCacheRecord> {
    GalleryStorage.ensureWorkspace(filesDir);
    let path = GalleryStorage.monthlySummariesPath(filesDir);
    try {
      if (!fs.accessSync(path)) {
        return {};
      }
      return ArkJSON.parse(GalleryStorage.readText(path)) as Record<string, GalleryMonthSummaryCacheRecord>;
    } catch (e) {
      return {};
    }
  }

  // 按月份增量写入总结缓存；页面层负责通过 signature 判断缓存是否仍然匹配当前结果。
  static saveMonthlySummary(filesDir: string, monthKey: string, record: GalleryMonthSummaryCacheRecord): void {
    GalleryStorage.ensureWorkspace(filesDir);
    let summaries = GalleryStorage.loadMonthlySummaries(filesDir);
    summaries[monthKey] = record;
    GalleryStorage.writeText(GalleryStorage.monthlySummariesPath(filesDir), ArkJSON.stringify(summaries, null, 2));
  }

  // 清理图库缓存时同步清理月度总结，避免旧总结引用已删除的分析结果。
  static clearMonthlySummaries(filesDir: string): void {
    try {
      fs.unlinkSync(GalleryStorage.monthlySummariesPath(filesDir));
    } catch (e) {
    }
  }

  static locationCacheKey(latitude: number, longitude: number): string {
    return latitude.toFixed(6) + ',' + longitude.toFixed(6);
  }

  static loadLocationCache(filesDir: string): Record<string, GalleryLocationCacheRecord> {
    GalleryStorage.ensureWorkspace(filesDir);
    let path = GalleryStorage.locationCachePath(filesDir);
    try {
      if (!fs.accessSync(path)) {
        return {};
      }
      return ArkJSON.parse(GalleryStorage.readText(path)) as Record<string, GalleryLocationCacheRecord>;
    } catch (e) {
      return {};
    }
  }

  // 逆地理编码结果按坐标 key 增量写入；页面层只在打开详情页时懒加载缺失坐标。
  static saveLocationCacheRecord(filesDir: string, record: GalleryLocationCacheRecord): void {
    GalleryStorage.ensureWorkspace(filesDir);
    let cache = GalleryStorage.loadLocationCache(filesDir);
    cache[record.key] = record;
    GalleryStorage.writeText(GalleryStorage.locationCachePath(filesDir), ArkJSON.stringify(cache, null, 2));
  }

  static clearLocationCache(filesDir: string): void {
    try {
      fs.unlinkSync(GalleryStorage.locationCachePath(filesDir));
    } catch (e) {
    }
  }

  static upsertResult(filesDir: string, result: GalleryAnalysisResult): GalleryAnalysisResult[] {
    GalleryStorage.writeResult(filesDir, result);
    return GalleryStorage.loadResults(filesDir);
  }

  static writeResult(filesDir: string, result: GalleryAnalysisResult): GalleryAnalysisResult {
    GalleryStorage.ensureWorkspace(filesDir);
    let normalized = GalleryStorage.normalizeResult(result);
    new MemoryChangeJournal(filesDir, new DataManagerStorage()).mark('gallery', normalized.date);
    GalleryStorage.ensureDirectory(GalleryStorage.itemDateDir(filesDir, normalized.date));
    // Commit references atomically before the image store can discard a full-size cache file.
    let path = GalleryStorage.itemPath(filesDir, normalized);
    GalleryStorage.writeText(path + '.tmp', ArkJSON.stringify(normalized, null, 2));
    fs.renameSync(path + '.tmp', path);
    return normalized;
  }

  static upsertEmbedding(filesDir: string, record: GalleryEmbeddingRecord): void {
    GalleryStorage.ensureWorkspace(filesDir);
    let normalized: GalleryEmbeddingRecord = {
      id: record.id,
      uri: record.uri,
      date: GalleryStorage.safeDate(record.date),
      category: GalleryStorage.safeCategory(record.category),
      text: record.text,
      vector: record.vector,
      model: record.model,
      mode: record.mode,
      createdAt: record.createdAt
    };
    GalleryStorage.ensureDirectory(GalleryStorage.embeddingDateDir(filesDir, normalized.date));
    GalleryStorage.writeText(GalleryStorage.embeddingPath(filesDir, normalized), ArkJSON.stringify(normalized, null, 2));
  }

  static clear(filesDir: string): void {
    new MemoryChangeJournal(filesDir, new DataManagerStorage()).mark('gallery', '*');
    GalleryStorage.deletePathRecursively(GalleryStorage.rootDir(filesDir));
    GalleryStorage.ensureWorkspace(filesDir);
  }

  static rebuildDaily(filesDir: string, date: string): void {
    GalleryStorage.ensureWorkspace(filesDir);
    let safeDate = GalleryStorage.safeDate(date);
    let results = GalleryStorage.loadResultsForDate(filesDir, safeDate);
    GalleryStorage.sortResultsByRecent(results);

    let dailyDir = GalleryStorage.dailyDateDir(filesDir, safeDate);
    GalleryStorage.deletePathRecursively(dailyDir);
    GalleryStorage.ensureDirectory(dailyDir);
    let categories = GalleryStorage.categoryOrder();
    for (let c = 0; c < categories.length; c++) {
      let category = categories[c];
      let group = results.filter((item: GalleryAnalysisResult) => GalleryStorage.safeCategory(item.category) === category);
      if (group.length === 0) {
        continue;
      }
      let metadata: GalleryDailyMetadata = {
        source: 'gallery',
        date: safeDate,
        category: category,
        latest_entry_index: group.length,
        item_count: group.length
      };
      let lines: string[] = [
        METADATA_START,
        ArkJSON.stringify(metadata, null, 2),
        METADATA_END,
        '',
        '# ' + safeDate + ' / ' + category,
        ''
      ];
      for (let j = 0; j < group.length; j++) {
        lines.push((j + 1).toString() + '. [' + group[j].id + '] ' +
          GalleryStorage.dailyInlineText(group[j].title) + ': ' +
          GalleryStorage.dailyInlineText(group[j].summary));
        if (group[j].details && group[j].details.length > 0) {
          for (let k = 0; k < group[j].details.length; k++) {
            let detail = GalleryStorage.dailyInlineText(group[j].details[k]);
            if (detail.length > 0) {
              lines.push('   - ' + detail);
            }
          }
        }
        let locationText = GalleryStorage.dailyLocationText(group[j]);
        if (locationText.length > 0) {
          lines.push('   - 位置：' + locationText);
        }
        let addressText = GalleryStorage.dailyAddressText(group[j]);
        if (addressText.length > 0) {
          lines.push('   - 地理位置：' + addressText);
        }
        let poiText = GalleryStorage.dailyPoiText(group[j]);
        if (poiText.length > 0) {
          lines.push('   - 附近地点：' + poiText);
        }
        let mapText = GalleryStorage.dailyMapText(group[j]);
        if (mapText.length > 0) {
          lines.push('   - 地图标注：' + mapText);
        }
        let captureText = GalleryStorage.dailyCaptureText(group[j]);
        if (captureText.length > 0) {
          lines.push('   - ' + captureText);
        }
        lines.push('');
      }
      GalleryStorage.writeText(GalleryStorage.dailyCategoryPath(filesDir, safeDate, category), lines.join('\n'));
    }
  }

  static rebuildDailyForDates(filesDir: string, dates: string[]): void {
    let seen: Record<string, boolean> = {};
    for (let i = 0; i < dates.length; i++) {
      let date = GalleryStorage.safeDate(dates[i]);
      if (seen[date]) {
        continue;
      }
      seen[date] = true;
      GalleryStorage.rebuildDaily(filesDir, date);
    }
  }

  static formatDate(ts: number): string {
    let date = new Date(ts);
    let y = date.getFullYear();
    let m = (date.getMonth() + 1).toString().padStart(2, '0');
    let d = date.getDate().toString().padStart(2, '0');
    return y + '-' + m + '-' + d;
  }

  private static normalizeResult(result: GalleryAnalysisResult): GalleryAnalysisResult {
    let createdAt = result.createdAt > 0 ? result.createdAt : new Date().getTime();
    let category = GalleryStorage.safeCategory(result.category);
    let date = result.date && result.date.length > 0 ? GalleryStorage.safeDate(result.date) : GalleryStorage.formatDate(createdAt);
    let latitude = result.latitude;
    let longitude = result.longitude;
    if (latitude === undefined && result.exif && result.exif.latitude !== undefined) {
      latitude = result.exif.latitude;
    }
    if (longitude === undefined && result.exif && result.exif.longitude !== undefined) {
      longitude = result.exif.longitude;
    }
    let location = GalleryStorage.normalizedLocation(result.location, latitude, longitude);
    return {
      id: result.id,
      uri: result.uri,
      thumbnailUri: result.thumbnailUri ? result.thumbnailUri : '',
      hdcSourcePath: result.hdcSourcePath,
      hdcSourceSize: result.hdcSourceSize,
      hdcModifiedAt: result.hdcModifiedAt,
      hdcChecksum: result.hdcChecksum,
      title: result.title,
      category: category,
      summary: result.summary,
      details: result.details ? result.details : [],
      tags: result.tags ? result.tags : [],
      ocrText: result.ocrText,
      rawModelText: result.rawModelText,
      keywords: result.keywords ? result.keywords : [],
      date: date,
      embeddingRef: result.embeddingRef,
      embeddingStatus: result.embeddingStatus,
      embeddingDimension: result.embeddingDimension,
      error: result.error,
      latitude: latitude,
      longitude: longitude,
      exif: result.exif,
      location: location,
      createdAt: createdAt
    };
  }

  private static normalizedLocation(record: GalleryLocationCacheRecord | undefined,
    latitude: number | undefined, longitude: number | undefined): GalleryLocationCacheRecord | undefined {
    if (!record) {
      return undefined;
    }
    let rawLatitude = Number(record.rawLatitude);
    let rawLongitude = Number(record.rawLongitude);
    if (!GalleryExifUtils.isValidLocation(rawLatitude, rawLongitude)) {
      rawLatitude = Number(latitude);
      rawLongitude = Number(longitude);
    }
    if (!GalleryExifUtils.isValidLocation(rawLatitude, rawLongitude)) {
      return undefined;
    }
    return {
      key: record.key && record.key.length > 0 ? record.key : GalleryStorage.locationCacheKey(rawLatitude, rawLongitude),
      provider: record.provider && record.provider.length > 0 ? record.provider : 'amap',
      rawLatitude: rawLatitude,
      rawLongitude: rawLongitude,
      amapLatitude: Number(record.amapLatitude),
      amapLongitude: Number(record.amapLongitude),
      formattedAddress: record.formattedAddress ? record.formattedAddress : '',
      province: record.province ? record.province : '',
      city: record.city ? record.city : '',
      district: record.district ? record.district : '',
      township: record.township ? record.township : '',
      street: record.street ? record.street : '',
      poiName: record.poiName ? record.poiName : '',
      updatedAt: record.updatedAt > 0 ? record.updatedAt : new Date().getTime()
    };
  }

  private static dailyLocationText(result: GalleryAnalysisResult): string {
    let latitude = result.latitude;
    let longitude = result.longitude;
    if (latitude === undefined && result.exif && result.exif.latitude !== undefined) {
      latitude = result.exif.latitude;
    }
    if (longitude === undefined && result.exif && result.exif.longitude !== undefined) {
      longitude = result.exif.longitude;
    }
    let location = GalleryExifUtils.directedLocationText(latitude, longitude);
    if (location.length > 0) {
      return location;
    }
    return GalleryExifUtils.rawGpsLocationText(result.exif);
  }

  private static dailyAddressText(result: GalleryAnalysisResult): string {
    if (!result.location) {
      return '';
    }
    return GalleryStorage.dailyInlineText(result.location.formattedAddress);
  }

  private static dailyPoiText(result: GalleryAnalysisResult): string {
    if (!result.location) {
      return '';
    }
    return GalleryStorage.dailyInlineText(result.location.poiName);
  }

  private static dailyMapText(result: GalleryAnalysisResult): string {
    let latitude = result.latitude;
    let longitude = result.longitude;
    if (result.location && GalleryExifUtils.isValidLocation(result.location.amapLatitude, result.location.amapLongitude)) {
      latitude = result.location.amapLatitude;
      longitude = result.location.amapLongitude;
    }
    return GalleryExifUtils.mapUrl(latitude, longitude);
  }

  private static dailyCaptureText(result: GalleryAnalysisResult): string {
    if (!result.exif) {
      return '';
    }
    let parts: string[] = [];
    let capturedAt = GalleryExifUtils.displayDateTime(result.exif.dateTimeOriginal);
    if (capturedAt.length > 0) {
      parts.push('拍摄时间：' + capturedAt);
    }
    let device = GalleryExifUtils.deviceText(result.exif);
    if (device.length > 0) {
      parts.push('拍摄设备：' + device);
    }
    return parts.join('；');
  }

  private static collectItems(dir: string, results: GalleryAnalysisResult[]): void {
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      let names = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        let path = dir + '/' + names[i];
        GalleryStorage.collectItems(path, results);
      }
    } catch (e) {
      if (dir.endsWith('.json')) {
        try {
          results.push(ArkJSON.parse(GalleryStorage.readText(dir)) as GalleryAnalysisResult);
        } catch (err) {
        }
      }
    }
  }

  private static itemDateDir(filesDir: string, date: string): string {
    return GalleryStorage.itemRoot(filesDir) + '/' + GalleryStorage.safeDate(date);
  }

  private static embeddingDateDir(filesDir: string, date: string): string {
    return GalleryStorage.embeddingRoot(filesDir) + '/' + GalleryStorage.safeDate(date);
  }

  private static dailyDateDir(filesDir: string, date: string): string {
    return GalleryStorage.dailyRoot(filesDir) + '/' + GalleryStorage.safeDate(date);
  }

  private static dailyCategoryPath(filesDir: string, date: string, category: string): string {
    return GalleryStorage.dailyDateDir(filesDir, date) + '/' + GalleryStorage.safeCategory(category) + '.md';
  }

  private static loadResultsForDate(filesDir: string, date: string): GalleryAnalysisResult[] {
    let results: GalleryAnalysisResult[] = [];
    GalleryStorage.collectItems(GalleryStorage.itemDateDir(filesDir, date), results);
    return results;
  }

  private static sortResultsByRecent(results: GalleryAnalysisResult[]): void {
    results.sort((left: GalleryAnalysisResult, right: GalleryAnalysisResult) => {
      let rightTime = GalleryStorage.resultTime(right);
      let leftTime = GalleryStorage.resultTime(left);
      if (rightTime !== leftTime) {
        return rightTime - leftTime;
      }
      return right.createdAt - left.createdAt;
    });
  }

  private static resultTime(item: GalleryAnalysisResult): number {
    let dateText = item.date && item.date.length > 0 ? item.date : '';
    if (dateText.length >= 10) {
      let parsed = new Date(dateText + ' 00:00:00').getTime();
      if (!isNaN(parsed)) {
        return parsed;
      }
    }
    return item.createdAt;
  }

  private static safeDate(date: string): string {
    return date.replace(/[\\/:*?"<>|]+/g, '_');
  }

  private static safeCategory(category: string): string {
    let value = category.trim();
    if (value === '聊天' || value === '餐饮' || value === '购物' || value === '出行' ||
      value === '健康' || value === '文档' || value === '工作') {
      return value;
    }
    return '其他';
  }

  private static categoryOrder(): string[] {
    return ['聊天', '文档', '餐饮', '购物', '出行', '健康', '工作', '其他'];
  }

  private static dailyInlineText(value: string): string {
    return value.replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
  }

  private static deletePathRecursively(path: string): number {
    let deleted = 0;
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      let names = fs.listFileSync(path);
      for (let i = 0; i < names.length; i++) {
        deleted += GalleryStorage.deletePathRecursively(path + '/' + names[i]);
      }
      fs.rmdirSync(path);
      return deleted + 1;
    } catch (e) {
      try {
        fs.unlinkSync(path);
        return deleted + 1;
      } catch (err) {
        return deleted;
      }
    }
  }
}
