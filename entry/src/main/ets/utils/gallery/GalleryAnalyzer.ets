import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { AppLogger } from '../AppLogger';
import { DebugSettings } from '../DebugSettings';
import { CloudModelClient, GalleryCloudModelConfig } from '../CloudModelClient';
import { GalleryOcrService } from './GalleryOcrService';
import { GalleryStorage } from './GalleryStorage';
import { GalleryKeywordFilter } from './GalleryKeywordFilter';
import { GalleryExifUtils } from './GalleryExifUtils';
import { GalleryReverseGeocoder } from './GalleryReverseGeocoder';
import {
  GalleryAnalysisResult,
  GalleryAnalyzeOptions,
  GalleryAnalyzeOutcome,
  GalleryAnalyzerConfig,
  GalleryExifMetadata,
  GalleryLocationCacheRecord,
  GalleryModelJson,
  GalleryPhotoInput,
  GalleryProgress,
  GalleryProgressHandler
} from './GalleryTypes';

const GALLERY_LOG_STORAGE_KEY = 'galleryLogs';
const GALLERY_LOG_MAX_CHARS = 60000;

class GallerySemaphore {
  private permits: number;
  private waiters: Array<() => void> = [];

  constructor(permits: number) {
    this.permits = Math.max(1, permits);
  }

  async acquire(): Promise<void> {
    if (this.permits > 0) {
      this.permits -= 1;
      return;
    }
    await new Promise<void>((resolve) => {
      this.waiters.push(resolve);
    });
  }

  release(): void {
    let next = this.waiters.shift();
    if (next) {
      next();
      return;
    }
    this.permits += 1;
  }
}

interface GalleryStageGates {
  ocr: GallerySemaphore;
  model: GallerySemaphore;
}

interface GalleryModelParseResult {
  json: GalleryModelJson;
  text: string;
}

interface GalleryLocationEnrichResult {
  result: GalleryAnalysisResult;
  updated: boolean;
}

export class GalleryAnalyzer {
  private filesDir: string;
  private cloudClient: CloudModelClient;
  private ocrService: GalleryOcrService = new GalleryOcrService();
  private reverseGeocoder: GalleryReverseGeocoder = new GalleryReverseGeocoder();
  private locationRequests: Record<string, Promise<GalleryLocationCacheRecord | undefined>> = {};
  private locationFailedKeys: Record<string, boolean> = {};

  constructor(filesDir: string, cloudClient: CloudModelClient) {
    this.filesDir = filesDir;
    this.cloudClient = cloudClient;
  }

  async analyzeUris(uris: string[], config: GalleryAnalyzerConfig, onProgress: GalleryProgressHandler,
    onResult?: (result: GalleryAnalysisResult) => void, options?: GalleryAnalyzeOptions): Promise<GalleryAnalysisResult[]> {
    let inputs: GalleryPhotoInput[] = [];
    for (let i = 0; i < uris.length; i++) {
      inputs.push({ uri: uris[i] });
    }
    return this.analyzeInputs(inputs, config, onProgress, onResult, options);
  }

  async analyzeInputs(inputs: GalleryPhotoInput[], config: GalleryAnalyzerConfig, onProgress: GalleryProgressHandler,
    onResult?: (result: GalleryAnalysisResult) => void, options?: GalleryAnalyzeOptions): Promise<GalleryAnalysisResult[]> {
    this.logInfo('batch start selected=' + inputs.length +
      ' skipOcr=' + config.skipOcr +
      ' keywordFilter=' + config.useOcrKeywordFilter +
      ' ocrConcurrency=' + config.ocrConcurrency +
      ' modelConcurrency=' + config.modelConcurrency +
      ' parallelFieldRequests=' + config.parallelFieldRequests +
      ' embeddingConcurrency=' + config.embeddingConcurrency +
      ' embeddingMode=' + config.embeddingMode);
    let batchStartedAt = new Date().getTime();
    let progress: GalleryProgress = {
      selected: inputs.length,
      processed: 0,
      skipped: 0,
      pending: inputs.length,
      ocrDone: 0,
      modelDone: 0,
      embeddingDone: 0,
      failed: 0,
      current: '准备分析'
    };
    onProgress(progress);
    let results: GalleryAnalysisResult[] = [];
    let gates: GalleryStageGates = {
      ocr: new GallerySemaphore(config.ocrConcurrency),
      model: new GallerySemaphore(config.modelConcurrency)
    };
    let limit = Math.max(1, config.ocrConcurrency, config.modelConcurrency);
    await this.runWithLimit(inputs, limit, async (input: GalleryPhotoInput, index: number): Promise<boolean> => {
      // 暂停只阻止新任务进入流水线，已经进入 OCR/模型/Embedding 阶段的图片会继续完成并回调落盘。
      if (options && options.shouldPause && options.shouldPause()) {
        return false;
      }
      progress.current = '分析第 ' + (index + 1) + '/' + inputs.length + ' 张';
      onProgress(progress);
      let outcome = await this.analyzeOne(input, config, gates, progress, onProgress);
      let result = outcome.result;
      results.push(result);
      if (outcome.cached) {
        // 缓存命中代表该图片已有可用分析结果，仍应计入已完成；只有关键词预筛命中时才计入跳过。
        progress.processed += 1;
        progress.pending = Math.max(0, progress.selected - progress.processed);
        if (outcome.skippedByKeyword === true) {
          progress.skipped += 1;
        }
        onProgress(progress);
        if (options && options.onItemDone) {
          options.onItemDone(input, outcome);
        }
        if (onResult && outcome.skippedByKeyword !== true) {
          onResult(result);
        }
        return true;
      }
      this.logInfo('cache result start id=' + result.id);
      let cacheStartedAt = new Date().getTime();
      let normalized = GalleryStorage.writeResult(this.filesDir, result);
      this.logInfo('cache result done id=' + result.id + ' elapsedMs=' + this.elapsed(cacheStartedAt));
      progress.processed += 1;
      progress.pending = Math.max(0, progress.selected - progress.processed);
      onProgress(progress);
      if (options && options.onItemDone) {
        options.onItemDone(input, {
          result: normalized,
          cached: false
        });
      }
      if (onResult) {
        onResult(normalized);
      }
      return true;
    });
    await this.ocrService.release();
    this.logInfo('batch done selected=' + inputs.length +
      ' results=' + results.length +
      ' failed=' + progress.failed +
      ' elapsedMs=' + this.elapsed(batchStartedAt));
    return GalleryStorage.loadResults(this.filesDir);
  }

