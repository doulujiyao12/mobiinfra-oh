import { promptAction, router } from '@kit.ArkUI';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CloudModelClient,
  GalleryCloudModelConfig,
  GalleryMonthSummaryResult,
  GalleryQuestionAnswerResult
} from '../../utils/CloudModelClient';
import { GalleryAnalyzer } from '../../utils/gallery/GalleryAnalyzer';
import { GalleryAutoScanner } from '../../utils/gallery/GalleryAutoScanner';
import { GalleryExifUtils } from '../../utils/gallery/GalleryExifUtils';
import {
  GalleryMonthlyCategoryCount,
  GalleryMonthlyInsight,
  GalleryMonthlyInsights
} from '../../utils/gallery/GalleryMonthlyInsights';
import { GalleryPhotoPicker } from '../../utils/gallery/GalleryPhotoPicker';
import { GalleryReverseGeocoder } from '../../utils/gallery/GalleryReverseGeocoder';
import { configuredEndpointSecretOrDefault } from '../../config/DefaultEndpointConfig';
import {
  DEFAULT_GALLERY_AMAP_WEB_KEY,
  DEFAULT_GALLERY_API_BASE_URL,
  DEFAULT_GALLERY_API_KEY,
  DEFAULT_GALLERY_EMBEDDING_API_KEY,
  DEFAULT_GALLERY_EMBEDDING_BASE_URL,
  DEFAULT_GALLERY_EMBEDDING_CONCURRENCY,
  DEFAULT_GALLERY_EMBEDDING_MODE,
  DEFAULT_GALLERY_EMBEDDING_MODEL,
  DEFAULT_GALLERY_IMAGE_SCALE,
  DEFAULT_GALLERY_MODEL,
  DEFAULT_GALLERY_MODEL_CONCURRENCY,
  DEFAULT_GALLERY_OCR_CONCURRENCY,
  DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS,
  DEFAULT_GALLERY_SKIP_OCR,
  DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER,
  GALLERY_AMAP_WEB_KEY_DEFAULT_SNAPSHOT,
  GALLERY_EMBEDDING_API_KEY_DEFAULT_SNAPSHOT,
  registerGallerySettingsDefaults
} from '../../utils/gallery/GallerySettingsDefaults';
import {
  hiddenDefaultSettingEditorValue,
  hiddenDefaultSettingPlaceholder,
  migrateDefaultSettingValue
} from '../../utils/DefaultSettingVisibility';
import { SensitiveSettingInput } from '../settings/SettingsCenterControls';
import { GalleryStorage } from '../../utils/gallery/GalleryStorage';
import { AppLogger } from '../../utils/AppLogger';
import { showToastSafely } from '../../utils/PromptSafe';
import {
  GalleryAnalysisResult,
  GalleryAnalyzeOutcome,
  GalleryAnalyzerConfig,
  GalleryLocationCacheRecord,
  GalleryMonthSummaryCacheRecord,
  GalleryPhotoInput,
  GalleryProgress,
  GalleryScanItem,
  GalleryScanSession
} from '../../utils/gallery/GalleryTypes';
import { GallerySearchHit, GallerySearchService } from '../../utils/gallery/GallerySearchService';
const GALLERY_RESULT_PAGE_SIZE = 10;

interface GalleryCoordinate {
  latitude?: number;
  longitude?: number;
}

// 结果区分类筛选项，count 来自当前时间范围内的可见结果统计。
interface GalleryCategoryFilter {
  index: number;
  label: string;
  count: number;
}

registerGallerySettingsDefaults();

@Entry
@Component
struct GalleryPage {
  @State analyzing: boolean = false;
  @State progress: number = 0;
  @State selectedFilter: number = 0;
  @State selectedTimeFilter: number = 0;
  @State resultDisplayLimit: number = GALLERY_RESULT_PAGE_SIZE;
  @State lastRunText: string = '尚未开始';
  @State settingsOpen: boolean = false;
  @State activeSensitiveInputId: string = '';
  @State manualAnalyzing: boolean = false;
  // 扫描进度展示使用这些运行态字段；它们可能先于 scan-session 落盘状态更新。
  @State autoScanStatus: string = 'idle';
  @State scanTotal: number = 0;
  @State scanProcessed: number = 0;
  @State scanPending: number = 0;
  @State scanSkipped: number = 0;
  @State scanFailed: number = 0;
  @State scanRevision: number = 0;
  @State progressRevision: number = 0;
  @State results: GalleryAnalysisResult[] = [];
  @State resultRevision: number = 0;
  @State selectedMonthKey: string = '';
  // 月度 AI 总结会持久化到 GalleryStorage，页面状态只缓存当前有效 signature 的记录。
  @State monthlyAiSummaries: Record<string, GalleryMonthSummaryCacheRecord> = {};
  @State monthlyAiLoadingKey: string = '';
  @State monthlyAiErrorKey: string = '';
  @State monthlyAiErrorText: string = '';
  @State selectedDetailId: string = '';
  @State settingsRevision: number = 0;
  @State galleryQuestion: string = '';
  @State gallerySearchHits: GallerySearchHit[] = [];
  @State gallerySearchRevision: number = 0;
  @State gallerySearchMessage: string = '输入问题后检索图库记录';
  @State galleryAnswerText: string = '';
  @State galleryAnswerMeta: string = '';
  @State galleryAnswerLoading: boolean = false;
  @State galleryAnswerError: string = '';
  @State skippedPanelOpen: boolean = false;
  @State skippedPanelItems: GalleryScanItem[] = [];
  @State skippedPanelRevision: number = 0;
  @State locationCacheRecords: Record<string, GalleryLocationCacheRecord> = {};
  @State locationResolvingKey: string = '';
  @State locationResolveErrorKey: string = '';
  @State locationResolveErrorText: string = '';
  @State locationResolveRevision: number = 0;
  @StorageLink('galleryApiBaseUrl') galleryApiBaseUrl: string = DEFAULT_GALLERY_API_BASE_URL;
  @StorageLink('galleryApiKey') galleryApiKey: string = DEFAULT_GALLERY_API_KEY;
  @StorageLink('galleryModel') galleryModel: string = DEFAULT_GALLERY_MODEL;
  @StorageLink('gallerySkipOcr') gallerySkipOcr: string = DEFAULT_GALLERY_SKIP_OCR;
  @StorageLink('galleryUseOcrKeywordFilter') galleryUseOcrKeywordFilter: string = DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER;
  @StorageLink('galleryOcrConcurrency') galleryOcrConcurrency: string = DEFAULT_GALLERY_OCR_CONCURRENCY;
  @StorageLink('galleryModelConcurrency') galleryModelConcurrency: string = DEFAULT_GALLERY_MODEL_CONCURRENCY;
  @StorageLink('galleryEmbeddingConcurrency') galleryEmbeddingConcurrency: string = DEFAULT_GALLERY_EMBEDDING_CONCURRENCY;
  @StorageLink('galleryParallelFieldRequests') galleryParallelFieldRequests: string = DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS;
  @StorageLink('galleryEmbeddingMode') galleryEmbeddingMode: string = DEFAULT_GALLERY_EMBEDDING_MODE;
  @StorageLink('galleryEmbeddingBaseUrl') galleryEmbeddingBaseUrl: string = DEFAULT_GALLERY_EMBEDDING_BASE_URL;
  @StorageLink('galleryEmbeddingApiKey') galleryEmbeddingApiKey: string = DEFAULT_GALLERY_EMBEDDING_API_KEY;
  @StorageLink('galleryEmbeddingModel') galleryEmbeddingModel: string = DEFAULT_GALLERY_EMBEDDING_MODEL;
  @StorageLink('galleryImageScale') galleryImageScale: string = DEFAULT_GALLERY_IMAGE_SCALE;
  @StorageLink('galleryAmapWebKey') galleryAmapWebKey: string = DEFAULT_GALLERY_AMAP_WEB_KEY;

  private filesDir: string = '';
  private cloudClient: CloudModelClient = new CloudModelClient();
  private reverseGeocoder: GalleryReverseGeocoder = new GalleryReverseGeocoder();
  private pauseRequested: boolean = false;
  private lastRunAt: number = 0;
  private lastRunTimerId: number = -1;
  // 恢复暂停任务时，分析器只上报本次 pendingInputs 的增量，需要叠加 baseline 才是全库进度。
  private autoProgressBaselineProcessed: number = 0;
  private autoProgressBaselineSkipped: number = 0;
  private autoProgressBaselineFailed: number = 0;

  aboutToAppear(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    this.migrateGalleryDefaultValues();
    this.ensureDefaultSettings();
    this.locationCacheRecords = GalleryStorage.loadLocationCache(this.filesDir);
    this.replaceResults(GalleryStorage.loadResults(this.filesDir));
    this.restoreLastRunFromResults();
    this.restoreScanSessionState();
    this.restoreMonthlyAiSummaries();
    this.startLastRunTimer();
  }

  aboutToDisappear(): void {
    this.stopLastRunTimer();
  }