  private async runWithLimit(items: GalleryPhotoInput[], limit: number, worker: (item: GalleryPhotoInput, index: number) => Promise<boolean>): Promise<void> {
    let nextIndex = 0;
    let workers: Promise<void>[] = [];
    let count = Math.min(limit, items.length);
    for (let i = 0; i < count; i++) {
      workers.push((async () => {
        while (nextIndex < items.length) {
          let index = nextIndex;
          nextIndex += 1;
          let keepGoing = await worker(items[index], index);
          if (!keepGoing) {
            return;
          }
        }
      })());
    }
    await Promise.all(workers);
  }

  private async analyzeOne(input: GalleryPhotoInput, config: GalleryAnalyzerConfig, gates: GalleryStageGates, progress: GalleryProgress,
    onProgress: GalleryProgressHandler): Promise<GalleryAnalyzeOutcome> {
    let uri = input.uri;
    let id = this.stableId(uri);
    let inputId = input.id;
    if (inputId !== undefined && inputId.length > 0) {
      id = inputId;
    }
    let pixelMap: image.PixelMap | null = null;
    let imageSource: image.ImageSource | null = null;
    let imageFile: fileIo.File | null = null;
    let itemStartedAt = new Date().getTime();
    let date = this.resolveImageDate(uri, itemStartedAt);
    let inputDate = input.date;
    let hasInputDate = false;
    if (inputDate !== undefined && inputDate.length > 0) {
      date = inputDate;
      hasInputDate = true;
    }
    let resultLatitude = input.latitude;
    let resultLongitude = input.longitude;
    let exifMetadata: GalleryExifMetadata | undefined = undefined;
    let locationRecord: GalleryLocationCacheRecord | undefined = undefined;
    this.logInfo('item start id=' + id + ' uri=' + uri);
    let cached = GalleryStorage.loadResult(this.filesDir, date, id);
    if (cached && this.isSuccessfulCachedResult(cached)) {
      let cachedLocation = await this.ensureResultLocation(cached, config, id);
      if (cachedLocation.updated) {
        this.logInfo('item cached location enriched id=' + id + ' date=' + cachedLocation.result.date);
        return {
          result: cachedLocation.result,
          cached: false
        };
      }
      progress.current = '命中缓存 ' + id;
      progress.ocrDone += 1;
      progress.modelDone += 1;
      progress.embeddingDone += 1;
      onProgress(progress);
      this.logInfo('item cached hit id=' + id + ' date=' + date + ' path=' + GalleryStorage.itemPathById(this.filesDir, date, id));
      return {
        result: cached,
        cached: true
      };
    }
    if (cached) {
      this.logInfo('item retry cached failure id=' + id + ' date=' + date + ' error=' + cached.error);
    }
    try {
      let decodeStartedAt = new Date().getTime();
      this.logInfo('decode start id=' + id);
      progress.current = '读取图片 ' + id;
      onProgress(progress);
      imageFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(imageFile.fd);
      exifMetadata = await this.readExifMetadata(imageSource, id);
      if (exifMetadata) {
        let exifDate = GalleryExifUtils.dateFromExifDateTime(exifMetadata.dateTimeOriginal);
        if (!hasInputDate && exifDate.length > 0) {
          date = exifDate;
        }
        if (resultLatitude === undefined && exifMetadata.latitude !== undefined) {
          resultLatitude = exifMetadata.latitude;
        }
        if (resultLongitude === undefined && exifMetadata.longitude !== undefined) {
          resultLongitude = exifMetadata.longitude;
        }
        let refreshedCached = GalleryStorage.loadResult(this.filesDir, date, id);
        if (refreshedCached && this.isSuccessfulCachedResult(refreshedCached)) {
          let refreshedLocation = await this.ensureResultLocation(refreshedCached, config, id);
          if (refreshedLocation.updated) {
            this.logInfo('item refreshed cache location enriched id=' + id + ' date=' + refreshedLocation.result.date);
            return {
              result: refreshedLocation.result,
              cached: false
            };
          }
          progress.current = '命中缓存 ' + id;
          progress.ocrDone += 1;
          progress.modelDone += 1;
          progress.embeddingDone += 1;
          onProgress(progress);
          this.logInfo('item cached hit after exif id=' + id + ' date=' + date +
            ' path=' + GalleryStorage.itemPathById(this.filesDir, date, id));
          return {
            result: refreshedCached,
            cached: true
          };
        }
      }
      pixelMap = await imageSource.createPixelMap();
      this.logInfo('decode done id=' + id + ' elapsedMs=' + this.elapsed(decodeStartedAt));
      await this.scaleForAnalysis(pixelMap, config.imageScale, id);
      locationRecord = await this.resolveLocationForCoordinates(resultLatitude, resultLongitude, config, id);

      await gates.ocr.acquire();
      let ocrText = '';
      try {
        if (!config.skipOcr) {
          let ocrStartedAt = new Date().getTime();
          this.logInfo('ocr start id=' + id);
          progress.current = 'OCR 识别 ' + id;
          onProgress(progress);
          ocrText = await this.ocrService.recognize(pixelMap);
          this.logInfo('ocr done id=' + id + ' chars=' + ocrText.length + ' elapsedMs=' + this.elapsed(ocrStartedAt));
        } else {
          this.logInfo('ocr skipped id=' + id);
          progress.current = '跳过 OCR ' + id;
          onProgress(progress);
        }
      } finally {
        gates.ocr.release();
      }
      progress.ocrDone += 1;
      onProgress(progress);

      if (config.useOcrKeywordFilter) {
        let keywordMatch = GalleryKeywordFilter.matchUsefulKeywords(ocrText);
        this.logInfo('keyword filter id=' + id + ' matched=' + keywordMatch.matched +
          ' keywords=' + keywordMatch.keywords.join(','));
        if (!keywordMatch.matched) {
          progress.current = 'OCR 预筛跳过 ' + id;
          progress.modelDone += 1;
          progress.embeddingDone += 1;
          onProgress(progress);
          let skippedResult: GalleryAnalysisResult = {
            id: id,
            uri: uri,
            thumbnailUri: '',
            title: 'OCR 未命中关键信息',
            category: '其他',
            summary: 'OCR 关键词预筛未命中，已跳过模型分析。',
            details: [],
            tags: [],
            ocrText: ocrText,
            rawModelText: '',
            keywords: [],
            date: date,
            embeddingRef: '',
            embeddingStatus: 'skipped',
            embeddingDimension: 0,
            error: '',
            latitude: resultLatitude,
            longitude: resultLongitude,
            exif: exifMetadata,
            location: locationRecord,
            createdAt: new Date().getTime()
          };
          this.logInfo('item skipped keyword filter id=' + id);
          return {
            result: skippedResult,
            cached: true,
            skippedByKeyword: true
          };
        }
      }

      let packStartedAt = new Date().getTime();
      this.logInfo('pack image start id=' + id);
      progress.current = '压缩图片 ' + id;
      onProgress(progress);
      let imageBase64 = await this.pixelMapToJpegBase64(pixelMap);
      this.logInfo('pack image done id=' + id + ' base64Chars=' + imageBase64.length + ' elapsedMs=' + this.elapsed(packStartedAt));
      await gates.model.acquire();
      let rawModelText = '';
      let modelJson: GalleryModelJson = {};
      let exifText = this.exifPromptText(exifMetadata, resultLatitude, resultLongitude, locationRecord);
      try {
        let modelStartedAt = new Date().getTime();
        this.logInfo('model start id=' + id + ' baseUrl=' + config.apiBaseUrl + ' model=' + config.model);
        progress.current = '模型分析 ' + id;
        onProgress(progress);
        if (config.parallelFieldRequests) {
          let fieldResult = await this.cloudClient.analyzeGalleryImageByFields(imageBase64, ocrText, exifText,
            this.toCloudConfig(config));
          rawModelText = fieldResult.rawText;
          modelJson = this.normalizeMergedModelJson(fieldResult.json);
          let fieldCount = this.modelFieldCount(modelJson);
          this.logInfo('model fields merged id=' + id + ' fields=' + fieldCount.toString());
          this.logInfo('model fields raw id=' + id + ' preview=' + this.previewForLog(rawModelText, 512));
          if (fieldCount === 0) {
            this.logInfo('model fields empty fallback full-json id=' + id);
            rawModelText = await this.cloudClient.analyzeGalleryImage(imageBase64, ocrText, exifText, this.toCloudConfig(config));
            this.logInfo('model full-json fallback raw id=' + id + ' chars=' + rawModelText.length.toString() +
              ' preview=' + this.previewForLog(rawModelText, 512));
            this.throwIfModelErrorResponse(rawModelText);
            let modelParse = this.parseModelJson(rawModelText, id);
            modelJson = modelParse.json;
            rawModelText = modelParse.text;
          }
        } else {
          rawModelText = await this.cloudClient.analyzeGalleryImage(imageBase64, ocrText, exifText, this.toCloudConfig(config));
          this.logInfo('model full-json raw id=' + id + ' chars=' + rawModelText.length.toString() +
            ' preview=' + this.previewForLog(rawModelText, 512));
          this.throwIfModelErrorResponse(rawModelText);
          let modelParse = this.parseModelJson(rawModelText, id);
          modelJson = modelParse.json;
          rawModelText = modelParse.text;
        }
        this.logInfo('model done id=' + id + ' chars=' + rawModelText.length + ' elapsedMs=' + this.elapsed(modelStartedAt));
      } finally {
        gates.model.release();
      }
      progress.modelDone += 1;
      onProgress(progress);

      let category = this.nonEmpty(modelJson.category, '其他');
      let details = this.detailListFrom(modelJson.details);
      let tags = this.tagListFrom(modelJson.tags);
      let keywords = this.keywordsFrom(tags, ocrText);
      let embeddingStatus = 'skipped';
      let embeddingDimension = 0;
      let embeddingRef = '';
      this.logInfo('embedding disabled id=' + id);
      progress.current = '跳过 Embedding ' + id;
      onProgress(progress);
      progress.embeddingDone += 1;
      onProgress(progress);

      let result: GalleryAnalysisResult = {
        id: id,
        uri: uri,
        thumbnailUri: '',
        title: this.nonEmpty(modelJson.title, '图库图片'),
        category: category,
        summary: this.nonEmpty(modelJson.summary, ocrText.length > 0 ? ocrText.substring(0, Math.min(80, ocrText.length)) : '未识别到明确文本'),
        details: details,
        tags: tags,
        ocrText: ocrText,
        rawModelText: rawModelText,
        keywords: keywords,
        date: date,
        embeddingRef: embeddingRef,
        embeddingStatus: embeddingStatus,
        embeddingDimension: embeddingDimension,
        error: '',
        latitude: resultLatitude,
        longitude: resultLongitude,
        exif: exifMetadata,
        location: locationRecord,
        createdAt: new Date().getTime()
      };
      this.logInfo('item done id=' + id + ' elapsedMs=' + this.elapsed(itemStartedAt));
      return {
        result: result,
        cached: false
      };
    } catch (e) {
      progress.failed += 1;
      onProgress(progress);
      this.logError('item failed id=' + id + ' elapsedMs=' + this.elapsed(itemStartedAt) + ' error=' + this.errorMessage(e));
      let result: GalleryAnalysisResult = {
        id: id,
        uri: uri,
        thumbnailUri: '',
        title: '分析失败',
        category: '其他',
        summary: this.errorMessage(e),
        details: [],
        tags: [],
        ocrText: '',
        rawModelText: '',
        keywords: [],
        date: date,
        embeddingRef: '',
        embeddingStatus: 'skipped',
        embeddingDimension: 0,
        error: this.errorMessage(e),
        latitude: resultLatitude,
        longitude: resultLongitude,
        exif: exifMetadata,
        location: locationRecord,
        createdAt: new Date().getTime()
      };
      return {
        result: result,
        cached: false
      };
    } finally {
      if (pixelMap) {
        try {
          await pixelMap.release();
        } catch (e) {
        }
      }
      if (imageSource) {
        try {
          await imageSource.release();
        } catch (e) {
        }
      }
      if (imageFile) {
        try {
          await fileIo.close(imageFile);
        } catch (e) {
        }
      }
    }
  }