  private ensureDefaultSettings(): void {
    this.galleryApiKey = configuredEndpointSecretOrDefault(this.galleryApiKey, DEFAULT_GALLERY_API_KEY);
    if (this.galleryModel.trim().length === 0) {
      this.galleryModel = DEFAULT_GALLERY_MODEL;
    }
    if (this.galleryApiBaseUrl.trim().length === 0) {
      this.galleryApiBaseUrl = DEFAULT_GALLERY_API_BASE_URL;
    }
    if (this.galleryEmbeddingMode.trim().length === 0) {
      this.galleryEmbeddingMode = DEFAULT_GALLERY_EMBEDDING_MODE;
    }
    this.galleryEmbeddingApiKey = configuredEndpointSecretOrDefault(this.galleryEmbeddingApiKey,
      DEFAULT_GALLERY_EMBEDDING_API_KEY);
    if (this.galleryUseOcrKeywordFilter.trim().length === 0) {
      this.galleryUseOcrKeywordFilter = DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER;
    }
    if (this.galleryParallelFieldRequests.trim().length === 0) {
      this.galleryParallelFieldRequests = DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS;
    }
    this.galleryAmapWebKey = configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY);
    this.galleryImageScale = this.normalizeScale(this.galleryImageScale, DEFAULT_GALLERY_IMAGE_SCALE);
  }

  private migrateGalleryDefaultValues(): void {
    this.galleryEmbeddingApiKey = this.migrateGalleryDefaultValue(this.galleryEmbeddingApiKey,
      DEFAULT_GALLERY_EMBEDDING_API_KEY, [''], GALLERY_EMBEDDING_API_KEY_DEFAULT_SNAPSHOT);
    this.galleryAmapWebKey = this.migrateGalleryDefaultValue(this.galleryAmapWebKey,
      DEFAULT_GALLERY_AMAP_WEB_KEY, [''], GALLERY_AMAP_WEB_KEY_DEFAULT_SNAPSHOT);
  }

  private migrateGalleryDefaultValue(currentValue: string, configuredDefault: string, legacyDefaults: string[],
    snapshotKey: string): string {
    let storedSnapshot = AppStorage.get(snapshotKey) as string;
    let lastAppliedDefault = storedSnapshot === undefined ? '' : storedSnapshot;
    let nextValue = migrateDefaultSettingValue(currentValue, configuredDefault, legacyDefaults, lastAppliedDefault);
    AppStorage.setOrCreate(snapshotKey, configuredDefault);
    return nextValue;
  }

  private visibleCount(): string {
    return this.visibleResults().length.toString() + ' 张';
  }

  private runGalleryKeywordSearch(): void {
    let query = this.galleryQuestion.trim();
    if (query.length === 0) {
      this.gallerySearchHits = [];
      this.gallerySearchMessage = '输入问题后检索图库记录';
      this.galleryAnswerText = '';
      this.galleryAnswerMeta = '';
      this.galleryAnswerError = '';
      this.gallerySearchRevision += 1;
      showToastSafely('请输入要检索的问题', 1200);
      return;
    }
    let hits = GallerySearchService.search(query, this.results, 20);
    this.gallerySearchHits = hits;
    this.gallerySearchMessage = hits.length > 0 ? '找到 ' + hits.length.toString() + ' 条相关图片' : '没有找到明确相关图片';
    this.gallerySearchRevision += 1;
  }

  private async runGalleryQuestionAnswer(): Promise<void> {
    let query = this.galleryQuestion.trim();
    if (query.length === 0) {
      showToastSafely('请输入要问的问题', 1200);
      return;
    }
    this.runGalleryKeywordSearch();
    if (this.gallerySearchHits.length === 0) {
      this.galleryAnswerText = '没有找到明确相关图片。';
      this.galleryAnswerMeta = '';
      this.galleryAnswerError = '';
      this.gallerySearchRevision += 1;
      return;
    }
    this.galleryAnswerLoading = true;
    this.galleryAnswerError = '';
    this.galleryAnswerText = '';
    this.galleryAnswerMeta = '';
    this.gallerySearchRevision += 1;
    try {
      let answer = await this.cloudClient.answerGalleryQuestion(this.galleryCloudModelConfig(), query,
        this.galleryAnswerCandidateText(this.gallerySearchHits));
      this.galleryAnswerText = answer.answer;
      this.galleryAnswerMeta = this.galleryAnswerMetaText(answer);
    } catch (e) {
      this.galleryAnswerError = this.errorMessage(e);
      showToastSafely('图库问答失败：' + this.errorMessage(e), 1800);
    } finally {
      this.galleryAnswerLoading = false;
      this.gallerySearchRevision += 1;
    }
  }

  private clearGalleryQuestion(): void {
    this.galleryQuestion = '';
    this.gallerySearchHits = [];
    this.gallerySearchMessage = '输入问题后检索图库记录';
    this.galleryAnswerText = '';
    this.galleryAnswerMeta = '';
    this.galleryAnswerError = '';
    this.galleryAnswerLoading = false;
    this.gallerySearchRevision += 1;
  }

  private galleryAnswerCandidateText(hits: GallerySearchHit[]): string {
    let limit = Math.min(10, hits.length);
    let lines: string[] = [];
    for (let i = 0; i < limit; i++) {
      let item = hits[i].item;
      lines.push((i + 1).toString() + '. id=' + item.id);
      lines.push('日期：' + this.groupDate(item));
      lines.push('类别：' + this.categoryLabel(item.category));
      lines.push('标签：' + (item.tags && item.tags.length > 0 ? item.tags.join('、') : '无'));
      lines.push('标题：' + item.title);
      lines.push('摘要：' + item.summary);
      if (item.details && item.details.length > 0) {
        lines.push('细节：' + item.details.join('；'));
      }
      if (item.ocrText && item.ocrText.length > 0) {
        lines.push('OCR：' + this.compactText(item.ocrText, 240));
      }
      lines.push('命中原因：' + hits[i].reason);
      lines.push('');
    }
    return lines.join('\n');
  }

  private galleryAnswerMetaText(answer: GalleryQuestionAnswerResult): string {
    let parts: string[] = [];
    if (answer.matchedIds.length > 0) {
      parts.push('引用 ' + answer.matchedIds.length.toString() + ' 张');
    }
    if (answer.confidence > 0) {
      parts.push('置信度 ' + answer.confidence.toFixed(2));
    }
    return parts.join(' · ');
  }

  private compactText(value: string, maxLength: number): string {
    let text = value ? String(value).replace(/\s+/g, ' ').trim() : '';
    if (text.length <= maxLength) {
      return text;
    }
    return text.substring(0, maxLength) + '...';
  }

  private async startManualAnalyze(): Promise<void> {
    if (this.analyzing) {
      showToastSafely('图库分析正在进行', 1200);
      return;
    }
    try {
      let picker = new GalleryPhotoPicker();
      let uris = await picker.selectImageUris(9);
      if (uris.length === 0) {
        showToastSafely('未选择图片', 1200);
        return;
      }
      let ctx = getContext(this) as common.UIAbilityContext;
      let locationGranted = await this.ensureMediaLocationPermission(ctx);
      if (!locationGranted) {
        showToastSafely('未获得媒体位置权限，将跳过拍摄位置读取', 1600);
      }
      this.analyzing = true;
      this.manualAnalyzing = true;
      this.progress = 0;
      this.scanTotal = uris.length;
      this.scanProcessed = 0;
      this.scanPending = uris.length;
      this.scanSkipped = 0;
      this.scanFailed = 0;
      this.progressRevision += 1;
      this.selectedFilter = 0;
      this.selectedTimeFilter = 0;
      this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
      this.clearMonthlyAiRuntimeState();
      this.setLastRunLabel('分析中');
      let analyzer = new GalleryAnalyzer(this.filesDir, this.cloudClient);
      let finalResults = await analyzer.analyzeUris(uris, this.buildAnalyzerConfig(false), (next: GalleryProgress) => {
        this.updateProgress(next);
      }, (result: GalleryAnalysisResult) => {
        this.mergeResult(result);
      });
      let storedResults = GalleryStorage.loadResults(this.filesDir);
      if (storedResults.length > 0) {
        this.replaceResults(storedResults);
      } else if (finalResults.length > 0) {
        this.replaceResults(finalResults);
      }
      this.analyzing = false;
      this.manualAnalyzing = false;
      this.progress = 100;
      this.scanProcessed = uris.length;
      this.scanPending = 0;
      this.clearManualProgressState();
      this.progressRevision += 1;
      this.refreshAnalyzeStats();
      this.setLastRun(new Date().getTime());
      if (this.scanFailed > 0) {
        showToastSafely('调用 AI 分析失败：' + this.scanFailed.toString() + ' 张，请查看失败详情或日志', 2200);
      } else {
        showToastSafely('图库分析完成', 1500);
      }
    } catch (e) {
      this.analyzing = false;
      this.manualAnalyzing = false;
      this.clearManualProgressState();
      this.setLastRunLabel('分析失败');
      showToastSafely('图库分析失败：' + this.errorMessage(e), 2000);
    }
  }

  private async startAutoAnalyze(): Promise<void> {
    if (this.analyzing) {
      showToastSafely('图库分析正在进行', 1200);
      return;
    }
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let granted = await this.ensureGalleryReadPermission(ctx);
      if (!granted) {
        showToastSafely('未获得图库读取权限', 1600);
        return;
      }
      let scanner = new GalleryAutoScanner();
      let inputs = await scanner.scanAllImages(ctx);
      if (inputs.length === 0) {
        showToastSafely('未扫描到图库图片', 1200);
        return;
      }
      // 每次全量扫描先创建新的会话快照；后续暂停/恢复都从该快照继续。
      let session = this.createScanSession(inputs);
      this.clearMonthlyAiRuntimeState();
      GalleryStorage.saveScanSession(this.filesDir, session);
      await this.runScanSession(session);
    } catch (e) {
      this.analyzing = false;
      this.autoScanStatus = 'failed';
      this.setLastRunLabel('分析失败');
      showToastSafely('自动分析失败：' + this.errorMessage(e), 2000);
    }
  }

  private async continueAutoAnalyze(): Promise<void> {
    if (this.analyzing) {
      showToastSafely('图库分析正在进行', 1200);
      return;
    }
    let session = GalleryStorage.loadScanSession(this.filesDir);
    if (!session) {
      showToastSafely('没有可继续的扫描任务', 1200);
      return;
    }
    try {
      await this.runScanSession(session);
    } catch (e) {
      this.analyzing = false;
      this.autoScanStatus = 'failed';
      this.setLastRunLabel('分析失败');
      showToastSafely('继续分析失败：' + this.errorMessage(e), 2000);
    }
  }

  private requestPauseAutoAnalyze(): void {
    if (!this.analyzing) {
      return;
    }
    if (this.pauseRequested || this.autoScanStatus === 'pausing') {
      showToastSafely('正在暂停，已开始处理的图片完成后会停止', 1600);
      return;
    }
    // 并发分析无法立刻终止已进入流水线的图片，因此先进入 pausing 状态并给用户明确反馈。
    this.pauseRequested = true;
    this.autoScanStatus = 'pausing';
    this.setLastRunLabel('暂停中');
    this.scanRevision += 1;
    this.progressRevision += 1;
    let session = GalleryStorage.loadScanSession(this.filesDir);
    if (session) {
      session.status = 'pausing';
      GalleryStorage.saveScanSession(this.filesDir, session);
    }
    showToastSafely('正在暂停，已开始处理的图片完成后会停止', 1800);
  }

  private async runScanSession(session: GalleryScanSession): Promise<void> {
    let pendingInputs = this.pendingInputs(session);
    if (pendingInputs.length === 0) {
      session.status = 'completed';
      GalleryStorage.saveScanSession(this.filesDir, session);
      this.applyScanSession(session);
      this.progress = 100;
      this.setLastRun(new Date().getTime());
      return;
    }
    this.pauseRequested = false;
    this.analyzing = true;
    this.autoScanStatus = 'running';
    this.progress = this.progressPercentFromUnits(session.processed, session.total);
    this.selectedFilter = 0;
    this.selectedTimeFilter = 0;
    this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
    this.setLastRunLabel('分析中');
    session.status = 'running';
    GalleryStorage.saveScanSession(this.filesDir, session);
    this.applyScanSession(session);
    // 保存恢复前的累计值；分析器回调中的 processed/skipped/failed 只代表本轮 pending 增量。
    this.autoProgressBaselineProcessed = session.processed;
    this.autoProgressBaselineSkipped = session.skipped;
    this.autoProgressBaselineFailed = session.failed;

    let analyzer = new GalleryAnalyzer(this.filesDir, this.cloudClient);
    let finalResults = await analyzer.analyzeInputs(pendingInputs, this.buildAnalyzerConfig(true), (next: GalleryProgress) => {
      this.updateAutoProgress(session, next);
    }, (result: GalleryAnalysisResult) => {
      this.mergeResult(result);
    }, {
      shouldPause: (): boolean => this.pauseRequested,
      onItemDone: (input: GalleryPhotoInput, outcome: GalleryAnalyzeOutcome) => {
        // 单项完成后立即更新并保存会话，确保暂停或退出后可以从最后完成项继续。
        let marked = this.markScanItem(session, input, outcome.cached, outcome.result.error, outcome.skippedByKeyword === true);
        if (this.pauseRequested && session.status === 'running') {
          session.status = 'pausing';
        }
        GalleryStorage.saveScanSession(this.filesDir, session);
        if (marked) {
          this.applyScanSession(session);
        }
      }
    });
    let storedResults = GalleryStorage.loadResults(this.filesDir);
    if (storedResults.length > 0) {
      this.replaceResults(storedResults);
    } else if (finalResults.length > 0) {
      this.replaceResults(finalResults);
    }

    this.analyzing = false;
    if (this.pauseRequested) {
      session.status = 'paused';
      GalleryStorage.saveScanSession(this.filesDir, session);
      this.autoScanStatus = 'paused';
      this.applyScanSession(session);
      this.setLastRunLabel('已暂停');
      showToastSafely('自动分析已暂停', 1200);
      return;
    }
    this.recountScanSession(session);
    let sessionCompleted = session.processed >= session.total;
    session.status = sessionCompleted ? 'completed' : 'paused';
    GalleryStorage.saveScanSession(this.filesDir, session);
    this.applyScanSession(session);
    this.progress = session.total === 0 ? 100 : this.progressPercentFromUnits(session.processed, session.total);
    if (sessionCompleted) {
      this.setLastRun(new Date().getTime());
    } else {
      this.setLastRunLabel('已暂停');
    }
    if (session.failed > 0) {
      showToastSafely('调用 AI 分析失败：' + session.failed.toString() + ' 张，请查看失败详情或日志', 2200);
    } else {
      showToastSafely(sessionCompleted ? '自动分析完成' : '自动分析已暂停', 1500);
    }
  }

  private async ensureGalleryReadPermission(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      let permissions: Permissions[] = ['ohos.permission.READ_IMAGEVIDEO', 'ohos.permission.MEDIA_LOCATION'];
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(ctx, permissions);
      if (!result.authResults || result.authResults.length === 0) {
        return false;
      }
      return result.authResults[0] === 0;
    } catch (e) {
      return false;
    }
  }

  private async ensureMediaLocationPermission(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      let permissions: Permissions[] = ['ohos.permission.MEDIA_LOCATION'];
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(ctx, permissions);
      if (!result.authResults || result.authResults.length === 0) {
        return false;
      }
      return result.authResults[0] === 0;
    } catch (e) {
      return false;
    }
  }

  private mergeResult(result: GalleryAnalysisResult): void {
    let nextResults: GalleryAnalysisResult[] = [];
    let inserted = false;
    for (let i = 0; i < this.results.length; i++) {
      if (this.results[i].id === result.id) {
        nextResults.push(result);
        inserted = true;
      } else {
        nextResults.push(this.results[i]);
      }
    }
    if (!inserted) {
      nextResults.push(result);
    }
    this.sortResultsByRecent(nextResults);
    this.replaceResults(nextResults);
  }

  private replaceResults(nextResults: GalleryAnalysisResult[]): void {
    this.sortResultsByRecent(nextResults);
    this.results = nextResults;
    this.resultRevision += 1;
    this.ensureSelectedFilterAvailable();
    this.ensureSelectedMonth();
    // 结果变化后重新筛选月度总结缓存，只保留 signature 与当前结果一致的记录。
    this.restoreMonthlyAiSummaries();
  }

  private refreshAnalyzeStats(): void {
    this.replaceResults(GalleryStorage.loadResults(this.filesDir));
    this.restoreLastRunFromResults();
    this.scanRevision += 1;
  }

  private monthlyInsights(): GalleryMonthlyInsight[] {
    return GalleryMonthlyInsights.build(this.results);
  }

  private ensureSelectedMonth(): void {
    let insights = this.monthlyInsights();
    if (insights.length === 0) {
      this.selectedMonthKey = '';
      return;
    }
    for (let i = 0; i < insights.length; i++) {
      if (insights[i].key === this.selectedMonthKey) {
        return;
      }
    }
    this.selectedMonthKey = insights[0].key;
  }

  private selectedMonthlyInsight(): GalleryMonthlyInsight | null {
    let insights = this.monthlyInsights();
    if (insights.length === 0) {
      return null;
    }
    for (let i = 0; i < insights.length; i++) {
      if (insights[i].key === this.selectedMonthKey) {
        return insights[i];
      }
    }
    return insights[0];
  }

  private selectedMonthlyInsightList(): GalleryMonthlyInsight[] {
    let insight = this.selectedMonthlyInsight();
    if (insight === null) {
      return [];
    }
    return [insight];
  }

  private monthlyAiSummary(insight: GalleryMonthlyInsight): GalleryMonthSummaryCacheRecord | undefined {
    return this.monthlyAiSummaries[insight.key];
  }

  private monthlyTitle(insight: GalleryMonthlyInsight): string {
    let summary = this.monthlyAiSummary(insight);
    if (summary && summary.title && summary.title.length > 0) {
      return summary.title;
    }
    return insight.label;
  }

  private monthlySummaryText(insight: GalleryMonthlyInsight): string {
    let summary = this.monthlyAiSummary(insight);
    if (summary && summary.summary && summary.summary.length > 0) {
      return summary.summary;
    }
    return insight.summary;
  }

  private monthlySuggestionText(insight: GalleryMonthlyInsight): string {
    let summary = this.monthlyAiSummary(insight);
    if (summary && summary.suggestion && summary.suggestion.length > 0) {
      return summary.suggestion;
    }
    return '';
  }

  private monthlyAiButtonText(insight: GalleryMonthlyInsight): string {
    if (this.monthlyAiLoadingKey === insight.key) {
      return '生成中';
    }
    return this.monthlyAiSummary(insight) ? '重生成' : 'AI 总结';
  }

  private monthlyAiError(insight: GalleryMonthlyInsight): string {
    if (this.monthlyAiErrorKey === insight.key) {
      return this.monthlyAiErrorText;
    }
    return '';
  }

  private clearMonthlyAiState(): void {
    this.monthlyAiSummaries = {};
    this.monthlyAiLoadingKey = '';
    this.monthlyAiErrorKey = '';
    this.monthlyAiErrorText = '';
  }

  private clearMonthlyAiRuntimeState(): void {
    this.monthlyAiLoadingKey = '';
    this.monthlyAiErrorKey = '';
    this.monthlyAiErrorText = '';
  }

  private restoreMonthlyAiSummaries(): void {
    if (this.filesDir.length === 0) {
      return;
    }
    let cached = GalleryStorage.loadMonthlySummaries(this.filesDir);
    let next: Record<string, GalleryMonthSummaryCacheRecord> = {};
    let insights = this.monthlyInsights();
    for (let i = 0; i < insights.length; i++) {
      let record = cached[insights[i].key];
      // signature 不一致说明该月图片结果发生过变化，需要让用户重新生成 AI 总结。
      if (record && record.signature === this.monthlyInsightSignature(insights[i])) {
        next[insights[i].key] = record;
      }
    }
    this.monthlyAiSummaries = next;
  }

  private monthlyInsightSignature(insight: GalleryMonthlyInsight): string {
    // 使用参与总结的核心字段生成稳定签名，避免复用过期的月度 AI 总结。
    let parts: string[] = [insight.key, insight.totalCount.toString()];
    for (let i = 0; i < insight.entriesForLlm.length; i++) {
      let item = insight.entriesForLlm[i];
      parts.push([
        item.id,
        item.date,
        item.category,
        item.title,
        item.summary,
        item.createdAt.toString()
      ].join('|'));
    }
    return this.stableId(parts.join('\n'));
  }

  private galleryCloudModelConfig(): GalleryCloudModelConfig {
    return {
      baseUrl: this.galleryApiBaseUrl.trim().length > 0 ? this.galleryApiBaseUrl.trim() : DEFAULT_GALLERY_API_BASE_URL,
      apiKey: configuredEndpointSecretOrDefault(this.galleryApiKey, DEFAULT_GALLERY_API_KEY),
      model: this.galleryModel.trim().length > 0 ? this.galleryModel.trim() : DEFAULT_GALLERY_MODEL
    };
  }

  private async generateAiMonthlySummary(insight: GalleryMonthlyInsight): Promise<void> {
    if (this.monthlyAiLoadingKey.length > 0) {
      return;
    }
    this.monthlyAiLoadingKey = insight.key;
    this.monthlyAiErrorKey = '';
    this.monthlyAiErrorText = '';
    try {
      let result = await this.cloudClient.summarizeGalleryMonth(this.galleryCloudModelConfig(),
        GalleryMonthlyInsights.buildLlmInput(insight));
      let record: GalleryMonthSummaryCacheRecord = {
        signature: this.monthlyInsightSignature(insight),
        title: result.title,
        summary: result.summary,
        suggestion: result.suggestion,
        rawText: result.rawText,
        updatedAt: new Date().getTime()
      };
      GalleryStorage.saveMonthlySummary(this.filesDir, insight.key, record);
      // ArkUI 对对象深层变更不总是触发刷新，这里构造新对象保证页面同步更新。
      let next: Record<string, GalleryMonthSummaryCacheRecord> = {};
      let keys = Object.keys(this.monthlyAiSummaries);
      for (let i = 0; i < keys.length; i++) {
        next[keys[i]] = this.monthlyAiSummaries[keys[i]];
      }
      next[insight.key] = record;
      this.monthlyAiSummaries = next;
    } catch (e) {
      this.monthlyAiErrorKey = insight.key;
      this.monthlyAiErrorText = this.errorMessage(e);
      showToastSafely('AI 月度总结失败：' + this.errorMessage(e), 1800);
    }
    this.monthlyAiLoadingKey = '';
  }

  private restoreLastRunFromResults(): void {
    if (this.results.length === 0) {
      this.setLastRunLabel('尚未开始');
      return;
    }
    let latest = 0;
    for (let i = 0; i < this.results.length; i++) {
      if (this.results[i].createdAt > latest) {
        latest = this.results[i].createdAt;
      }
    }
    if (latest > 0) {
      this.setLastRun(latest);
    } else {
      this.setLastRunLabel('尚未开始');
    }
  }

  private setLastRun(ts: number): void {
    this.lastRunAt = ts;
    this.lastRunText = this.relativeTimeText(ts);
  }

  private setLastRunLabel(label: string): void {
    this.lastRunAt = 0;
    this.lastRunText = label;
  }

  private startLastRunTimer(): void {
    if (this.lastRunTimerId !== -1) {
      return;
    }
    this.lastRunTimerId = setInterval(() => {
      if (this.lastRunAt > 0) {
        this.lastRunText = this.relativeTimeText(this.lastRunAt);
      }
    }, 60 * 1000);
  }

  private stopLastRunTimer(): void {
    if (this.lastRunTimerId !== -1) {
      clearInterval(this.lastRunTimerId);
      this.lastRunTimerId = -1;
    }
  }

  private relativeTimeText(ts: number): string {
    let diffMs = new Date().getTime() - ts;
    if (diffMs < 0) {
      diffMs = 0;
    }
    let minuteMs = 60 * 1000;
    let hourMs = 60 * minuteMs;
    let dayMs = 24 * hourMs;
    let monthMs = 30 * dayMs;
    if (diffMs < 2 * minuteMs) {
      return '刚刚';
    }
    if (diffMs < 30 * minuteMs) {
      return Math.max(1, Math.floor(diffMs / minuteMs)).toString() + '分钟前';
    }
    if (diffMs < hourMs) {
      return '半小时前';
    }
    if (diffMs < dayMs) {
      return Math.max(1, Math.floor(diffMs / hourMs)).toString() + '小时前';
    }
    if (diffMs < monthMs) {
      return Math.max(1, Math.floor(diffMs / dayMs)).toString() + '天前';
    }
    if (diffMs < 12 * monthMs) {
      return Math.max(1, Math.floor(diffMs / monthMs)).toString() + '个月前';
    }
    return Math.max(1, Math.floor(diffMs / (12 * monthMs))).toString() + '年前';
  }

  private createScanSession(inputs: GalleryPhotoInput[]): GalleryScanSession {
    let items: GalleryScanItem[] = [];
    let seen: Record<string, boolean> = {};
    for (let i = 0; i < inputs.length; i++) {
      let input = inputs[i];
      let id = this.stableId(input.uri);
      let inputId = input.id;
      if (inputId !== undefined && inputId.length > 0) {
        id = inputId;
      }
      let date = this.formatDate(new Date().getTime());
      let inputDate = input.date;
      if (inputDate !== undefined && inputDate.length > 0) {
        date = inputDate;
      }
      // 媒体库偶尔可能返回重复 uri/id，扫描会话内按 id 去重，避免总数和跳过数重复累计。
      if (seen[id]) {
        continue;
      }
      seen[id] = true;
      items.push({
        uri: input.uri,
        id: id,
        date: date,
        status: 'queued',
        error: '',
        skipReason: ''
      });
    }
    let now = new Date().getTime();
    return {
      id: 'gallery_scan_' + now.toString(),
      status: 'queued',
      createdAt: now,
      updatedAt: now,
      total: items.length,
      processed: 0,
      skipped: 0,
      failed: 0,
      items: items
    };
  }

  private pendingInputs(session: GalleryScanSession): GalleryPhotoInput[] {
    let inputs: GalleryPhotoInput[] = [];
    for (let i = 0; i < session.items.length; i++) {
      if (session.items[i].status === 'queued' || session.items[i].status === 'failed') {
        // 恢复扫描时允许失败项重新进入队列，避免一次模型或网络失败永久卡住任务。
        if (session.items[i].status === 'failed') {
          session.items[i].status = 'queued';
          session.items[i].error = '';
          session.items[i].skipReason = '';
        }
        inputs.push({
          uri: session.items[i].uri,
          id: session.items[i].id,
          date: session.items[i].date
        });
      }
    }
    this.recountScanSession(session);
    return inputs;
  }

  private markScanItem(session: GalleryScanSession, input: GalleryPhotoInput, cached: boolean, error: string, skippedByKeyword: boolean): boolean {
    let inputId = input.id !== undefined && input.id.length > 0 ? input.id : this.stableId(input.uri);
    let inputDate = input.date !== undefined && input.date.length > 0 ? input.date : '';
    for (let i = 0; i < session.items.length; i++) {
      let sameIdentity = session.items[i].id === inputId && (inputDate.length === 0 || session.items[i].date === inputDate);
      if (sameIdentity || session.items[i].uri === input.uri) {
        if (error && error.length > 0) {
          session.items[i].status = 'failed';
          session.items[i].error = error;
          session.items[i].skipReason = '';
        } else {
          // 缓存命中不再视为跳过；只有 OCR 关键词预筛未命中才进入 skipped，便于跳过面板准确解释。
          session.items[i].status = cached && skippedByKeyword ? 'skipped' : 'done';
          session.items[i].error = '';
          if (cached && skippedByKeyword) {
            session.items[i].skipReason = 'OCR 关键词预筛未命中';
          } else {
            session.items[i].skipReason = '';
          }
        }
        session.updatedAt = new Date().getTime();
        this.recountScanSession(session);
        return true;
      }
    }
    return false;
  }

  private recountScanSession(session: GalleryScanSession): void {
    let processed = 0;
    let skipped = 0;
    let failed = 0;
    for (let i = 0; i < session.items.length; i++) {
      this.normalizeScanItemStatus(session.items[i]);
      if (session.items[i].status === 'done' || session.items[i].status === 'skipped') {
        processed += 1;
      }
      if (session.items[i].status === 'skipped') {
        skipped += 1;
      }
      if (session.items[i].status === 'failed') {
        failed += 1;
      }
    }
    session.total = session.items.length;
    session.processed = processed;
    session.skipped = skipped;
    session.failed = failed;
  }

  private normalizeScanItemStatus(item: GalleryScanItem): void {
    // 兼容旧版本会话：历史上“已有缓存”曾被记为 skipped，这里迁移为 done，避免每次全扫重复计入跳过。
    if (item.status === 'skipped' && item.skipReason === '已存在可用缓存') {
      item.status = 'done';
      item.error = '';
      item.skipReason = '';
    }
  }

  private applyScanSession(session: GalleryScanSession): void {
    // 将落盘会话同步到页面展示；所有进度卡片和顶部“已分析 x/y”都从这些状态读取。
    this.recountScanSession(session);
    this.scanTotal = session.total;
    this.scanProcessed = session.processed;
    this.scanSkipped = session.skipped;
    this.scanFailed = session.failed;
    this.scanPending = Math.max(0, session.total - session.processed);
    this.autoScanStatus = this.effectiveScanStatus(session.status);
    this.progress = this.progressPercentFromUnits(session.processed, session.total);
    this.scanRevision += 1;
  }

  private effectiveScanStatus(status: string): string {
    // 用户点击暂停后，session 可能仍是 running；页面应优先展示“暂停中”的用户意图。
    if (this.analyzing && this.pauseRequested && status === 'running') {
      return 'pausing';
    }
    return status;
  }

  private restoreScanSessionState(): void {
    let session = GalleryStorage.loadScanSession(this.filesDir);
    if (!session) {
      this.autoScanStatus = 'idle';
      return;
    }
    this.applyScanSession(session);
    GalleryStorage.saveScanSession(this.filesDir, session);
    if (this.scanPending > 0 && session.status === 'completed') {
      // 防御旧会话异常：状态 completed 但仍有未完成项时，降级为 paused 允许用户继续。
      session.status = 'paused';
      GalleryStorage.saveScanSession(this.filesDir, session);
      this.applyScanSession(session);
    }
    if (this.scanPending > 0 && (session.status === 'paused' || session.status === 'pausing' || session.status === 'running')) {
      this.setLastRunLabel('已暂停');
    }
  }

  private skippedScanItems(): GalleryScanItem[] {
    // 跳过面板只展示真正被 OCR 关键词预筛过滤的图片，不展示缓存命中的已完成图片。
    let session = GalleryStorage.loadScanSession(this.filesDir);
    if (!session) {
      return [];
    }
    let items: GalleryScanItem[] = [];
    for (let i = 0; i < session.items.length; i++) {
      if (session.items[i].status === 'skipped') {
        items.push(session.items[i]);
      }
    }
    return items;
  }

  private openSkippedPanel(): void {
    let items = this.skippedScanItems();
    if (items.length === 0) {
      showToastSafely('当前没有跳过的图片', 1200);
      return;
    }
    this.skippedPanelItems = items;
    this.skippedPanelOpen = true;
    this.skippedPanelRevision += 1;
  }

  private closeSkippedPanel(): void {
    this.skippedPanelOpen = false;
  }

  private skippedReason(item: GalleryScanItem): string {
    if (item.skipReason !== undefined && item.skipReason.length > 0) {
      return item.skipReason;
    }
    return '已跳过';
  }

  private stableId(uri: string): string {
    let hash = 0;
    for (let i = 0; i < uri.length; i++) {
      hash = ((hash << 5) - hash) + uri.charCodeAt(i);
      hash = hash & hash;
    }
    return 'gallery_' + Math.abs(hash).toString();
  }

  private normalizeConcurrency(value: string, fallback: string, maxValue: number): string {
    let digits = '';
    for (let i = 0; i < value.length; i++) {
      let ch = value.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      }
    }
    if (digits.length === 0) {
      return fallback;
    }
    let num = parseInt(digits);
    if (num < 1) {
      num = 1;
    }
    if (num > maxValue) {
      num = maxValue;
    }
    return num.toString();
  }

  private normalizeScale(value: string, fallback: string): string {
    let parsed = parseFloat(value);
    if (isNaN(parsed)) {
      parsed = parseFloat(fallback);
    }
    if (isNaN(parsed)) {
      parsed = 0.25;
    }
    if (parsed < 0.1) {
      parsed = 0.1;
    }
    if (parsed > 1) {
      parsed = 1;
    }
    return parsed.toFixed(2);
  }

  @Builder StatCell(label: string, value: string, color: string) {
    Column() {
      Text(label).fontSize(12).fontColor('#737987').maxLines(1)
      Text(value)
        .fontSize(label === '最近分析' ? 14 : 21)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .margin({ top: 5 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  private runAction(actionId: number): void {
    if (actionId === 0) {
      if (this.hasPausedScan()) {
        this.continueAutoAnalyze();
      } else {
        this.startAutoAnalyze();
      }
      return;
    }
    if (actionId === 1) {
      this.startManualAnalyze();
      return;
    }
    if (actionId === 3) {
      this.requestPauseAutoAnalyze();
      return;
    }
    if (actionId === 2) {
      this.confirmClearAnalysis();
    }
  }

  private confirmClearAnalysis(): void {
    if (this.analyzing) {
      showToastSafely('图库分析正在进行，无法清空', 1200);
      return;
    }
    promptAction.showDialog({
      title: '清空分析',
      message: '将清空已保存的图库分析结果、扫描进度、月度总结和位置缓存。此操作不可恢复。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '清空', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        this.clearAnalysis();
      }
    }).catch(() => {});
  }

  private clearAnalysis(): void {
    GalleryStorage.clear(this.filesDir);
    GalleryStorage.clearScanSession(this.filesDir);
    GalleryStorage.clearMonthlySummaries(this.filesDir);
    GalleryStorage.clearLocationCache(this.filesDir);
    this.replaceResults([]);
    this.clearMonthlyAiState();
    this.locationCacheRecords = {};
    this.locationResolvingKey = '';
    this.locationResolveErrorKey = '';
    this.locationResolveErrorText = '';
    this.locationResolveRevision += 1;
    this.progress = 0;
    this.selectedFilter = 0;
    this.selectedTimeFilter = 0;
    this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
    this.scanTotal = 0;
    this.scanProcessed = 0;
    this.scanPending = 0;
    this.scanSkipped = 0;
    this.scanFailed = 0;
    this.scanRevision += 1;
    this.autoScanStatus = 'idle';
    this.setLastRunLabel('尚未开始');
    showToastSafely('图库缓存已清理', 1200);
  }

  private hasPausedScan(): boolean {
    return !this.analyzing && this.scanPending > 0 &&
      (this.autoScanStatus === 'paused' || this.autoScanStatus === 'pausing' || this.autoScanStatus === 'running');
  }

  private autoActionTitle(): string {
    if (this.analyzing) {
      return '分析中';
    }
    if (this.hasPausedScan()) {
      return '继续分析';
    }
    return '图库分析';
  }

  @Builder PrimaryActionButton() {
    Row() {
      Text('选择图片分析').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Color.White).layoutWeight(1).maxLines(1)
      Text('>')
        .fontSize(18)
        .fontColor('#39BFA3')
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor(Color.White)
        .borderRadius(15)
    }
    .width('100%')
    .height(50)
    .padding({ left: 16, right: 14 })
    .backgroundColor('#39BFA3')
    .borderRadius(15)
    .margin({ top: 10 })
    .onClick(() => { this.runAction(1); })
  }

  @Builder HeaderIconButton(label: string, actionId: number) {
    Text(label)
      .fontSize(18)
      .fontColor('#2F5BEA')
      .width(38)
      .height(38)
      .textAlign(TextAlign.Center)
      .backgroundColor('#EEF3FF')
      .borderRadius(10)
      .onClick(() => {
        if (actionId === 0) {
          router.back();
          return;
        }
        this.settingsOpen = !this.settingsOpen;
      })
  }

  @Builder ToolbarAction(title: string, color: string, bg: string, actionId: number) {
    Button(title)
      .height(38)
      .layoutWeight(1)
      .fontSize(12)
      .fontColor(color)
      .backgroundColor(bg)
      .borderRadius(9)
      .enabled(!(this.analyzing && actionId !== 3))
      .onClick(() => { this.runAction(actionId); })
  }

  @Builder ActionToolbar() {
    Column() {
      ForEach([this.scanRevision + this.progressRevision + this.resultRevision], (_revision: number) => {
        Column() {
          Row() {
            this.StatCell('已分析', this.analyzedCountText(), '#2F5BEA')
            Divider().vertical(true).height(38).color('#E5E8F0')
            this.StatCell('最近分析', this.lastRunText, '#202636')
          }.width('100%')

          Row() {
            this.ToolbarAction('选择图片', '#FFFFFF', '#2F5BEA', 1)
            Blank().width(8)
            this.ToolbarAction(this.autoActionTitle(), '#2F5BEA', '#EEF3FF', 0)
            Blank().width(8)
            if (this.analyzing) {
              this.ToolbarAction(this.autoScanStatus === 'pausing' ? '暂停中' : '暂停', '#B55A00', '#FFF4E8', 3)
            } else {
              this.ToolbarAction('清空分析', '#B55A00', '#FFF4E8', 2)
            }
          }
          .width('100%')
          .margin({ top: 14 })
        }.width('100%')
      }, (revision: number) => revision.toString())
    }
    .width('90%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .margin({ top: 14 })
  }

  private shouldShowProgressStrip(): boolean {
    if (this.manualAnalyzing) {
      return false;
    }
    return this.analyzing || this.hasPausedScan() || this.scanTotal > 0;
  }

  private progressTitle(): string {
    if (this.analyzing) {
      return this.autoScanStatus === 'pausing' ? '暂停中' : '分析中';
    }
    if (this.hasPausedScan()) {
      return '已暂停';
    }
    if (this.scanTotal > 0 && this.scanPending === 0) {
      return '已完成';
    }
    return '分析进度';
  }

  @Builder ProgressStrip() {
    Column() {
      ForEach([this.scanRevision + this.progressRevision + this.resultRevision], (_revision: number) => {
        Column() {
          Row() {
            Text(this.progressTitle())
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#202636')
              .layoutWeight(1)
            Text(this.progressPercentText(this.progress))
              .fontSize(12)
              .fontColor('#667085')
          }.width('100%')
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(6)
              .backgroundColor('#E8EDF7')
              .borderRadius(3)
            Row()
              .width(this.progressFillWidth(this.progress))
              .height(6)
              .backgroundColor('#2F5BEA')
              .borderRadius(3)
          }
          .width('100%')
          .height(6)
          .margin({ top: 8 })
          this.ScanStatsPanel()
        }.width('100%')
      }, (revision: number) => revision.toString())
    }
    .width('90%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .margin({ top: 10 })
  }

  @Builder CompactActionButton(title: string, color: string, actionId: number) {
    Row() {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#151A28').layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('>')
        .fontSize(15)
        .fontColor(color)
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
    }
    .height(44)
    .layoutWeight(1)
    .padding({ left: 12, right: 10 })
    .backgroundColor('#F8FAFE')
    .borderRadius(13)
    .onClick(() => { this.runAction(actionId); })
  }

  @Builder ScanStatCell(label: string, value: number, color: string, actionId: number) {
    Column() {
      Text(actionId === 1 && value > 0 ? label + ' >' : label).fontSize(11).fontColor('#7C8494').maxLines(1)
      Text(value.toString()).fontSize(16).fontWeight(FontWeight.Bold).fontColor(color).margin({ top: 3 }).maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (actionId === 1) {
        this.openSkippedPanel();
      }
    })
  }

  @Builder ScanStatTextCell(label: string, value: string, color: string) {
    Column() {
      Text(label).fontSize(11).fontColor('#7C8494').maxLines(1)
      Text(value).fontSize(16).fontWeight(FontWeight.Bold).fontColor(color).margin({ top: 3 }).maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder ScanStatsPanel() {
    if (this.scanTotal > 0 || this.analyzing) {
      Column() {
        Row() {
          this.ScanStatCell('总数', this.scanTotal, '#151A28', 0)
          this.ScanStatCell('已完成', this.scanProcessed, '#5B68FF', 0)
          this.ScanStatCell('未完成', this.scanPending, '#FF8A3D', 0)
          this.ScanStatCell('跳过', this.scanSkipped, '#39BFA3', 1)
          this.ScanStatCell('失败', this.scanFailed, '#E5484D', 0)
        }.width('100%')
      }
      .width('100%')
      .margin({ top: 14 })
    }
  }

  private updateSetting(fieldId: number, value: string): void {
    if (fieldId === 0) {
      this.galleryApiBaseUrl = value;
      return;
    }
    if (fieldId === 1) {
      this.galleryApiKey = value;
      return;
    }
    if (fieldId === 2) {
      this.galleryModel = value;
      return;
    }
    if (fieldId === 3) {
      this.gallerySkipOcr = value;
      return;
    }
    if (fieldId === 4) {
      this.galleryEmbeddingMode = value === 'true' ? 'remote' : 'huawei_local';
      return;
    }
    if (fieldId === 9) {
      this.galleryUseOcrKeywordFilter = value;
      return;
    }
    if (fieldId === 11) {
      this.galleryParallelFieldRequests = value;
      return;
    }
    if (fieldId === 10) {
      this.galleryAmapWebKey = value;
      return;
    }
    if (fieldId === 5) {
      this.galleryEmbeddingBaseUrl = value;
      return;
    }
    if (fieldId === 6) {
      this.galleryEmbeddingApiKey = value;
      return;
    }
    if (fieldId === 7) {
      this.galleryEmbeddingModel = value;
      return;
    }
    this.galleryImageScale = this.normalizeScale(value, this.galleryImageScale);
  }

  private updateConcurrency(fieldId: number, value: string, maxValue: number): void {
    if (fieldId === 0) {
      this.galleryOcrConcurrency = this.normalizeConcurrency(value, this.galleryOcrConcurrency, maxValue);
      return;
    }
    if (fieldId === 1) {
      this.galleryModelConcurrency = this.normalizeConcurrency(value, this.galleryModelConcurrency, maxValue);
      return;
    }
    this.galleryEmbeddingConcurrency = this.normalizeConcurrency(value, this.galleryEmbeddingConcurrency, maxValue);
  }

  @Builder SettingInput(label: string, value: string, placeholder: string, fieldId: number,
    defaultValue: string = '', hideDefaultValue: boolean = false) {
    Column() {
      Text(label).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2F3645').width('100%')
      TextInput({
        placeholder: hideDefaultValue ? hiddenDefaultSettingPlaceholder(value, defaultValue, placeholder) : placeholder,
        text: hideDefaultValue ? hiddenDefaultSettingEditorValue(value, defaultValue) : value
      })
        .width('100%')
        .height(42)
        .fontSize(12)
        .backgroundColor('#F7F9FE')
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .margin({ top: 8 })
        .onChange((next: string) => { this.updateSetting(fieldId, next); })
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder ConcurrencyInput(label: string, value: string, rangeText: string, maxValue: number, fieldId: number) {
    Column() {
      Row() {
        Text(label).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2F3645').layoutWeight(1)
        Text(rangeText).fontSize(11).fontColor('#8A92A3')
      }.width('100%')
      TextInput({ placeholder: value, text: value })
        .width('100%')
        .height(42)
        .fontSize(12)
        .backgroundColor('#F7F9FE')
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .margin({ top: 8 })
        .onChange((next: string) => { this.updateConcurrency(fieldId, next, maxValue); })
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder SettingToggle(label: string, desc: string, enabled: boolean, fieldId: number) {
    Row() {
      Column() {
        Text(label).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2F3645').width('100%')
        Text(desc).fontSize(11).fontColor('#8A92A3').margin({ top: 4 }).width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor('#5B68FF')
        .onChange((next: boolean) => { this.updateSetting(fieldId, next ? 'true' : 'false'); })
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder SettingsPanel() {
    if (this.settingsOpen) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.activeSensitiveInputId = '';
            this.settingsOpen = false;
          })

        Column() {
          Row() {
            Column() {
              Text('图库采集设置').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#11182F')
              Text('云端模型、OCR 与索引写入并发').fontSize(12).fontColor('#7B8290').margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('关闭')
              .fontSize(13)
              .fontColor('#5B68FF')
              .onClick(() => {
                this.activeSensitiveInputId = '';
                this.settingsOpen = false;
              })
          }.width('100%')

          Scroll() {
            Column() {
              ForEach([this.settingsRevision], (_revision: number) => {
                Column() {
                  this.SettingInput('云端 API Base URL', this.galleryApiBaseUrl, '输入云端 API Base URL', 0,
                    DEFAULT_GALLERY_API_BASE_URL, true)
                  SensitiveSettingInput({
                    sensitiveId: 'galleryPageApiKey',
                    activeSensitiveId: this.activeSensitiveInputId,
                    label: 'API Key',
                    value: this.galleryApiKey,
                    defaultValue: DEFAULT_GALLERY_API_KEY,
                    placeholder: 'Bearer token 或服务密钥',
                    onActiveSensitiveChange: (value: string) => { this.activeSensitiveInputId = value; },
                    onValueChange: (value: string) => { this.updateSetting(1, value); }
                  })
                  this.SettingInput('大模型名称', this.galleryModel, 'MiniCPM-V-4.6-Instruct', 2)
                  this.SettingToggle('跳过本地 OCR', '设备不支持 CoreVision OCR 时开启，直接让大模型分析图片', this.gallerySkipOcr === 'true', 3)
                  this.SettingToggle('OCR 关键词预筛', '自动全库分析时先用 OCR 关键词过滤，手动选择图片不受影响', this.galleryUseOcrKeywordFilter === 'true', 9)
                  this.SettingToggle('字段级并发请求', '同一张图并发请求 title/category/summary/details/tags/importance，降低整包 JSON 解析失败概率', this.galleryParallelFieldRequests === 'true', 11)
                  SensitiveSettingInput({
                    sensitiveId: 'galleryPageAmapWebKey',
                    activeSensitiveId: this.activeSensitiveInputId,
                    label: '高德 Web 服务 Key',
                    value: this.galleryAmapWebKey,
                    defaultValue: DEFAULT_GALLERY_AMAP_WEB_KEY,
                    placeholder: '用于拍摄位置逆地理编码',
                    onActiveSensitiveChange: (value: string) => { this.activeSensitiveInputId = value; },
                    onValueChange: (value: string) => { this.updateSetting(10, value); }
                  })
                  this.ConcurrencyInput('OCR 并发请求数', this.galleryOcrConcurrency, '范围 1-6，默认 3', 6, 0)
                  this.ConcurrencyInput('大模型并发请求数', this.galleryModelConcurrency, '范围 1-4，默认 2', 4, 1)
                  this.SettingToggle('使用云端 Embedding API', '关闭时使用华为端侧 Embedding；开启时使用 SiliconFlow / bge-m3', this.galleryEmbeddingMode === 'remote', 4)
                  this.SettingInput('Embedding Base URL', this.galleryEmbeddingBaseUrl, '输入 Embedding Base URL', 5,
                    DEFAULT_GALLERY_EMBEDDING_BASE_URL, true)
                  SensitiveSettingInput({
                    sensitiveId: 'galleryPageEmbeddingApiKey',
                    activeSensitiveId: this.activeSensitiveInputId,
                    label: 'Embedding API Key',
                    value: this.galleryEmbeddingApiKey,
                    defaultValue: DEFAULT_GALLERY_EMBEDDING_API_KEY,
                    placeholder: 'SiliconFlow 服务密钥',
                    onActiveSensitiveChange: (value: string) => { this.activeSensitiveInputId = value; },
                    onValueChange: (value: string) => { this.updateSetting(6, value); }
                  })
                  this.SettingInput('Embedding 模型', this.galleryEmbeddingModel, 'BAAI/bge-m3', 7)
                  this.ConcurrencyInput('Embedding 并发请求数', this.galleryEmbeddingConcurrency, '范围 1-4，默认 2', 4, 2)
                  this.SettingInput('图片分析缩放比例', this.galleryImageScale, '0.10 - 1.00，默认 0.25', 8)
                }.width('100%')
              }, (revision: number) => revision.toString())
            }.width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 6 })

          Row() {
            Button('恢复默认')
              .height(40)
              .layoutWeight(1)
              .fontSize(12)
              .backgroundColor('#EEF4FF')
              .fontColor('#4F68FF')
              .borderRadius(12)
              .onClick(() => {
                this.galleryApiBaseUrl = DEFAULT_GALLERY_API_BASE_URL;
                this.galleryApiKey = DEFAULT_GALLERY_API_KEY;
                this.galleryModel = DEFAULT_GALLERY_MODEL;
                this.gallerySkipOcr = DEFAULT_GALLERY_SKIP_OCR;
                this.galleryUseOcrKeywordFilter = DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER;
                this.galleryOcrConcurrency = DEFAULT_GALLERY_OCR_CONCURRENCY;
                this.galleryModelConcurrency = DEFAULT_GALLERY_MODEL_CONCURRENCY;
                this.galleryEmbeddingConcurrency = DEFAULT_GALLERY_EMBEDDING_CONCURRENCY;
                this.galleryParallelFieldRequests = DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS;
                this.galleryEmbeddingMode = DEFAULT_GALLERY_EMBEDDING_MODE;
                this.galleryEmbeddingBaseUrl = DEFAULT_GALLERY_EMBEDDING_BASE_URL;
                this.galleryEmbeddingApiKey = DEFAULT_GALLERY_EMBEDDING_API_KEY;
                this.galleryEmbeddingModel = DEFAULT_GALLERY_EMBEDDING_MODEL;
                this.galleryImageScale = DEFAULT_GALLERY_IMAGE_SCALE;
                this.galleryAmapWebKey = DEFAULT_GALLERY_AMAP_WEB_KEY;
                this.settingsRevision += 1;
              })
            Button('保存')
              .height(40)
              .layoutWeight(1)
              .fontSize(12)
              .backgroundColor('#5B68FF')
              .borderRadius(12)
              .margin({ left: 10 })
              .onClick(() => {
                this.activeSensitiveInputId = '';
                this.settingsOpen = false;
                showToastSafely('图库采集设置已保存', 1200);
              })
          }.width('100%').margin({ top: 16 })
        }
        .width('86%')
        .height('82%')
        .padding(18)
        .backgroundColor(Color.White)
        .borderRadius(18)
        .shadow({ radius: 24, color: '#24000000', offsetX: 0, offsetY: 10 })
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder DetailSectionTitle(label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor('#202636')
      .width('100%')
      .margin({ top: 14 })
  }

  @Builder DetailInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#7C8494')
        .width(64)
        .maxLines(1)
      Text(value)
        .fontSize(12)
        .fontColor('#303746')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder DetailLinkRow(label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#7C8494')
        .width(64)
        .maxLines(1)
      Text(value)
        .fontSize(12)
        .fontColor('#5B68FF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
    .onClick(onTap)
  }

  @Builder DetailLocationPreview(item: GalleryAnalysisResult) {
    Column() {
      Row() {
        Column() {
          Text('地址解析')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
          Text(this.captureLocationPreviewText(item))
            .fontSize(12)
            .fontColor('#5E6678')
            .lineHeight(18)
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ right: 10 })
        Text(this.captureLocationActionText(item))
          .fontSize(12)
          .fontColor('#5B68FF')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#EEF4FF')
          .borderRadius(10)
          .onClick(() => {
            if (configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY).length === 0) {
              this.activeSensitiveInputId = '';
              this.settingsOpen = true;
              return;
            }
            this.resolveCaptureAddressLazy(item, true);
          })
      }
      .width('100%')
      if (this.captureAddressText(item).length > 0) {
        Text(this.captureAddressText(item))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .lineHeight(22)
          .width('100%')
          .margin({ top: 10 })
      }
      if (this.capturePoiText(item).length > 0) {
        Text('附近：' + this.capturePoiText(item))
          .fontSize(12)
          .fontColor('#6B7280')
          .width('100%')
          .margin({ top: 6 })
      }
      if (this.captureStaticMapUrl(item).length > 0) {
        Image(this.captureStaticMapUrl(item))
          .width('100%')
          .height(138)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .backgroundColor('#EDF1F7')
          .margin({ top: 10 })
      }
      Row() {
        Text('查看地图标注')
          .fontSize(12)
          .fontColor('#5B68FF')
          .onClick(() => {
            this.openCaptureMap(item);
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(12)
    .borderRadius(14)
    .backgroundColor('#F7F9FC')
    .margin({ top: 10 })
  }

  @Builder DetailTag(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor('#596273')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor('#F1F4FA')
      .borderRadius(8)
      .margin({ right: 7, top: 7 })
  }

  @Builder DetailBullet(detail: string) {
    Text('· ' + detail)
      .fontSize(12)
      .fontColor('#4D5566')
      .lineHeight(18)
      .width('100%')
      .margin({ top: 6 })
  }

  @Builder DetailBulletSlot(item: GalleryAnalysisResult, index: number) {
    if (this.detailAt(item, index).length > 0) {
      this.DetailBullet(this.detailAt(item, index))
    }
  }

  @Builder DetailBulletSlots(item: GalleryAnalysisResult) {
    this.DetailBulletSlot(item, 0)
    this.DetailBulletSlot(item, 1)
    this.DetailBulletSlot(item, 2)
    this.DetailBulletSlot(item, 3)
    this.DetailBulletSlot(item, 4)
    this.DetailBulletSlot(item, 5)
    this.DetailBulletSlot(item, 6)
    this.DetailBulletSlot(item, 7)
  }

  @Builder DetailTagSlot(item: GalleryAnalysisResult, index: number) {
    if (this.tagAt(item, index).length > 0) {
      this.DetailTag(this.tagAt(item, index))
    }
  }

  @Builder DetailTagSlots(item: GalleryAnalysisResult) {
    Row() {
      this.DetailTagSlot(item, 0)
      this.DetailTagSlot(item, 1)
      this.DetailTagSlot(item, 2)
      this.DetailTagSlot(item, 3)
      this.DetailTagSlot(item, 4)
    }
    .width('100%')
    .margin({ top: 1 })
  }

  @Builder ResultDetailPanel() {
    if (this.selectedDetailId.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.closeResultDetail(); })

        ForEach(this.selectedDetailItems(), (item: GalleryAnalysisResult) => {
          Column() {
            Row() {
              Column() {
                Text(item.title)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#11182F')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.categoryLabel(item.category))
                  .fontSize(12)
                  .fontColor(this.categoryColor(item.category))
                  .margin({ top: 5 })
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ right: 12 })
              AiGeneratedBadge({ compact: true })
                .margin({ right: 12 })
              Text('关闭')
                .fontSize(13)
                .fontColor('#5B68FF')
                .onClick(() => { this.closeResultDetail(); })
            }
            .width('100%')

            Scroll() {
              Column() {
                Image(this.previewUri(item))
                  .width('100%')
                  .height(220)
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#F2F4F7')
                  .borderRadius(12)
                  .margin({ top: 14 })

                Text(item.summary)
                  .fontSize(13)
                  .fontColor('#4D5566')
                  .lineHeight(20)
                  .width('100%')
                  .margin({ top: 12 })

                this.DetailSectionTitle('基础信息')
                this.DetailInfoRow('时间', this.resultTime(item))
                this.DetailInfoRow('日期', this.groupDate(item))
                this.DetailInfoRow('状态', this.resultStatus(item))
                this.DetailInfoRow('ID', item.id)
                if (this.captureTimeText(item).length > 0) {
                  this.DetailInfoRow('拍摄时间', this.captureTimeText(item))
                }
                if (this.captureDeviceText(item).length > 0) {
                  this.DetailInfoRow('拍摄设备', this.captureDeviceText(item))
                }
                if (this.captureLocationText(item).length > 0) {
                  this.DetailInfoRow('拍摄位置', this.captureLocationText(item))
                }
                ForEach([this.locationResolveRevision], (_revision: number) => {
                  if (this.captureAddressText(item).length > 0) {
                    this.DetailInfoRow('地理位置', this.captureAddressText(item))
                  }
                  if (this.capturePoiText(item).length > 0) {
                    this.DetailInfoRow('附近地点', this.capturePoiText(item))
                  }
                }, (revision: number) => item.id + '_location_' + revision.toString())
                if (this.captureMapUrl(item).length > 0) {
                  this.DetailLocationPreview(item)
                }
                if (this.captureSizeText(item).length > 0) {
                  this.DetailInfoRow('图片尺寸', this.captureSizeText(item))
                }

                if (this.resultDetails(item).length > 0) {
                  this.DetailSectionTitle('分析明细')
                  this.DetailBulletSlots(item)
                }

                if (this.resultTags(item).length > 0) {
                  this.DetailSectionTitle('标签')
                  this.DetailTagSlots(item)
                }

                if (item.ocrText && item.ocrText.length > 0) {
                  this.DetailSectionTitle('OCR 文本')
                  Text(item.ocrText)
                    .fontSize(12)
                    .fontColor('#4D5566')
                    .lineHeight(18)
                    .width('100%')
                    .padding(10)
                    .backgroundColor('#F7F9FC')
                    .borderRadius(10)
                    .margin({ top: 8 })
                }

                if (item.error && item.error.length > 0) {
                  this.DetailSectionTitle('错误信息')
                  Text(item.error)
                    .fontSize(12)
                    .fontColor('#B42318')
                    .lineHeight(18)
                    .width('100%')
                    .padding(10)
                    .backgroundColor('#FFF4F2')
                    .borderRadius(10)
                    .margin({ top: 8 })
                }

                Blank().height(8)
              }
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
          }
          .width('88%')
          .height('82%')
          .padding(18)
          .backgroundColor(Color.White)
          .borderRadius(18)
          .shadow({ radius: 24, color: '#24000000', offsetX: 0, offsetY: 10 })
        }, (item: GalleryAnalysisResult) => item.id)
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder SkippedItemRow(item: GalleryScanItem) {
    Row() {
      Image(item.uri)
        .width(72)
        .height(72)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#F2F4F7')
        .borderRadius(10)
      Column() {
        Text(this.skippedReason(item))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#151A28')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.date)
          .fontSize(12)
          .fontColor('#7C8494')
          .margin({ top: 6 })
          .maxLines(1)
        Text(item.id)
          .fontSize(11)
          .fontColor('#9AA3B2')
          .margin({ top: 5 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F7F9FC')
    .borderRadius(14)
    .margin({ top: 10 })
  }

  @Builder SkippedItemsPanel() {
    if (this.skippedPanelOpen) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.closeSkippedPanel(); })

        Column() {
          Row() {
            Column() {
              Text('跳过图片')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor('#11182F')
                .maxLines(1)
              Text('OCR 关键词预筛未命中的图片会计入跳过')
                .fontSize(12)
                .fontColor('#717684')
                .margin({ top: 5 })
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ right: 12 })
            Text('关闭')
              .fontSize(13)
              .fontColor('#5B68FF')
              .onClick(() => { this.closeSkippedPanel(); })
          }
          .width('100%')

          Scroll() {
            Column() {
              ForEach(this.skippedPanelItems, (item: GalleryScanItem) => {
                this.SkippedItemRow(item)
              }, (item: GalleryScanItem, index: number) => item.id + '_' + item.date + '_' + index.toString() + '_' + this.skippedPanelRevision.toString())
              Blank().height(8)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 12 })
        }
        .width('88%')
        .height('72%')
        .padding(18)
        .backgroundColor(Color.White)
        .borderRadius(18)
        .shadow({ radius: 24, color: '#24000000', offsetX: 0, offsetY: 10 })
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder FilterChip(item: GalleryCategoryFilter) {
    Text(this.categoryChipText(item))
      .fontSize(13)
      .fontWeight(this.selectedFilter === item.index ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.selectedFilter === item.index ? Color.White : '#596071')
      .height(36)
      .padding({ left: 14, right: 14 })
      .textAlign(TextAlign.Center)
      .backgroundColor(this.selectedFilter === item.index ? '#5B68FF' : '#F1F4FA')
      .borderRadius(18)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.selectedFilter = item.index;
        this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
      })
  }

  private categoryLabel(category: string): string {
    let value = this.normalizeCategory(category);
    return value;
  }

  private categoryBg(category: string): string {
    let value = this.normalizeCategory(category);
    if (value === '餐饮') {
      return '#EAF8F3';
    }
    if (value === '出行') {
      return '#EAF1FF';
    }
    if (value === '购物') {
      return '#FFF1E7';
    }
    if (value === '健康') {
      return '#F0ECFF';
    }
    return '#EEF3FF';
  }

  private statusColor(status: string): string {
    let value = status ? status : '';
    if (value === 'ok' || value === '已入库') {
      return '#267A54';
    }
    if (value.indexOf('failed') === 0 || value.indexOf('失败') !== -1) {
      return '#B42318';
    }
    return '#667085';
  }

  private statusBg(status: string): string {
    let value = status ? status : '';
    if (value === 'ok' || value === '已入库') {
      return '#EAF8F3';
    }
    if (value.indexOf('failed') === 0 || value.indexOf('失败') !== -1) {
      return '#FDECEC';
    }
    return '#F2F4F7';
  }

  private tagAt(item: GalleryAnalysisResult, index: number): string {
    if (!item.tags || item.tags.length <= index) {
      return '';
    }
    let value = item.tags[index];
    if (!value) {
      return '';
    }
    return String(value);
  }

  private hasAnyDisplayTag(item: GalleryAnalysisResult): boolean {
    for (let i = 0; i < 3; i++) {
      if (this.tagAt(item, i).length > 0) {
        return true;
      }
    }
    return false;
  }

  private detailAt(item: GalleryAnalysisResult, index: number): string {
    if (!item.details || item.details.length <= index) {
      return '';
    }
    let value = item.details[index];
    if (!value) {
      return '';
    }
    return String(value);
  }

  private hasAnyDisplayDetail(item: GalleryAnalysisResult): boolean {
    for (let i = 0; i < 8; i++) {
      if (this.detailAt(item, i).length > 0) {
        return true;
      }
    }
    return false;
  }

  private selectedDetailItems(): GalleryAnalysisResult[] {
    if (this.selectedDetailId.length === 0) {
      return [];
    }
    for (let i = 0; i < this.results.length; i++) {
      if (this.results[i].id === this.selectedDetailId) {
        return [this.results[i]];
      }
    }
    return [];
  }

  private showResultDetail(item: GalleryAnalysisResult): void {
    this.selectedDetailId = item.id;
    this.resolveCaptureAddressLazy(item, false);
  }

  private closeResultDetail(): void {
    this.selectedDetailId = '';
  }

  private resultDetails(item: GalleryAnalysisResult): string[] {
    if (item.details) {
      return item.details;
    }
    return [];
  }

  private resultTags(item: GalleryAnalysisResult): string[] {
    if (item.tags) {
      return item.tags;
    }
    return [];
  }

  @Builder TagChip(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor('#596273')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      .backgroundColor('#F4F6FA')
      .borderRadius(7)
      .margin({ right: 6, top: 6 })
  }

  @Builder InsightDetailSlot(item: GalleryAnalysisResult, index: number) {
    if (this.detailAt(item, index).length > 0) {
      Text('· ' + this.detailAt(item, index))
        .fontSize(11)
        .fontColor('#667085')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: index === 0 ? 0 : 2 })
    }
  }

  @Builder InsightDetailSlots(item: GalleryAnalysisResult) {
    Column() {
      this.InsightDetailSlot(item, 0)
      this.InsightDetailSlot(item, 1)
      this.InsightDetailSlot(item, 2)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder InsightTagSlot(item: GalleryAnalysisResult, index: number) {
    if (this.tagAt(item, index).length > 0) {
      this.TagChip(this.tagAt(item, index))
    }
  }

  @Builder InsightTagSlots(item: GalleryAnalysisResult) {
    Row() {
      this.InsightTagSlot(item, 0)
      this.InsightTagSlot(item, 1)
      this.InsightTagSlot(item, 2)
    }
    .width('100%')
    .height(24)
  }

  @Builder InsightCard(item: GalleryAnalysisResult) {
    Row() {
      Image(this.previewUri(item))
        .width(92)
        .height(92)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column() {
        Row() {
          Text(item.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          AiGeneratedBadge({ compact: true })
            .margin({ left: 8, right: 8 })
          Text(this.categoryLabel(item.category))
            .fontSize(11)
            .fontColor(this.categoryColor(item.category))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(this.categoryBg(item.category))
            .borderRadius(8)
        }.width('100%')
        Text(item.summary)
          .fontSize(12)
          .fontColor('#596273')
          .margin({ top: 7 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.hasAnyDisplayDetail(item)) {
          this.InsightDetailSlots(item)
        }
        if (this.hasAnyDisplayTag(item)) {
          this.InsightTagSlots(item)
        }
        Row() {
          Text(this.resultTime(item))
            .fontSize(10)
            .fontColor('#858C99')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.resultStatus(item))
            .fontSize(10)
            .fontColor(this.statusColor(this.resultStatus(item)))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(this.statusBg(this.resultStatus(item)))
            .borderRadius(7)
            .maxLines(1)
        }.width('100%').margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .margin({ top: 10 })
    .onClick(() => { this.showResultDetail(item); })
  }

  private buildAnalyzerConfig(useOcrKeywordFilter: boolean): GalleryAnalyzerConfig {
    return {
      apiBaseUrl: this.galleryApiBaseUrl.trim().length > 0 ? this.galleryApiBaseUrl.trim() : DEFAULT_GALLERY_API_BASE_URL,
      apiKey: configuredEndpointSecretOrDefault(this.galleryApiKey, DEFAULT_GALLERY_API_KEY),
      model: this.galleryModel.trim().length > 0 ? this.galleryModel.trim() : DEFAULT_GALLERY_MODEL,
      amapWebKey: configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY),
      skipOcr: this.gallerySkipOcr === 'true',
      useOcrKeywordFilter: useOcrKeywordFilter && this.gallerySkipOcr !== 'true' && this.galleryUseOcrKeywordFilter === 'true',
      ocrConcurrency: parseInt(this.galleryOcrConcurrency),
      modelConcurrency: parseInt(this.galleryModelConcurrency),
      embeddingConcurrency: parseInt(this.galleryEmbeddingConcurrency),
      parallelFieldRequests: this.galleryParallelFieldRequests === 'true',
      embeddingMode: this.galleryEmbeddingMode === 'remote' ? 'remote' : 'huawei_local',
      embeddingBaseUrl: this.galleryEmbeddingBaseUrl.trim().length > 0 ? this.galleryEmbeddingBaseUrl.trim() : DEFAULT_GALLERY_EMBEDDING_BASE_URL,
      embeddingApiKey: configuredEndpointSecretOrDefault(this.galleryEmbeddingApiKey,
        DEFAULT_GALLERY_EMBEDDING_API_KEY),
      embeddingModel: this.galleryEmbeddingModel.trim().length > 0 ? this.galleryEmbeddingModel.trim() : DEFAULT_GALLERY_EMBEDDING_MODEL,
      imageScale: parseFloat(this.normalizeScale(this.galleryImageScale, DEFAULT_GALLERY_IMAGE_SCALE))
    };
  }

  private updateProgress(next: GalleryProgress): void {
    // 手动选择图片分析没有 scan-session baseline，直接采用分析器上报的本批次进度。
    let completed = Math.max(0, next.processed - next.failed);
    this.scanTotal = next.selected;
    this.scanProcessed = next.processed;
    this.scanPending = next.pending;
    this.scanSkipped = next.skipped;
    this.scanFailed = next.failed;
    this.progress = this.progressPercentFromUnits(completed, next.selected);
    this.progressRevision += 1;
  }

  private updateAutoProgress(session: GalleryScanSession, next?: GalleryProgress): void {
    // 自动全量分析会跨暂停恢复，必须用 session 的历史值加上本轮进度增量来实时刷新页面。
    this.recountScanSession(session);
    if (this.pauseRequested && session.status === 'running') {
      session.status = 'pausing';
    }
    this.scanTotal = session.total;
    if (next) {
      this.scanProcessed = Math.min(session.total, this.autoProgressBaselineProcessed + next.processed);
      this.scanSkipped = Math.min(this.scanProcessed, this.autoProgressBaselineSkipped + next.skipped);
      this.scanFailed = Math.min(this.scanProcessed, this.autoProgressBaselineFailed + next.failed);
    } else {
      this.scanProcessed = session.processed;
      this.scanSkipped = session.skipped;
      this.scanFailed = session.failed;
    }
    this.scanPending = Math.max(0, session.total - session.processed);
    if (next) {
      this.scanPending = Math.max(0, session.total - this.scanProcessed);
    }
    this.autoScanStatus = this.effectiveScanStatus(session.status);
    this.progress = this.progressPercentFromUnits(this.scanProcessed, session.total);
    // ArkUI 对复杂异步状态变化偶尔不会重建子 Builder，revision 用作显式刷新信号。
    this.scanRevision += 1;
    this.progressRevision += 1;
  }

  private clearManualProgressState(): void {
    this.scanTotal = 0;
    this.scanProcessed = 0;
    this.scanPending = 0;
    this.scanSkipped = 0;
    this.scanFailed = 0;
    this.progress = 0;
    this.progressRevision += 1;
  }

  private progressPercentFromUnits(doneUnits: number, totalUnits: number): number {
    if (totalUnits <= 0) {
      return 0;
    }
    let percent = doneUnits * 100 / totalUnits;
    if (percent < 0) {
      return 0;
    }
    if (percent > 100) {
      return 100;
    }
    return Math.round(percent * 100) / 100;
  }

  private progressPercentText(value: number): string {
    if (value >= 100) {
      return '100%';
    }
    if (value <= 0) {
      return '0%';
    }
    if (value < 10) {
      return value.toFixed(2) + '%';
    }
    return value.toFixed(1) + '%';
  }

  private progressFillWidth(value: number): string {
    if (value <= 0) {
      return '0%';
    }
    if (value >= 100) {
      return '100%';
    }
    if (value < 1) {
      return '1%';
    }
    return value.toFixed(2) + '%';
  }

  private analyzedCountText(): string {
    // 自动扫描中显示 scan-session 进度；普通浏览时显示已落盘结果数。
    if (this.scanTotal > 0 && (this.analyzing || this.hasPausedScan() || this.autoScanStatus === 'completed')) {
      return this.scanProcessed.toString() + '/' + this.scanTotal.toString() + ' 张';
    }
    return this.results.length.toString() + ' 张';
  }

  private categoryChipText(item: GalleryCategoryFilter): string {
    if (item.index === 0) {
      return item.label;
    }
    return item.label + ' ' + item.count.toString();
  }

  private categoryFilterItems(): GalleryCategoryFilter[] {
    // 分类标签按当前时间范围重新统计，只保留有结果的分类，避免空标签占位和横向滚动。
    let items = this.timeFilteredResults(this.results);
    let counts: Record<string, number> = {};
    for (let i = 0; i < items.length; i++) {
      let category = this.normalizeCategory(items[i].category);
      counts[category] = counts[category] ? counts[category] + 1 : 1;
    }
    let filters: GalleryCategoryFilter[] = [{
      index: 0,
      label: '全部',
      count: items.length
    }];
    for (let i = 1; i <= 8; i++) {
      let label = this.filterCategory(i);
      let count = counts[label] ? counts[label] : 0;
      if (count > 0) {
        filters.push({
          index: i,
          label: label,
          count: count
        });
      }
    }
    return filters;
  }

  private ensureSelectedFilterAvailable(): void {
    // 切换时间范围后，如果原分类在当前范围无结果，自动回退到“全部”。
    if (this.selectedFilter === 0) {
      return;
    }
    let target = this.filterCategory(this.selectedFilter);
    let items = this.timeFilteredResults(this.results);
    for (let i = 0; i < items.length; i++) {
      if (this.matchCategory(items[i].category, target)) {
        return;
      }
    }
    this.selectedFilter = 0;
    this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
  }

  private filteredResults(): GalleryAnalysisResult[] {
    let timeResults = this.timeFilteredResults(this.results);
    if (this.selectedFilter === 0) {
      return timeResults;
    }
    let target = this.filterCategory(this.selectedFilter);
    return timeResults.filter((item: GalleryAnalysisResult) => this.matchCategory(item.category, target));
  }

  private filterCategory(index: number): string {
    if (index === 1) {
      return '聊天';
    }
    if (index === 2) {
      return '文档';
    }
    if (index === 3) {
      return '餐饮';
    }
    if (index === 4) {
      return '购物';
    }
    if (index === 5) {
      return '出行';
    }
    if (index === 6) {
      return '健康';
    }
    if (index === 7) {
      return '工作';
    }
    return '其他';
  }

  private normalizeCategory(category: string): string {
    let value = category ? String(category).trim() : '';
    if (value === '聊天' || value === '文档' || value === '餐饮' || value === '购物' ||
      value === '出行' || value === '健康' || value === '工作') {
      return value;
    }
    return '其他';
  }

  private matchCategory(category: string, target: string): boolean {
    return this.normalizeCategory(category) === target;
  }

  private visibleResults(): GalleryAnalysisResult[] {
    let categoryResults = this.filteredResults();
    this.sortResultsByRecent(categoryResults);
    return categoryResults;
  }

  private timeFilteredResults(items: GalleryAnalysisResult[]): GalleryAnalysisResult[] {
    if (this.selectedTimeFilter === 0) {
      let result = items.slice(0);
      this.sortResultsByRecent(result);
      return result;
    }
    let now = new Date().getTime();
    let startTs = 0;
    if (this.selectedTimeFilter === 1) {
      startTs = now - 7 * 24 * 60 * 60 * 1000;
    } else if (this.selectedTimeFilter === 2) {
      startTs = now - 30 * 24 * 60 * 60 * 1000;
    } else {
      let yearStart = new Date(new Date().getFullYear(), 0, 1);
      startTs = yearStart.getTime();
    }
    let results = items.filter((item: GalleryAnalysisResult) => this.itemTime(item) >= startTs);
    this.sortResultsByRecent(results);
    return results;
  }

  private displayedResults(items: GalleryAnalysisResult[]): GalleryAnalysisResult[] {
    if (items.length <= this.resultDisplayLimit) {
      return items;
    }
    return items.slice(0, this.resultDisplayLimit);
  }

  private resultPanelCountText(): string {
    let visibleItems = this.visibleResults();
    let displayedCount = this.displayedResults(visibleItems).length;
    if (visibleItems.length === 0) {
      return '0 条可见';
    }
    if (displayedCount < visibleItems.length) {
      return visibleItems.length.toString() + ' 条可见 · 已显示 ' + displayedCount.toString() + '/' +
        visibleItems.length.toString() + ' 条';
    }
    return visibleItems.length.toString() + ' 条可见';
  }

  private itemTime(item: GalleryAnalysisResult): number {
    let dateText = item.date && item.date.length > 0 ? item.date : '';
    if (dateText.length >= 10) {
      let parsed = new Date(dateText + ' 00:00:00').getTime();
      if (!isNaN(parsed)) {
        return parsed;
      }
    }
    return item.createdAt;
  }

  private sortResultsByRecent(items: GalleryAnalysisResult[]): void {
    items.sort((left: GalleryAnalysisResult, right: GalleryAnalysisResult) => {
      let rightTime = this.itemTime(right);
      let leftTime = this.itemTime(left);
      if (rightTime !== leftTime) {
        return rightTime - leftTime;
      }
      return right.createdAt - left.createdAt;
    });
  }

  private shouldShowDateHeader(items: GalleryAnalysisResult[], index: number): boolean {
    if (index === 0) {
      return true;
    }
    return this.groupDate(items[index]) !== this.groupDate(items[index - 1]);
  }

  private groupDate(item: GalleryAnalysisResult): string {
    if (item.date && item.date.length >= 10) {
      return item.date.substring(0, 10);
    }
    return this.formatDate(item.createdAt);
  }

  private formatDate(ts: number): string {
    let date = new Date(ts);
    let y = date.getFullYear();
    let m = (date.getMonth() + 1).toString().padStart(2, '0');
    let d = date.getDate().toString().padStart(2, '0');
    return y + '-' + m + '-' + d;
  }

  private formatDateTime(ts: number): string {
    let date = new Date(ts);
    let hh = date.getHours().toString().padStart(2, '0');
    let mm = date.getMinutes().toString().padStart(2, '0');
    return this.formatDate(ts) + ' ' + hh + ':' + mm;
  }

  private categoryColor(category: string): string {
    let value = this.normalizeCategory(category);
    if (value === '餐饮') {
      return '#39BFA3';
    }
    if (value === '出行') {
      return '#4B8BFF';
    }
    if (value === '购物') {
      return '#FF8A3D';
    }
    if (value === '健康') {
      return '#765BFF';
    }
    return '#5B68FF';
  }

  private resultTime(item: GalleryAnalysisResult): string {
    let imageDate = item.date && item.date.length > 0 ? item.date : this.formatDate(item.createdAt);
    return imageDate + ' · 分析 ' + this.formatDateTime(item.createdAt);
  }

  private captureTimeText(item: GalleryAnalysisResult): string {
    if (!item.exif) {
      return '';
    }
    return GalleryExifUtils.displayDateTime(item.exif.dateTimeOriginal);
  }

  private captureDeviceText(item: GalleryAnalysisResult): string {
    return GalleryExifUtils.deviceText(item.exif);
  }

  private captureLocationText(item: GalleryAnalysisResult): string {
    let location = this.captureLocationValue(item);
    let directedLocation = GalleryExifUtils.directedLocationText(location.latitude, location.longitude);
    if (directedLocation.length > 0) {
      return directedLocation;
    }
    return GalleryExifUtils.rawGpsLocationText(item.exif);
  }

  private captureMapUrl(item: GalleryAnalysisResult): string {
    let location = this.captureMapLocationValue(item);
    return GalleryExifUtils.mapUrl(location.latitude, location.longitude);
  }

  private captureStaticMapUrl(item: GalleryAnalysisResult): string {
    let amapKey = configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY);
    if (amapKey.length === 0) {
      return '';
    }
    let record = this.captureLocationRecord(item);
    if (!record) {
      return '';
    }
    let latitude = Number(record.amapLatitude);
    let longitude = Number(record.amapLongitude);
    if (!GalleryExifUtils.isValidLocation(latitude, longitude)) {
      return '';
    }
    let coordinate = longitude.toFixed(6) + ',' + latitude.toFixed(6);
    return 'https://restapi.amap.com/v3/staticmap' +
      '?location=' + encodeURIComponent(coordinate) +
      '&zoom=16' +
      '&size=640*320' +
      '&markers=' + encodeURIComponent('large,0xF24A4A,A:' + coordinate) +
      '&key=' + encodeURIComponent(amapKey);
  }

  private openCaptureMap(item: GalleryAnalysisResult): void {
    let location = this.captureMapLocationValue(item);
    let latitude = Number(location.latitude);
    let longitude = Number(location.longitude);
    if (!GalleryExifUtils.isValidLocation(latitude, longitude)) {
      showToastSafely('没有可定位的经纬度', 1200);
      return;
    }
    let ctx = getContext(this) as common.UIAbilityContext;
    this.openExternalCaptureMap(ctx, {
      latitude: latitude,
      longitude: longitude
    });
  }

  private captureLocationRecord(item: GalleryAnalysisResult): GalleryLocationCacheRecord | undefined {
    if (item.location && (item.location.formattedAddress.length > 0 || item.location.poiName.length > 0)) {
      return item.location;
    }
    let key = this.captureLocationCacheKey(item);
    if (key.length === 0) {
      return undefined;
    }
    return this.locationCacheRecords[key];
  }

  private captureAddressText(item: GalleryAnalysisResult): string {
    let record = this.captureLocationRecord(item);
    if (!record) {
      return '';
    }
    if (record.formattedAddress && record.formattedAddress.length > 0) {
      return record.formattedAddress;
    }
    return record.poiName ? record.poiName : '';
  }

  private capturePoiText(item: GalleryAnalysisResult): string {
    let record = this.captureLocationRecord(item);
    if (!record || !record.poiName) {
      return '';
    }
    return record.poiName;
  }

  private captureLocationPreviewText(item: GalleryAnalysisResult): string {
    let key = this.captureLocationCacheKey(item);
    if (key.length === 0) {
      return '当前图片没有可用经纬度。';
    }
    if (this.captureLocationRecord(item)) {
      return '已使用高德 Web 服务解析并缓存。';
    }
    if (this.locationResolvingKey === key) {
      return '正在通过高德 Web 服务解析地址...';
    }
    if (this.locationResolveErrorKey === key && this.locationResolveErrorText.length > 0) {
      return '解析失败：' + this.locationResolveErrorText;
    }
    if (configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY).length === 0) {
      return '配置高德 Web 服务 Key 后，可按需解析具体地理位置。';
    }
    return '尚未解析具体地址，点击右侧按钮后会请求一次并写入本地缓存。';
  }

  private captureLocationActionText(item: GalleryAnalysisResult): string {
    if (configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY).length === 0) {
      return '配置';
    }
    let key = this.captureLocationCacheKey(item);
    if (key.length > 0 && this.locationResolvingKey === key) {
      return '解析中';
    }
    return this.captureLocationRecord(item) ? '重试' : '解析';
  }

  private captureLocationCacheKey(item: GalleryAnalysisResult): string {
    let rawLocation = this.captureRawLatLng(item);
    if (!rawLocation) {
      return '';
    }
    return GalleryStorage.locationCacheKey(Number(rawLocation.latitude), Number(rawLocation.longitude));
  }

  private async resolveCaptureAddressLazy(item: GalleryAnalysisResult, force: boolean): Promise<void> {
    let rawLocation = this.captureRawLatLng(item);
    if (!rawLocation) {
      return;
    }
    if (!force && item.location && (item.location.formattedAddress.length > 0 || item.location.poiName.length > 0)) {
      return;
    }
    let rawLatitude = Number(rawLocation.latitude);
    let rawLongitude = Number(rawLocation.longitude);
    let key = GalleryStorage.locationCacheKey(rawLatitude, rawLongitude);
    if (!force && this.locationCacheRecords[key]) {
      this.persistLocationToResult(item, this.locationCacheRecords[key]);
      return;
    }
    let amapKey = configuredEndpointSecretOrDefault(this.galleryAmapWebKey, DEFAULT_GALLERY_AMAP_WEB_KEY);
    if (amapKey.length === 0) {
      this.locationResolveRevision += 1;
      return;
    }
    if (this.locationResolvingKey === key) {
      return;
    }
    this.locationResolvingKey = key;
    this.locationResolveErrorKey = '';
    this.locationResolveErrorText = '';
    this.locationResolveRevision += 1;
    try {
      let record = await this.reverseGeocoder.reverse(rawLatitude, rawLongitude, amapKey);
      GalleryStorage.saveLocationCacheRecord(this.filesDir, record);
      let next: Record<string, GalleryLocationCacheRecord> = {};
      let keys = Object.keys(this.locationCacheRecords);
      for (let i = 0; i < keys.length; i++) {
        next[keys[i]] = this.locationCacheRecords[keys[i]];
      }
      next[record.key] = record;
      this.locationCacheRecords = next;
      this.persistLocationToResult(item, record);
    } catch (e) {
      this.locationResolveErrorKey = key;
      this.locationResolveErrorText = this.errorMessage(e);
      showToastSafely('地址解析失败：' + this.errorMessage(e), 1800);
    } finally {
      if (this.locationResolvingKey === key) {
        this.locationResolvingKey = '';
      }
      this.locationResolveRevision += 1;
    }
  }

  private persistLocationToResult(item: GalleryAnalysisResult, record: GalleryLocationCacheRecord): void {
    item.location = record;
    let normalized = GalleryStorage.writeResult(this.filesDir, item);
    this.mergeResult(normalized);
    this.locationResolveRevision += 1;
  }

  private captureMapLocationValue(item: GalleryAnalysisResult): GalleryCoordinate {
    let record = this.captureLocationRecord(item);
    if (record) {
      return {
        latitude: record.amapLatitude,
        longitude: record.amapLongitude
      };
    }
    return this.captureLocationValue(item);
  }

  private captureRawLatLng(item: GalleryAnalysisResult): GalleryCoordinate | undefined {
    let location = this.captureLocationValue(item);
    let latitude = Number(location.latitude);
    let longitude = Number(location.longitude);
    if (!GalleryExifUtils.isValidLocation(latitude, longitude)) {
      return undefined;
    }
    return {
      latitude: latitude,
      longitude: longitude
    };
  }

  private openExternalCaptureMap(ctx: common.UIAbilityContext, location: GalleryCoordinate): void {
    if (!location) {
      showToastSafely('无法生成地图链接', 1200);
      return;
    }
    let mapUrl = GalleryExifUtils.mapUrl(location.latitude, location.longitude);
    if (mapUrl.length === 0) {
      showToastSafely('无法生成地图链接', 1200);
      return;
    }
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: mapUrl
    }).catch((e: BusinessError) => {
      AppLogger.warnCause('Gallery.Location', 'open external capture map failed', e);
      showToastSafely('无法打开地图链接', 1600);
    });
  }

  private captureLocationValue(item: GalleryAnalysisResult): GalleryCoordinate {
    let latitude = item.latitude;
    let longitude = item.longitude;
    if (latitude === undefined && item.exif && item.exif.latitude !== undefined) {
      latitude = item.exif.latitude;
    }
    if (longitude === undefined && item.exif && item.exif.longitude !== undefined) {
      longitude = item.exif.longitude;
    }
    return {
      latitude: latitude,
      longitude: longitude
    };
  }

  private captureSizeText(item: GalleryAnalysisResult): string {
    if (!item.exif) {
      return '';
    }
    let width = GalleryExifUtils.cleanProperty(item.exif.imageWidth);
    let height = GalleryExifUtils.cleanProperty(item.exif.imageHeight);
    if (width.length > 0 && height.length > 0) {
      return width + ' x ' + height;
    }
    return '';
  }

  private resultStatus(item: GalleryAnalysisResult): string {
    if (item.error && item.error.length > 0) {
      return '分析失败';
    }
    if (item.rawModelText && item.rawModelText.trim().length > 0) {
      return '已入库';
    }
    return '未入库';
  }

  private previewUri(item: GalleryAnalysisResult): string {
    return item.uri;
  }

  private monthlyCategoryColor(label: string): string {
    let colors = ['#4B8BFF', '#39BFA3', '#FF8A3D', '#765BFF', '#D14B7A', '#667085'];
    return colors[this.monthlyTagColorIndex(label)];
  }

  private monthlyCategoryBg(label: string): string {
    let colors = ['#EAF1FF', '#EAF8F3', '#FFF1E7', '#F0ECFF', '#FCECF3', '#F2F4F7'];
    return colors[this.monthlyTagColorIndex(label)];
  }

  private monthlyTagColorIndex(label: string): number {
    let hash = 0;
    let text = label && label.length > 0 ? label : 'tag';
    for (let i = 0; i < text.length; i++) {
      hash = (hash + text.charCodeAt(i)) % 6;
    }
    return hash;
  }

  private monthlyCategoryPercent(count: number, total: number): string {
    if (total <= 0) {
      return '0%';
    }
    let percent = Math.floor(count * 100 / total);
    if (percent < 6 && count > 0) {
      percent = 6;
    }
    return percent.toString() + '%';
  }

  @Builder MonthChip(insight: GalleryMonthlyInsight) {
    Column() {
      Text(insight.label)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.selectedMonthKey === insight.key ? Color.White : '#4C5260')
        .maxLines(1)
      Text(insight.totalCount.toString() + ' 张')
        .fontSize(11)
        .fontColor(this.selectedMonthKey === insight.key ? '#EAF1FF' : '#7C8494')
        .margin({ top: 3 })
        .maxLines(1)
    }
    .justifyContent(FlexAlign.Center)
    .height(48)
    .padding({ left: 13, right: 13 })
    .backgroundColor(this.selectedMonthKey === insight.key ? '#4B8BFF' : '#F1F4FA')
    .borderRadius(12)
    .margin({ right: 8 })
    .onClick(() => {
      this.selectedMonthKey = insight.key;
    })
  }

  @Builder MonthlyCategoryBar(item: GalleryMonthlyCategoryCount, total: number) {
    Column() {
      Row() {
        Text(item.label)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2F3645')
          .layoutWeight(1)
          .maxLines(1)
        Text(item.count.toString() + ' 张')
          .fontSize(12)
          .fontColor('#7C8494')
          .maxLines(1)
      }.width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(7)
          .backgroundColor('#EEF0F5')
          .borderRadius(4)
        Row()
          .width(this.monthlyCategoryPercent(item.count, total))
          .height(7)
          .backgroundColor(this.monthlyCategoryColor(item.label))
          .borderRadius(4)
      }
      .width('100%')
      .height(7)
      .margin({ top: 5 })
    }
    .width('100%')
    .margin({ top: 9 })
  }

  @Builder MonthlyCategoryChip(item: GalleryMonthlyCategoryCount) {
    Text(item.label + ' ' + item.count.toString())
      .fontSize(11)
      .fontColor(this.monthlyCategoryColor(item.label))
      .fontWeight(FontWeight.Bold)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor(this.monthlyCategoryBg(item.label))
      .borderRadius(8)
      .margin({ right: 7, top: 7 })
      .constraintSize({ maxWidth: 132 })
  }

  @Builder MonthlyRepresentativeImage(item: GalleryAnalysisResult) {
    Image(this.previewUri(item))
      .width(64)
      .height(64)
      .objectFit(ImageFit.Cover)
      .borderRadius(8)
      .margin({ right: 8 })
      .onClick(() => { this.showResultDetail(item); })
  }

  @Builder MonthlyInsightsPanel(revision: number) {
    if (this.monthlyInsights().length > 0) {
      Column() {
        Row() {
          Text('月度洞察').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#11182F').layoutWeight(1)
          AiGeneratedBadge({ compact: true })
            .margin({ right: 8 })
          Text(this.monthlyInsights().length.toString() + ' 个月').fontSize(13).fontColor('#7F8592')
        }.width('100%')
        Scroll() {
          Row() {
            ForEach(this.monthlyInsights(), (insight: GalleryMonthlyInsight) => {
              this.MonthChip(insight)
            }, (insight: GalleryMonthlyInsight) => revision.toString() + '_' + insight.key)
          }
        }
        .width('100%')
        .height(56)
        .scrollable(ScrollDirection.Horizontal)
        .margin({ top: 12 })

        ForEach(this.selectedMonthlyInsightList(), (insight: GalleryMonthlyInsight) => {
          this.MonthlyInsightDetail(insight, revision)
        }, (insight: GalleryMonthlyInsight) => revision.toString() + '_' + insight.key + '_detail')
      }
      .width('86%')
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(18)
      .margin({ top: 18 })
    }
  }

  @Builder MonthlyInsightDetail(insight: GalleryMonthlyInsight, revision: number) {
    Column() {
      Row() {
        Column() {
          Text(this.monthlyTitle(insight))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(insight.totalCount.toString() + ' 张分析结果')
            .fontSize(12)
            .fontColor('#7C8494')
            .margin({ top: 3 })
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ right: 10 })
        Button(this.monthlyAiButtonText(insight))
          .height(34)
          .width(74)
          .fontSize(12)
          .fontColor('#4B8BFF')
          .backgroundColor('#EEF4FF')
          .borderRadius(10)
          .enabled(this.monthlyAiLoadingKey.length === 0)
          .onClick(() => {
            this.generateAiMonthlySummary(insight);
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Text(this.monthlySummaryText(insight))
        .fontSize(13)
        .fontColor('#596273')
        .lineHeight(20)
        .margin({ top: 10 })
        .width('100%')
        .maxLines(8)

      if (this.monthlySuggestionText(insight).length > 0) {
        Text('整理建议：' + this.monthlySuggestionText(insight))
          .fontSize(12)
          .fontColor('#4B5F9F')
          .lineHeight(18)
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor('#F2F6FF')
          .borderRadius(10)
          .margin({ top: 10 })
          .width('100%')
          .maxLines(5)
      }

      if (this.monthlyAiError(insight).length > 0) {
        Text('AI 总结失败：' + this.monthlyAiError(insight))
          .fontSize(12)
          .fontColor('#B42318')
          .margin({ top: 8 })
          .width('100%')
      }

      ForEach(insight.categoryCounts.slice(0, Math.min(4, insight.categoryCounts.length)),
        (item: GalleryMonthlyCategoryCount) => {
          this.MonthlyCategoryBar(item, insight.totalCount)
        }, (item: GalleryMonthlyCategoryCount) => revision.toString() + '_' + insight.key + '_bar_' + item.label)

      Scroll() {
        Row() {
          ForEach(insight.representativeItems, (item: GalleryAnalysisResult) => {
            this.MonthlyRepresentativeImage(item)
          }, (item: GalleryAnalysisResult) => revision.toString() + '_' + insight.key + '_img_' + item.id)
        }
      }
      .width('100%')
      .height(72)
      .scrollable(ScrollDirection.Horizontal)
      .margin({ top: 12 })

      Scroll() {
        Row() {
          ForEach(insight.categoryCounts.slice(0, Math.min(6, insight.categoryCounts.length)),
            (item: GalleryMonthlyCategoryCount) => {
              this.MonthlyCategoryChip(item)
            }, (item: GalleryMonthlyCategoryCount) => revision.toString() + '_' + insight.key + '_chip_' + item.label)
        }
      }
      .width('100%')
      .height(34)
      .scrollable(ScrollDirection.Horizontal)
      .margin({ top: 2 })
    }
    .width('100%')
  }

  @Builder GallerySearchHitCard(hit: GallerySearchHit) {
    Row() {
      Image(this.previewUri(hit.item))
        .width(64)
        .height(64)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column() {
        Row() {
          Text(hit.item.title)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.categoryLabel(hit.item.category))
            .fontSize(10)
            .fontColor(this.categoryColor(hit.item.category))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(this.categoryBg(hit.item.category))
            .borderRadius(7)
        }.width('100%')
        Text(hit.item.summary)
          .fontSize(11)
          .fontColor('#596273')
          .margin({ top: 5 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(hit.reason)
            .fontSize(10)
            .fontColor('#4B5F9F')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.groupDate(hit.item))
            .fontSize(10)
            .fontColor('#8A92A3')
            .margin({ left: 8 })
            .maxLines(1)
        }.width('100%').margin({ top: 5 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F8FAFE')
    .borderRadius(12)
    .margin({ top: 8 })
    .onClick(() => { this.showResultDetail(hit.item); })
  }

  @Builder GalleryQuestionPanel(revision: number) {
    Column() {
      Text(revision.toString()).fontSize(0).width(0).height(0).opacity(0)
      Row() {
        Column() {
          Text('图库问答').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#11182F')
          Text(this.gallerySearchMessage).fontSize(12).fontColor('#7F8592').margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }.width('100%')
      Row() {
        TextInput({ placeholder: '例如：找一下外卖订单、停车缴费、会议安排', text: this.galleryQuestion })
          .height(42)
          .layoutWeight(1)
          .fontSize(12)
          .backgroundColor('#F7F9FE')
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => { this.galleryQuestion = value; })
        Button('检索')
          .width(64)
          .height(42)
          .fontSize(12)
          .backgroundColor('#5B68FF')
          .borderRadius(12)
          .margin({ left: 8 })
          .onClick(() => { this.runGalleryKeywordSearch(); })
        Button(this.galleryAnswerLoading ? '生成中' : '问答')
          .width(70)
          .height(42)
          .fontSize(12)
          .backgroundColor('#2F5BEA')
          .borderRadius(12)
          .margin({ left: 8 })
          .enabled(!this.galleryAnswerLoading)
          .onClick(() => { this.runGalleryQuestionAnswer(); })
      }
      .width('100%')
      .margin({ top: 12 })
      Row() {
        Text('关键词检索').fontSize(11).fontColor('#8A92A3').layoutWeight(1)
        if (this.galleryQuestion.length > 0 || this.gallerySearchHits.length > 0) {
          Text('清空')
            .fontSize(12)
            .fontColor('#5B68FF')
            .onClick(() => { this.clearGalleryQuestion(); })
        }
      }
      .width('100%')
      .margin({ top: 8 })
      if (this.galleryAnswerLoading) {
        Text('正在基于检索结果生成回答...')
          .fontSize(12)
          .fontColor('#667085')
          .width('100%')
          .padding(10)
          .backgroundColor('#F7F9FC')
          .borderRadius(10)
          .margin({ top: 10 })
      }
      if (this.galleryAnswerText.length > 0) {
        Column() {
          AiGeneratedBadge({ compact: true })
            .margin({ bottom: 7 })
          Text(this.galleryAnswerText)
            .fontSize(13)
            .fontColor('#303746')
            .lineHeight(20)
            .width('100%')
          if (this.galleryAnswerMeta.length > 0) {
            Text(this.galleryAnswerMeta)
              .fontSize(11)
              .fontColor('#7F8592')
              .margin({ top: 6 })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
        .backgroundColor('#F2F6FF')
        .borderRadius(12)
        .margin({ top: 10 })
      }
      if (this.galleryAnswerError.length > 0) {
        Text('问答失败：' + this.galleryAnswerError)
          .fontSize(12)
          .fontColor('#B42318')
          .width('100%')
          .margin({ top: 8 })
      }
      if (this.gallerySearchHits.length > 0) {
        ForEach(this.gallerySearchHits, (hit: GallerySearchHit) => {
          this.GallerySearchHitCard(hit)
        }, (hit: GallerySearchHit) => revision.toString() + '_' + hit.item.id)
      }
    }
    .width('90%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .margin({ top: 14 })
  }

  @Builder TimeFilterChip(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.selectedTimeFilter === index ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.selectedTimeFilter === index ? '#151A28' : '#596071')
      .height(34)
      .padding({ left: 12, right: 12 })
      .textAlign(TextAlign.Center)
      .backgroundColor(this.selectedTimeFilter === index ? '#E8EEFF' : '#F1F4FA')
      .borderRadius(17)
      .margin({ right: 8 })
      .onClick(() => {
        this.selectedTimeFilter = index;
        this.ensureSelectedFilterAvailable();
        this.resultDisplayLimit = GALLERY_RESULT_PAGE_SIZE;
      })
  }

  @Builder ResultsPanel(revision: number) {
    Column() {
      Row() {
        Column() {
          Text('图库结果').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#11182F')
          Text(this.resultPanelCountText()).fontSize(12).fontColor('#7F8592').margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        AiGeneratedBadge({ compact: true })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.categoryFilterItems(), (item: GalleryCategoryFilter) => {
          this.FilterChip(item)
        }, (item: GalleryCategoryFilter) => revision.toString() + '_' + item.index.toString() + '_' + item.count.toString())
      }
      .width('100%')
      .margin({ top: 12 })
      Scroll() {
        Row() {
          this.TimeFilterChip('全部时间', 0)
          this.TimeFilterChip('近7天', 1)
          this.TimeFilterChip('近30天', 2)
          this.TimeFilterChip('今年', 3)
        }
      }
      .width('100%')
      .height(38)
      .scrollable(ScrollDirection.Horizontal)
      .margin({ top: 4 })
      ForEach(this.displayedResults(this.visibleResults()), (item: GalleryAnalysisResult, index: number) => {
        if (this.shouldShowDateHeader(this.displayedResults(this.visibleResults()), index)) {
          Row() {
            Text(this.groupDate(item)).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#4C5260').layoutWeight(1)
          }
          .width('100%')
          .height(28)
          .margin({ top: index === 0 ? 6 : 14 })
        }
        this.InsightCard(item)
      }, (item: GalleryAnalysisResult) => revision.toString() + '_' + item.id)
      if (this.visibleResults().length === 0) {
        Column() {
          Text(this.results.length === 0 ? '暂无图库分析结果' : '当前筛选无结果')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#303746')
          Text(this.results.length === 0 ? '选择图片或启动全库分析后，这里会展示图片洞察。' : '换一个分类或时间范围看看。')
            .fontSize(12)
            .fontColor('#7B8393')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ top: 28, bottom: 24, left: 18, right: 18 })
        .backgroundColor('#F7F9FC')
        .borderRadius(12)
        .margin({ top: 16 })
      }
      if (this.visibleResults().length > this.resultDisplayLimit) {
        Button('加载更多')
          .height(40)
          .width('100%')
          .fontSize(13)
          .fontColor('#4F68FF')
          .backgroundColor('#EEF4FF')
          .borderRadius(12)
          .margin({ top: 12 })
          .onClick(() => { this.resultDisplayLimit += GALLERY_RESULT_PAGE_SIZE; })
      }
    }
    .width('90%')
    .padding(14)
    .backgroundColor('#F2F5FA')
    .borderRadius(12)
    .margin({ top: 14 })
  }

  private errorMessage(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  build() {
    Stack() {
      Scroll() {
      Column() {
        Row() {
          this.HeaderIconButton('<', 0)
          Column() {
            Text('图库分析').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#11182F').maxLines(1)
            Text('相册、截图与文档图片洞察').fontSize(13).fontColor('#717684').margin({ top: 3 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 })
          this.HeaderIconButton('⚙', 1)
        }
        .width('90%')
        .margin({ top: 24 })

        this.ActionToolbar()
        if (this.shouldShowProgressStrip()) {
          this.ProgressStrip()
        }
        this.MonthlyInsightsPanel(this.resultRevision)
        this.GalleryQuestionPanel(this.gallerySearchRevision + this.resultRevision)
        this.ResultsPanel(this.resultRevision)

        Blank().height(100)
      }.width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F6F7FA')

      this.SettingsPanel()
      this.ResultDetailPanel()
      this.SkippedItemsPanel()
    }
    .width('100%')
    .height('100%')
  }
}