  private toCloudConfig(config: GalleryAnalyzerConfig): GalleryCloudModelConfig {
    return {
      baseUrl: config.apiBaseUrl,
      apiKey: config.apiKey,
      model: config.model
    };
  }

  private normalizeMergedModelJson(modelJson: GalleryModelJson): GalleryModelJson {
    let normalized: GalleryModelJson = {};
    if (modelJson.title && modelJson.title.trim().length > 0) {
      normalized.title = modelJson.title.trim();
    }
    if (modelJson.category && modelJson.category.trim().length > 0) {
      normalized.category = modelJson.category.trim();
    }
    if (modelJson.summary && modelJson.summary.trim().length > 0) {
      normalized.summary = modelJson.summary.trim();
    }
    normalized.details = this.detailListFrom(modelJson.details);
    normalized.tags = this.tagListFrom(modelJson.tags);
    if (modelJson.importance !== undefined && !isNaN(modelJson.importance)) {
      normalized.importance = modelJson.importance;
    }
    return normalized;
  }

  private modelFieldCount(modelJson: GalleryModelJson): number {
    let count = 0;
    if (modelJson.title && modelJson.title.trim().length > 0) {
      count += 1;
    }
    if (modelJson.category && modelJson.category.trim().length > 0) {
      count += 1;
    }
    if (modelJson.summary && modelJson.summary.trim().length > 0) {
      count += 1;
    }
    if (modelJson.details && modelJson.details.length > 0) {
      count += 1;
    }
    if (modelJson.tags && modelJson.tags.length > 0) {
      count += 1;
    }
    if (modelJson.importance !== undefined && !isNaN(modelJson.importance)) {
      count += 1;
    }
    return count;
  }

  private async ensureResultLocation(result: GalleryAnalysisResult, config: GalleryAnalyzerConfig,
    id: string): Promise<GalleryLocationEnrichResult> {
    if (this.hasResolvedLocation(result.location)) {
      return {
        result: result,
        updated: false
      };
    }
    let location = await this.resolveLocationForCoordinates(result.latitude, result.longitude, config, id);
    if (!location) {
      return {
        result: result,
        updated: false
      };
    }
    result.location = location;
    return {
      result: result,
      updated: true
    };
  }

  private async resolveLocationForCoordinates(latitude: number | undefined, longitude: number | undefined,
    config: GalleryAnalyzerConfig, id: string): Promise<GalleryLocationCacheRecord | undefined> {
    let lat = Number(latitude);
    let lon = Number(longitude);
    if (!GalleryExifUtils.isValidLocation(lat, lon)) {
      return undefined;
    }
    let key = GalleryStorage.locationCacheKey(lat, lon);
    let cached = GalleryStorage.loadLocationCache(this.filesDir)[key];
    if (cached && this.hasResolvedLocation(cached)) {
      this.logInfo('location cache hit id=' + id + ' key=' + key);
      return cached;
    }
    if (this.locationFailedKeys[key]) {
      return undefined;
    }
    let amapKey = config.amapWebKey.trim();
    if (amapKey.length === 0) {
      return undefined;
    }
    if (!this.locationRequests[key]) {
      this.logInfo('location reverse start id=' + id + ' key=' + key);
      this.locationRequests[key] = this.reverseGeocoder.reverse(lat, lon, amapKey)
        .then((record: GalleryLocationCacheRecord) => {
          GalleryStorage.saveLocationCacheRecord(this.filesDir, record);
          this.logInfo('location reverse done id=' + id + ' key=' + key);
          return record;
        })
        .catch((e: Error) => {
          this.locationFailedKeys[key] = true;
          this.logError('location reverse failed id=' + id + ' key=' + key + ' error=' + this.errorMessage(e));
          return undefined;
        });
    } else {
      this.logInfo('location reverse reuse pending id=' + id + ' key=' + key);
    }
    return await this.locationRequests[key];
  }

  private hasResolvedLocation(record?: GalleryLocationCacheRecord): boolean {
    if (!record) {
      return false;
    }
    return record.formattedAddress.length > 0 || record.poiName.length > 0;
  }

  private async readExifMetadata(imageSource: image.ImageSource, id: string): Promise<GalleryExifMetadata | undefined> {
    let metadata: GalleryExifMetadata = {};
    metadata.dateTimeOriginal = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'DateTimeOriginal'));
    metadata.deviceMake = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'Make'));
    metadata.deviceModel = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'Model'));
    metadata.imageWidth = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'ImageWidth'));
    metadata.imageHeight = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'ImageLength'));
    metadata.orientation = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'Orientation'));
    metadata.gpsLatitude = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'GPSLatitude'));
    metadata.gpsLongitude = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'GPSLongitude'));
    metadata.gpsLatitudeRef = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'GPSLatitudeRef'));
    metadata.gpsLongitudeRef = GalleryExifUtils.cleanProperty(await this.readImageProperty(imageSource, 'GPSLongitudeRef'));
    metadata.latitude = GalleryExifUtils.coordinateFromExif(metadata.gpsLatitude, metadata.gpsLatitudeRef);
    metadata.longitude = GalleryExifUtils.coordinateFromExif(metadata.gpsLongitude, metadata.gpsLongitudeRef);

    if (!this.hasExifMetadata(metadata)) {
      this.logInfo('exif empty id=' + id);
      return undefined;
    }
    this.logInfo('exif read id=' + id +
      ' time=' + GalleryExifUtils.displayDateTime(metadata.dateTimeOriginal) +
      ' device=' + GalleryExifUtils.deviceText(metadata) +
      ' location=' + GalleryExifUtils.locationText(metadata.latitude, metadata.longitude) +
      ' rawGps=' + GalleryExifUtils.rawGpsLocationText(metadata));
    return metadata;
  }

  private async readImageProperty(imageSource: image.ImageSource, key: string): Promise<string> {
    try {
      return await imageSource.getImageProperty(key, { index: 0, defaultValue: '' });
    } catch (e) {
      return '';
    }
  }

  private hasExifMetadata(metadata: GalleryExifMetadata): boolean {
    return GalleryExifUtils.cleanProperty(metadata.dateTimeOriginal).length > 0 ||
      GalleryExifUtils.deviceText(metadata).length > 0 ||
      GalleryExifUtils.locationText(metadata.latitude, metadata.longitude).length > 0 ||
      GalleryExifUtils.rawGpsLocationText(metadata).length > 0 ||
      GalleryExifUtils.cleanProperty(metadata.imageWidth).length > 0 ||
      GalleryExifUtils.cleanProperty(metadata.imageHeight).length > 0 ||
      GalleryExifUtils.cleanProperty(metadata.orientation).length > 0;
  }

  private exifPromptText(metadata: GalleryExifMetadata | undefined, latitude: number | undefined, longitude: number | undefined,
    locationRecord?: GalleryLocationCacheRecord): string {
    let lines: string[] = [];
    if (metadata) {
      let capturedAt = GalleryExifUtils.displayDateTime(metadata.dateTimeOriginal);
      if (capturedAt.length > 0) {
        lines.push('拍摄时间：' + capturedAt);
      }
      let device = GalleryExifUtils.deviceText(metadata);
      if (device.length > 0) {
        lines.push('拍摄设备：' + device);
      }
      let size = this.exifSizeText(metadata);
      if (size.length > 0) {
        lines.push('图片尺寸：' + size);
      }
    }
    let location = GalleryExifUtils.directedLocationText(latitude, longitude);
    if (location.length > 0) {
      lines.push('拍摄位置：' + location);
    } else if (metadata) {
      let rawGps = GalleryExifUtils.rawGpsLocationText(metadata);
      if (rawGps.length > 0) {
        lines.push('拍摄位置 GPS 原始值：' + rawGps);
      }
    }
    if (locationRecord && locationRecord.formattedAddress.length > 0) {
      lines.push('地理位置：' + locationRecord.formattedAddress);
    }
    if (locationRecord && locationRecord.poiName.length > 0) {
      lines.push('附近地点：' + locationRecord.poiName);
    }
    return lines.length > 0 ? lines.join('\n') : '(无)';
  }

  private exifSizeText(metadata: GalleryExifMetadata): string {
    let width = GalleryExifUtils.cleanProperty(metadata.imageWidth);
    let height = GalleryExifUtils.cleanProperty(metadata.imageHeight);
    if (width.length > 0 && height.length > 0) {
      return width + ' x ' + height;
    }
    return '';
  }

  private async pixelMapToJpegBase64(pixelMap: image.PixelMap): Promise<string> {
    let packer = image.createImagePacker();
    try {
      let data = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 85
      });
      let helper = new util.Base64Helper();
      return helper.encodeToStringSync(new Uint8Array(data));
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      try {
        await packer.release();
      } catch (e) {
      }
    }
  }

  private parseModelJson(raw: string, id: string): GalleryModelParseResult {
    let rawText = raw.trim();
    let parsed = this.tryParseModelJson(rawText);
    if (parsed) {
      return {
        json: parsed,
        text: rawText
      };
    }
    let text = this.cleanModelJsonText(raw);
    parsed = this.tryParseModelJson(text);
    if (parsed) {
      this.logInfo('model json normalized id=' + id +
        ' rawChars=' + rawText.length.toString() +
        ' normalizedChars=' + text.length.toString());
      return {
        json: parsed,
        text: text
      };
    }
    let candidates = this.modelJsonRepairCandidates(text);
    for (let i = 0; i < candidates.length; i++) {
      let repaired = candidates[i];
      parsed = this.tryParseModelJson(repaired);
      if (parsed) {
        this.logInfo('model json repaired id=' + id +
          ' candidate=' + (i + 1).toString() + '/' + candidates.length.toString() +
          ' originalChars=' + text.length +
          ' repairedChars=' + repaired.length +
          ' originalTail=' + this.debugTail(text) +
          ' repairedTail=' + this.debugTail(repaired));
        return {
          json: parsed,
          text: repaired
        };
      }
    }
    this.logError('model json parse failed id=' + id +
      ' rawChars=' + raw.length +
      ' cleanedChars=' + text.length +
      ' candidates=' + candidates.length.toString() +
      ' cleanedTail=' + this.debugTail(text));
    return {
      json: {
        title: '图库图片',
        category: '其他',
        summary: raw.length > 140 ? raw.substring(0, 140) : raw,
        details: [],
        tags: []
      },
      text: raw
    };
  }

  private cleanModelJsonText(raw: string): string {
    let text = raw.trim();
    if (text.startsWith('```')) {
      let first = text.indexOf('\n');
      let last = text.lastIndexOf('```');
      if (first >= 0 && last > first) {
        text = text.substring(first + 1, last).trim();
      }
    }
    let start = text.indexOf('{');
    let end = text.lastIndexOf('}');
    if (start >= 0) {
      if (end > start) {
        text = text.substring(start, end + 1);
      } else {
        text = text.substring(start);
      }
    }
    return text.trim();
  }

  private tryParseModelJson(text: string): GalleryModelJson | null {
    try {
      return ArkJSON.parse(text) as GalleryModelJson;
    } catch (e) {
      return null;
    }
  }

  private throwIfModelErrorResponse(raw: string): void {
    let text = this.cleanModelJsonText(raw);
    let payload = this.tryParseModelJson(text);
    if (!payload) {
      return;
    }
    let map = payload as Record<string, Object | string | number | boolean | null>;
    let action = map['action'];
    if (typeof action !== 'string' || action.toLowerCase() !== 'error') {
      return;
    }
    let reason = '';
    let rawReason = map['reason'];
    if (typeof rawReason === 'string') {
      reason = rawReason.trim();
    }
    if (reason.length === 0) {
      let rawMessage = map['message'];
      if (typeof rawMessage === 'string') {
        reason = rawMessage.trim();
      }
    }
    throw new Error('调用 AI 分析失败' + (reason.length > 0 ? '：' + reason : ''));
  }

  private modelJsonRepairCandidates(text: string): string[] {
    let candidates: string[] = [];
    let trimmed = text.trim();
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(trimmed));
    let withoutComma = this.removeTrailingJsonComma(trimmed);
    let withoutJsonCommas = this.removeJsonTrailingCommas(trimmed);
    let normalizedKeys = this.normalizeModelJsonKeys(trimmed);
    let cjkPunctuation = this.normalizeCjkJsonPunctuation(trimmed);
    let withoutParentheses = this.removeJsonParentheses(trimmed);
    let cjkPunctuationWithoutParentheses = this.removeJsonParentheses(cjkPunctuation);
    let quotedKnownKeys = this.quoteKnownModelJsonKeys(trimmed);
    let singleQuoted = this.repairSingleQuotedModelJson(trimmed);
    let quotedArrayItems = this.quoteBareModelJsonArrayItems(trimmed);
    this.pushModelJsonCandidate(candidates, withoutComma + ']}');
    this.pushModelJsonCandidate(candidates, withoutComma + '"]}');
    this.pushModelJsonCandidate(candidates, withoutComma + '}');
    this.pushModelJsonCandidate(candidates, withoutJsonCommas);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(withoutJsonCommas));
    this.pushModelJsonCandidate(candidates, normalizedKeys);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(normalizedKeys));
    this.pushModelJsonCandidate(candidates, cjkPunctuation);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(cjkPunctuation));
    this.pushModelJsonCandidate(candidates, this.normalizeModelJsonKeys(cjkPunctuation));
    this.pushModelJsonCandidate(candidates, withoutParentheses);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(withoutParentheses));
    this.pushModelJsonCandidate(candidates, cjkPunctuationWithoutParentheses);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(cjkPunctuationWithoutParentheses));
    this.pushModelJsonCandidate(candidates, quotedKnownKeys);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(quotedKnownKeys));
    this.pushModelJsonCandidate(candidates, singleQuoted);
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(singleQuoted));
    this.pushModelJsonCandidate(candidates, quotedArrayItems);
    this.pushModelJsonCandidate(candidates, this.quoteBareModelJsonArrayItems(cjkPunctuation));
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(withoutComma + ']}'));
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(withoutComma + '"]}'));
    this.pushModelJsonCandidate(candidates, this.repairModelJsonText(withoutComma + '}'));
    return candidates;
  }

  private pushModelJsonCandidate(candidates: string[], text: string): void {
    this.pushUnique(candidates, text);
    let escaped = this.escapeJsonStringControlChars(text);
    if (escaped !== text) {
      this.pushUnique(candidates, escaped);
    }
  }

  private escapeJsonStringControlChars(text: string): string {
    let result = '';
    let inString = false;
    let escaped = false;
    for (let i = 0; i < text.length; i++) {
      let ch = text.charAt(i);
      if (inString) {
        if (escaped) {
          result += ch;
          escaped = false;
          continue;
        }
        if (ch === '\\') {
          result += ch;
          escaped = true;
          continue;
        }
        if (ch === '"') {
          result += ch;
          inString = false;
          continue;
        }
        if (ch === '\n' || ch === '\r' || ch === '\t') {
          result += ' ';
          continue;
        }
        result += ch;
        continue;
      }
      result += ch;
      if (ch === '"') {
        inString = true;
      }
    }
    return result;
  }

  private repairModelJsonText(text: string): string {
    let trimmed = text.trim();
    if (trimmed.length === 0 || trimmed.indexOf('{') < 0) {
      return trimmed;
    }
    let stack: string[] = [];
    let inString = false;
    let escaped = false;
    for (let i = 0; i < trimmed.length; i++) {
      let ch = trimmed.charAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
        continue;
      }
      if (ch === '{' || ch === '[') {
        stack.push(ch);
        continue;
      }
      if (ch === '}' || ch === ']') {
        if (stack.length > 0 && this.matchingJsonClose(stack[stack.length - 1]) === ch) {
          stack.pop();
        }
      }
    }
    let repaired = trimmed;
    if (inString) {
      repaired += '"';
    }
    while (stack.length > 0) {
      repaired = this.removeTrailingJsonComma(repaired);
      let open = stack[stack.length - 1];
      stack.splice(stack.length - 1, 1);
      if (open === '[') {
        repaired += ']';
      } else {
        repaired += '}';
      }
    }
    return repaired;
  }

  private matchingJsonClose(open: string): string {
    return open === '[' ? ']' : '}';
  }

  private removeTrailingJsonComma(text: string): string {
    let end = text.length - 1;
    while (end >= 0) {
      let ch = text.charAt(end);
      if (ch !== ' ' && ch !== '\n' && ch !== '\r' && ch !== '\t') {
        break;
      }
      end -= 1;
    }
    if (end >= 0 && text.charAt(end) === ',') {
      return text.substring(0, end) + text.substring(end + 1);
    }
    return text;
  }

  private removeJsonTrailingCommas(text: string): string {
    let result = '';
    let inString = false;
    let escaped = false;
    for (let i = 0; i < text.length; i++) {
      let ch = text.charAt(i);
      if (inString) {
        result += ch;
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
        result += ch;
        continue;
      }
      if (ch === ',') {
        let next = i + 1;
        while (next < text.length) {
          let nextChar = text.charAt(next);
          if (nextChar !== ' ' && nextChar !== '\n' && nextChar !== '\r' && nextChar !== '\t') {
            break;
          }
          next++;
        }
        if (next < text.length && (text.charAt(next) === '}' || text.charAt(next) === ']')) {
          continue;
        }
      }
      result += ch;
    }
    return result;
  }

  private normalizeModelJsonKeys(text: string): string {
    return text
      .replace(/"importance\s*:\s*([0-9.]+)/g, '"importance":$1')
      .replace(/"title\s*:/g, '"title":')
      .replace(/"category\s*:/g, '"category":')
      .replace(/"summary\s*:/g, '"summary":')
      .replace(/"details\s*:/g, '"details":')
      .replace(/"tags\s*:/g, '"tags":');
  }

  private normalizeCjkJsonPunctuation(text: string): string {
    return text.replace(/[“”]/g, '"')
      .replace(/[‘’]/g, "'")
      .replace(/，/g, ',')
      .replace(/：/g, ':');
  }

  private removeJsonParentheses(text: string): string {
    return text.replace(/[()（）]/g, '');
  }

  private quoteKnownModelJsonKeys(text: string): string {
    return text.replace(/([{,]\s*)(title|category|summary|details|tags|importance)\s*:/g, '$1"$2":');
  }

  private repairSingleQuotedModelJson(text: string): string {
    return text.replace(/'([^'\\]*(?:\\.[^'\\]*)*)'/g, '"$1"');
  }

  private quoteBareModelJsonArrayItems(text: string): string {
    return text.replace(/\[([^\[\]{}"]*)\]/g, (match: string, body: string): string => {
      if (body.indexOf(':') >= 0) {
        return match;
      }
      let parts = body.split(/[,，、;；]/);
      let quoted: string[] = [];
      for (let i = 0; i < parts.length; i++) {
        let value = parts[i].trim();
        if (value.length === 0) {
          continue;
        }
        if (value === 'true' || value === 'false' || value === 'null' || !isNaN(Number(value))) {
          quoted.push(value);
        } else {
          quoted.push('"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"');
        }
      }
      return '[' + quoted.join(',') + ']';
    });
  }

  private debugTail(text: string): string {
    let normalized = text.replace(/[\r\n\t]+/g, ' ');
    if (normalized.length <= 240) {
      return normalized;
    }
    return normalized.substring(normalized.length - 240);
  }

  private resultText(modelJson: GalleryModelJson, ocrText: string): string {
    let parts: string[] = [];
    if (modelJson.title && modelJson.title.length > 0) {
      parts.push(modelJson.title);
    }
    if (modelJson.category && modelJson.category.length > 0) {
      parts.push(modelJson.category);
    }
    if (modelJson.summary && modelJson.summary.length > 0) {
      parts.push(modelJson.summary);
    }
    let details = this.detailListFrom(modelJson.details);
    for (let i = 0; i < details.length; i++) {
      parts.push(details[i]);
    }
    if (ocrText.length > 0) {
      parts.push(ocrText);
    }
    return parts.join('\n');
  }

  private resolveImageDate(uri: string, fallbackTs: number): string {
    if (uri.length === 0) {
      return GalleryStorage.formatDate(fallbackTs);
    }
    return GalleryStorage.formatDate(fallbackTs);
  }

  private keywordsFrom(tags: string[], ocrText: string): string[] {
    let result: string[] = [];
    for (let i = 0; i < tags.length; i++) {
      this.pushUnique(result, tags[i]);
    }
    let keywordMatch = GalleryKeywordFilter.matchUsefulKeywords(ocrText);
    for (let k = 0; k < keywordMatch.keywords.length && result.length < 12; k++) {
      this.pushUnique(result, keywordMatch.keywords[k]);
    }
    return result;
  }

  private pushUnique(items: string[], value: string): void {
    let normalized = value.trim();
    if (normalized.length === 0) {
      return;
    }
    for (let i = 0; i < items.length; i++) {
      if (items[i] === normalized) {
        return;
      }
    }
    items.push(normalized);
  }

  private stableId(uri: string): string {
    let hash = 0;
    for (let i = 0; i < uri.length; i++) {
      hash = ((hash << 5) - hash) + uri.charCodeAt(i);
      hash = hash & hash;
    }
    return 'gallery_' + Math.abs(hash).toString();
  }

  private nonEmpty(value: string | undefined, fallback: string): string {
    if (value && value.trim().length > 0) {
      return value.trim();
    }
    return fallback;
  }

  private detailListFrom(details: string[] | undefined): string[] {
    let result: string[] = [];
    if (!details) {
      return result;
    }
    for (let i = 0; i < details.length && result.length < 8; i++) {
      let value = String(details[i]).replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
      if (value.length > 0) {
        result.push(value);
      }
    }
    return result;
  }

  private tagListFrom(tags: string[] | undefined): string[] {
    let result: string[] = [];
    if (!tags) {
      return result;
    }
    for (let i = 0; i < tags.length && result.length < 8; i++) {
      let value = String(tags[i]).replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
      if (value.length > 0) {
        this.pushUnique(result, value);
      }
    }
    return result;
  }

  private isSuccessfulCachedResult(result: GalleryAnalysisResult): boolean {
    return !result.error || result.error.trim().length === 0;
  }

  private normalizeImageScale(scale: number): number {
    if (isNaN(scale)) {
      return 0.25;
    }
    if (scale < 0.1) {
      return 0.1;
    }
    if (scale > 1) {
      return 1;
    }
    return scale;
  }

  private async scaleForAnalysis(pixelMap: image.PixelMap, scale: number, id: string): Promise<void> {
    let normalizedScale = this.normalizeImageScale(scale);
    if (normalizedScale >= 1) {
      this.logInfo('image scale skipped id=' + id + ' scale=' + normalizedScale);
      return;
    }
    let scaleStartedAt = new Date().getTime();
    this.logInfo('image scale start id=' + id + ' scale=' + normalizedScale);
    await pixelMap.scale(normalizedScale, normalizedScale);
    this.logInfo('image scale done id=' + id + ' elapsedMs=' + this.elapsed(scaleStartedAt));
  }

  private errorMessage(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  private elapsed(startedAt: number): number {
    return new Date().getTime() - startedAt;
  }

  private previewForLog(text: string, maxLength: number): string {
    let normalized = text.replace(/\r/g, '\\r').replace(/\n/g, '\\n');
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return normalized.substring(0, maxLength) + '...';
  }

  private logInfo(message: string): void {
    AppLogger.info('Gallery.Analyzer', message);
    this.captureLog('INFO', message);
  }

  private logError(message: string): void {
    AppLogger.error('Gallery.Analyzer', message);
    this.captureLog('ERROR', message);
  }

  private logEmbeddingMessage(level: string, id: string, message: string): void {
    let text = 'embedding id=' + id + ' ' + message;
    if (level === 'ERROR') {
      this.logError(text);
      return;
    }
    this.logInfo(text);
  }

  private captureLog(level: string, message: string): void {
    if (!DebugSettings.isEnabled()) { return; }
    let previous = AppStorage.get(GALLERY_LOG_STORAGE_KEY) as string;
    let current = previous && previous.length > 0 ? previous : '';
    let line = '[' + new Date().toLocaleTimeString() + '] [' + level + '] ' + message;
    let next = current.length > 0 ? current + '\n' + line : line;
    if (next.length > GALLERY_LOG_MAX_CHARS) {
      next = next.substring(next.length - GALLERY_LOG_MAX_CHARS);
    }
    AppStorage.setOrCreate(GALLERY_LOG_STORAGE_KEY, next);
  }
}
