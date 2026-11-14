import { AppTheme } from '../../utils/AppTheme';
import { StartupSourceSync, STARTUP_SOURCE_SYNC_ENABLED_KEY } from '../../utils/StartupSourceSync';
import { CalendarMemoryPanel } from '../../components/CalendarMemoryPanel';
import { MailSettingsPanel } from '../../components/MailSettingsPanel';
import { FrostedPage } from '../../components/FrostedPage';
import { FrameCallback, promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { DEFAULT_ENDPOINT_CONFIG } from '../../config/DefaultEndpointConfig';
import { CloudModelConfig } from '../../utils/CloudModelClient';
import { defaultChatCloudConfig } from '../../utils/ChatCloudConfig';
import {
  cloudSettingValuesDiffer, cloudSettingsUseSeparateValues, sharedCloudSettingEditorValue, updateUnifiedCloudSetting
} from '../../utils/CloudSettingsConfig';
import { DEFAULT_MODELSCOPE_MNN_REPO } from '../../config/ModelDownloadConfig';
import { createLocalModelRecommendation, LocalModelRecommendation, normalizeLocalModelRepo } from '../../utils/LocalModelRecommendation';
import { ModelSettingsField } from './ModelSettingsField';
import {
  CHAT_CONTEXT_COMPRESSION_THRESHOLD_PERCENT_DEFAULT,
  CHAT_CONTEXT_RECENT_ROUNDS_DEFAULT,
  normalizeChatContextCompressionThresholdPercent,
  normalizeChatContextRecentRounds
} from '../chat/ChatContextBudget';
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
  GALLERY_API_BASE_URL_DEFAULT_SNAPSHOT,
  GALLERY_API_KEY_DEFAULT_SNAPSHOT,
  GALLERY_EMBEDDING_API_KEY_DEFAULT_SNAPSHOT,
  GALLERY_MODEL_DEFAULT_SNAPSHOT,
  galleryApiUsesLegacyDefaults,
  registerGallerySettingsDefaults
} from '../../utils/gallery/GallerySettingsDefaults';
import {
  hiddenDefaultSettingEditorValue,
  hiddenDefaultSettingPlaceholder,
  migrateDefaultSettingValue
} from '../../utils/DefaultSettingVisibility';
import { showToastSafely } from '../../utils/PromptSafe';
import { DEBUG_ENABLED_STORAGE_KEY, DebugSettings } from '../../utils/DebugSettings';
import {
  MIMO_CHINESE_VOICE_PRESETS,
  VOICE_TTS_ROLE_PRESETS,
  VoiceTtsRolePreset,
  VoiceTtsRoleSelection,
  VoiceTtsVoicePreset,
  voiceTtsSelectionFromRolePreset
} from '../../utils/voice/VoiceTtsPresets';
import {
  DEFAULT_WECHAT_AUTO_SUMMARY_DAYS,
  DEFAULT_WECHAT_AUTO_SUMMARY_ENABLED,
  DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO,
  DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS,
  DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES,
  DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES,
  DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED,
  DEFAULT_WECHAT_AUTO_SUMMARY_WAIT,
  normalizeWechatAutoSummaryDays,
  normalizeWechatAutoSummaryHistorySwipeRatio,
  normalizeWechatAutoSummaryMaxContacts,
  normalizeWechatAutoSummaryMaxHistorySwipes,
  normalizeWechatAutoSummaryStableSwipes,
  normalizeWechatAutoSummarySwipeSpeed,
  normalizeWechatAutoSummaryWait
} from '../../utils/wechat/WechatAutoSummaryTypes';
import {
  DownloadedModelItem,
  isSettingsSectionSelected,
  normalizeSettingsSectionId,
  restoreMaskedSensitiveSettingDefault,
  SETTINGS_SECTION_ITEMS,
  SETTINGS_SECTION_NONE,
  SettingsActionKind,
  SettingsConfirmConfig,
  SettingsSectionItem,
  SettingsSectionId,
  SettingsScrollTarget,
  settingsSectionSubtitle,
  settingsSectionTitle,
  settingsParentSection
} from './SettingsCenterTypes';
import {
  SETTINGS_BUTTON_HEIGHT,
  SETTINGS_CONTROL_RADIUS,
  SETTINGS_FIELD_HEIGHT,
  SETTINGS_INPUT_BACKGROUND_COLOR,
  SETTINGS_MUTED_TEXT_COLOR,
  SETTINGS_PAGE_BACKGROUND_COLOR,
  SETTINGS_PAGE_HORIZONTAL_PADDING,
  SETTINGS_SECONDARY_TEXT_COLOR,
  settingsActionColor
} from './SettingsCenterTheme';
import {
  SensitiveSettingInput,
  SettingInput,
  SettingsActionButton,
  SettingsActionRow,
  SettingsGroupCard,
  SettingsNavigationRow,
  SettingsListDivider,
  SettingsOutputPanel,
  SettingToggle as SettingToggleControl
} from './SettingsCenterControls';
import { CollectionFormGroup, CollectionFormDivider, CollectionFormInput, CollectionFormSwitch,
  CollectionFormAction, CollectionSourceRow } from '../../components/CollectionFormControls';
import { HuaweiAccountCard } from './HuaweiAccountCard';
import { HUAWEI_ACCOUNT_SESSION_KEY } from '../../utils/AiServiceAccess';
import { PRIVACY_STATE_KEY } from '../../utils/PrivacyConsent';
import { HuaweiPrivacyAccess } from '../../utils/HuaweiPrivacyAccess';
import { PERSONAL_MEMORY_A2A_STATE_KEY, PersonalMemoryAccess } from '../../agent/PersonalMemoryAccess';

registerGallerySettingsDefaults();

const LEGACY_MIMO_TTS_BASE_URL = 'https://api.xiaomimimo.com';

class SettingsScrollFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.action(); }
}

@Component
export struct SettingsCenterPage {
  private pageScroller: Scroller = new Scroller();
  @StorageProp(DEBUG_ENABLED_STORAGE_KEY) @Watch('onDebugSettingChanged') private debugEnabled: boolean = false;
  @State private debugSwitchValue: boolean = false;
  @StorageProp(PRIVACY_STATE_KEY) privacyConsentState: string = 'unselected';
  @Link autoConfirm: boolean;
  @Link cloudAutoConfirm: boolean;
  @Link threadNumInput: string;
  @Prop localNpuExecutionMode: string = 'cpu';
  @Link @Watch('onSelectedSectionChanged') selectedSectionId: number;
  @Link @Watch('onScrollTargetChanged') scrollTarget: number;
  private detailScrollRevision: number = 0;
  onBackRequest: () => boolean = (): boolean => false;
  @Link output: string;
  @Link chunkOmCacheOutput: string;
  @Link cloudOutput: string;
  @Link modelDownloadProgressVisible: boolean;
  @Link modelDownloadProgressPercent: number;
  @Link modelDownloadProgressText: string;
  @Link modelDownloadProgressTitle: string;
  @Link downloading: boolean;
  @Link modelScopeDownloading: boolean;
  @Link modelScopePauseRequested: boolean;
  @Prop hdcAutoStatus: string = '';
  @Prop hdcAutoConnected: boolean = false;
  @Prop hdcAutoConnecting: boolean = false;
  @Prop hdcManualPairing: boolean = false;
  @Prop downloadedModels: DownloadedModelItem[] = [];
  @Prop selectedModelId: string = '';
  @Prop localModelRecommendation: LocalModelRecommendation = createLocalModelRecommendation('', []);
  @StorageLink('modelScopeMnnRepo') modelScopeMnnRepo: string = DEFAULT_MODELSCOPE_MNN_REPO;
  @StorageLink('customModelScopeMnnRepo') private customModelScopeMnnRepo: string = '';
  @State private modelCacheExpanded: boolean = false;
  @StorageLink('hdcServerIp') hdcServerIp: string = DEFAULT_ENDPOINT_CONFIG.hdcServerUrl;
  @StorageLink('manualHdcServerIp') manualHdcServerIp: string = '';
  @StorageLink('wirelessIp') wirelessIp: string = DEFAULT_ENDPOINT_CONFIG.wirelessHdcTarget;
  @StorageLink('cloudPlannerBaseUrl') cloudPlannerBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl;
  @StorageLink('cloudPlannerModel') cloudPlannerModel: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel;
  @StorageLink('cloudPlannerApiKey') cloudPlannerApiKey: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey;
  @StorageLink('cloudDeciderBaseUrl') cloudDeciderBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl;
  @StorageLink('cloudDeciderApiKey') cloudDeciderApiKey: string = DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey;
  @StorageLink('cloudApiKey') cloudApiKey: string = DEFAULT_ENDPOINT_CONFIG.cloudApiKey;
  @StorageLink('cloudDeciderModel') cloudDeciderModel: string = DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel;
  @StorageLink('voiceTtsBaseUrl') voiceTtsBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsBaseUrl;
  @StorageLink('voiceTtsApiKey') voiceTtsApiKey: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsApiKey;
  @StorageLink('voiceTtsModel') voiceTtsModel: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsModel;
  @StorageLink('voiceTtsVoice') voiceTtsVoice: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsVoice;
  @StorageLink('voiceTtsStylePrompt') voiceTtsStylePrompt: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsStylePrompt;
  @StorageLink('voiceTtsRolePreset') voiceTtsRolePreset: string = DEFAULT_ENDPOINT_CONFIG.voiceTtsRolePreset;
  @StorageLink('voiceTtsStreamingEnabled') voiceTtsStreamingEnabled: boolean =
    DEFAULT_ENDPOINT_CONFIG.voiceTtsStreamingEnabled;
  @StorageLink('chatContextCompressionThresholdPercent') chatContextCompressionThresholdPercent: string =
    String(CHAT_CONTEXT_COMPRESSION_THRESHOLD_PERCENT_DEFAULT);
  @StorageLink('chatContextRecentRounds') chatContextRecentRounds: string =
    String(CHAT_CONTEXT_RECENT_ROUNDS_DEFAULT);
  @StorageLink('avatarImageBaseUrl') avatarImageBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl;
  @StorageLink('avatarImageApiKey') avatarImageApiKey: string = DEFAULT_ENDPOINT_CONFIG.avatarImageApiKey;
  @StorageLink('avatarTextToImageModel') avatarTextToImageModel: string = DEFAULT_ENDPOINT_CONFIG.avatarImageModel;
  @StorageLink('avatarImageToImageModel') avatarImageToImageModel: string = DEFAULT_ENDPOINT_CONFIG.avatarImageModel;
  @StorageLink('avatarImageSize') avatarImageSize: string = DEFAULT_ENDPOINT_CONFIG.avatarImageSize;
  @StorageLink('galleryApiBaseUrl') galleryApiBaseUrl: string = DEFAULT_GALLERY_API_BASE_URL;
  @StorageLink('galleryApiKey') galleryApiKey: string = DEFAULT_GALLERY_API_KEY;
  @StorageLink('galleryModel') galleryModel: string = DEFAULT_GALLERY_MODEL;
  @StorageLink('gallerySkipOcr') gallerySkipOcr: string = DEFAULT_GALLERY_SKIP_OCR;
  @StorageLink('galleryUseOcrKeywordFilter') galleryUseOcrKeywordFilter: string = DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER;
  @StorageLink('galleryParallelFieldRequests') galleryParallelFieldRequests: string = DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS;
  @StorageLink('galleryOcrConcurrency') galleryOcrConcurrency: string = DEFAULT_GALLERY_OCR_CONCURRENCY;
  @StorageLink('galleryModelConcurrency') galleryModelConcurrency: string = DEFAULT_GALLERY_MODEL_CONCURRENCY;
  @StorageLink('galleryEmbeddingConcurrency') galleryEmbeddingConcurrency: string = DEFAULT_GALLERY_EMBEDDING_CONCURRENCY;
  @StorageLink('galleryEmbeddingMode') galleryEmbeddingMode: string = DEFAULT_GALLERY_EMBEDDING_MODE;
  @StorageLink('galleryEmbeddingBaseUrl') galleryEmbeddingBaseUrl: string = DEFAULT_GALLERY_EMBEDDING_BASE_URL;
  @StorageLink('galleryEmbeddingApiKey') galleryEmbeddingApiKey: string = DEFAULT_GALLERY_EMBEDDING_API_KEY;
  @StorageLink('galleryEmbeddingModel') galleryEmbeddingModel: string = DEFAULT_GALLERY_EMBEDDING_MODEL;
  @StorageLink('galleryImageScale') galleryImageScale: string = DEFAULT_GALLERY_IMAGE_SCALE;
  @StorageLink('galleryAmapWebKey') galleryAmapWebKey: string = DEFAULT_GALLERY_AMAP_WEB_KEY;
  @StorageLink('wechatAutoSummaryEnabled') wechatAutoSummaryEnabled: string = DEFAULT_WECHAT_AUTO_SUMMARY_ENABLED;
  @StorageLink('wechatAutoSummaryDefaultDays') wechatAutoSummaryDefaultDays: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_DAYS;
  @StorageLink('wechatAutoSummaryDefaultMaxContacts') wechatAutoSummaryDefaultMaxContacts: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS;
  @StorageLink('wechatAutoSummarySwipeSpeed') wechatAutoSummarySwipeSpeed: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED;
  @StorageLink('wechatAutoSummaryHistorySwipeRatio') wechatAutoSummaryHistorySwipeRatio: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO;
  @StorageLink('wechatAutoSummaryStableSwipes') wechatAutoSummaryStableSwipes: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES;
  @StorageLink('wechatAutoSummaryMaxHistorySwipes') wechatAutoSummaryMaxHistorySwipes: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES;
  @StorageLink('wechatAutoSummaryWait') wechatAutoSummaryWait: string = DEFAULT_WECHAT_AUTO_SUMMARY_WAIT;
  @State private wechatAutoSummaryAdvancedOpen: boolean = false;
  @State private activeSensitiveInputId: string = '';
  @StorageLink(PERSONAL_MEMORY_A2A_STATE_KEY) private personalMemoryA2aEnabled: boolean = false;
  @StorageLink(HUAWEI_ACCOUNT_SESSION_KEY) private huaweiAccountSessionActive: boolean = false;
  private detailScroller: Scroller = new Scroller();
  @State private voiceTtsStylePromptEditorRevision: number = 0;
  onDownloadModelScopeModel: () => Promise<void> = async () => {};
  onUseRecommendedLocalModel: () => Promise<void> = async () => {};
  onPauseModelScopeDownload: () => void = () => {};
  onUpdateConfigThreadNum: () => void = () => {};
  onShowConfigJson: () => void = () => {};
  onDiscoverHdc: () => Promise<void> = async () => {};
  onSetHdcManualPairing: () => void = () => {};
  onMarkHdcManualEditing: () => void = () => {};
  onTestAndConnectHdc: () => Promise<void> = async () => {};
  onTestCloudPlanner: () => Promise<void> = async () => {};
  onStartCloudBackend: () => Promise<void> = async () => {};
  onClearScreenshots: () => void = () => {};
  onDeleteDebugOutputs: () => void = () => {};
  onSwitchDownloadedModel: (modelId: string) => void = (modelId: string) => {};
  onDeleteDownloadedModel: (modelId: string) => void = (modelId: string) => {};
  onRefreshDownloadedModels: () => void = () => {};
  @Prop calendarMemoryRefreshing: boolean = false;
  @Prop calendarSourceSyncReady: boolean = false;
  @Prop mailSourceSyncReady: boolean = false;
  @Prop sourceSyncPending: string = '';
  onQuickSyncCalendar: () => void = (): void => {};
  onQuickSyncMail: () => void = (): void => {};
  onSyncCalendarMemory: () => Promise<void> = async (): Promise<void> => {};
  onReadCalendarMemory: () => Promise<void> = async (): Promise<void> => {};
  onMailChanged: () => void = (): void => {};
  onSyncMail: () => Promise<void> = async (): Promise<void> => {};
  @StorageLink(STARTUP_SOURCE_SYNC_ENABLED_KEY) private startupSyncEnabled: boolean = true;
  onListScreenshots: () => void = () => {};
  onDeleteModelConfigJson: () => void = () => {};
  onListModelFilesTree: () => void = () => {};
  onListChunkVisionOmFiles: () => void = () => {};
  onDeleteChunkVisionOmFiles: () => void = () => {};
  onLocalNpuExecutionModeChange: (mode: string) => void = (mode: string) => {};

  aboutToAppear(): void {
    this.scheduleDetailScroll();
    this.startupSyncEnabled = new StartupSourceSync((getContext(this) as common.Context).filesDir).isEnabled();
    try { DebugSettings.initialize(getContext(this) as common.Context); } catch (e) {
      showToastSafely('读取 Debug 设置失败：' + (e as Error).message, 2500);
    }
    this.debugSwitchValue = DebugSettings.isEnabled();
    PersonalMemoryAccess.isEnabled(getContext(this) as common.Context).then((enabled: boolean): void => {
      this.personalMemoryA2aEnabled = enabled;
    }).catch((): void => {
      this.personalMemoryA2aEnabled = false;
    });
    this.migrateGalleryDefaultValues();
    this.restoreMaskedDefaultSecrets();
    this.upgradeLegacyVoiceTtsBaseUrl();
  }

  private migrateGalleryDefaultValues(): void {
    if (galleryApiUsesLegacyDefaults(this.galleryApiBaseUrl, this.galleryModel)) {
      this.galleryApiBaseUrl = DEFAULT_GALLERY_API_BASE_URL;
      this.galleryApiKey = DEFAULT_GALLERY_API_KEY;
      this.galleryModel = DEFAULT_GALLERY_MODEL;
      AppStorage.setOrCreate(GALLERY_API_BASE_URL_DEFAULT_SNAPSHOT, DEFAULT_GALLERY_API_BASE_URL);
      AppStorage.setOrCreate(GALLERY_API_KEY_DEFAULT_SNAPSHOT, DEFAULT_GALLERY_API_KEY);
      AppStorage.setOrCreate(GALLERY_MODEL_DEFAULT_SNAPSHOT, DEFAULT_GALLERY_MODEL);
    } else {
      this.galleryApiBaseUrl = this.migrateGalleryDefaultValue(this.galleryApiBaseUrl,
        DEFAULT_GALLERY_API_BASE_URL, [''], GALLERY_API_BASE_URL_DEFAULT_SNAPSHOT);
      this.galleryApiKey = this.migrateGalleryDefaultValue(this.galleryApiKey,
        DEFAULT_GALLERY_API_KEY, [''], GALLERY_API_KEY_DEFAULT_SNAPSHOT);
      this.galleryModel = this.migrateGalleryDefaultValue(this.galleryModel,
        DEFAULT_GALLERY_MODEL, [''], GALLERY_MODEL_DEFAULT_SNAPSHOT);
    }
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

  private restoreMaskedDefaultSecrets(): void {
    this.cloudApiKey = restoreMaskedSensitiveSettingDefault(this.cloudApiKey, DEFAULT_ENDPOINT_CONFIG.cloudApiKey);
    this.cloudPlannerApiKey = restoreMaskedSensitiveSettingDefault(this.cloudPlannerApiKey,
      DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey);
    this.cloudDeciderApiKey = restoreMaskedSensitiveSettingDefault(this.cloudDeciderApiKey,
      DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey);
    this.avatarImageApiKey = restoreMaskedSensitiveSettingDefault(this.avatarImageApiKey,
      DEFAULT_ENDPOINT_CONFIG.avatarImageApiKey);
    this.voiceTtsApiKey = restoreMaskedSensitiveSettingDefault(this.voiceTtsApiKey,
      DEFAULT_ENDPOINT_CONFIG.voiceTtsApiKey);
    this.galleryApiKey = restoreMaskedSensitiveSettingDefault(this.galleryApiKey, DEFAULT_GALLERY_API_KEY);
    this.galleryEmbeddingApiKey =
      restoreMaskedSensitiveSettingDefault(this.galleryEmbeddingApiKey, DEFAULT_GALLERY_EMBEDDING_API_KEY);
    this.galleryAmapWebKey = restoreMaskedSensitiveSettingDefault(this.galleryAmapWebKey,
      DEFAULT_GALLERY_AMAP_WEB_KEY);
  }

  private upgradeLegacyVoiceTtsBaseUrl(): void {
    // 只迁移旧默认值；用户手动配置的其他 OpenAI-compatible 地址保持不变。
    if (this.voiceTtsBaseUrl.trim() === LEGACY_MIMO_TTS_BASE_URL) {
      this.voiceTtsBaseUrl = DEFAULT_ENDPOINT_CONFIG.voiceTtsBaseUrl;
    }
  }

  private closeSensitiveInputs(): void {
    if (this.activeSensitiveInputId.length > 0) {
      this.activeSensitiveInputId = '';
    }
  }

  private setActiveSensitiveInput(id: string): void {
    this.activeSensitiveInputId = id;
  }

  private hdcInputEditable(): boolean {
    return this.hdcManualPairing || !this.hdcAutoConnected;
  }

  private hdcInputBackgroundColor(): string {
    return this.hdcInputEditable() ? '#F2F5FC' : '#E6EAF2';
  }

  private hdcInputTextColor(): string {
    return this.hdcInputEditable() ? '#11182F' : '#7A8494';
  }

  private hdcStatusColor(): string {
    if (this.hdcAutoConnected) {
      return '#2D9B73';
    }
    if (this.hdcAutoConnecting) {
      return settingsActionColor(SettingsActionKind.Primary);
    }
    return '#D26B31';
  }

  private resetDetailScroll(): void {
    if (!isSettingsSectionSelected(this.selectedSectionId)) { return; }
    try {
      let localDownload = this.selectedSectionId === SettingsSectionId.ModelAgents &&
        this.scrollTarget === SettingsScrollTarget.LocalModelDownload;
      this.detailScroller.scrollEdge(localDownload ? Edge.Bottom : Edge.Top);
      if (localDownload) { this.scrollTarget = SettingsScrollTarget.None; }
    } catch (e) {}
  }

  private scheduleDetailScroll(): void {
    let revision = ++this.detailScrollRevision;
    let section = this.selectedSectionId;
    if (!isSettingsSectionSelected(section)) { return; }
    // Wait for the detail layout, including the downloaded-model list, before
    // scrolling. A newer navigation invalidates earlier frame callbacks.
    this.getUIContext().postFrameCallback(new SettingsScrollFrame((): void => {
      if (revision !== this.detailScrollRevision || section !== this.selectedSectionId) { return; }
      this.resetDetailScroll();
    }));
  }

  private onScrollTargetChanged(): void {
    if (this.scrollTarget !== SettingsScrollTarget.None) { this.scheduleDetailScroll(); }
  }

  aboutToDisappear(): void { this.detailScrollRevision++; }

  private openSection(id: SettingsSectionId): void {
    this.scrollTarget = SettingsScrollTarget.None;
    this.selectedSectionId = normalizeSettingsSectionId(id);
  }

  private onSelectedSectionChanged(): void {
    this.closeSensitiveInputs();
    if (this.selectedSectionId !== SettingsSectionId.ModelAgents) { this.scrollTarget = SettingsScrollTarget.None; }
    this.scheduleDetailScroll();
  }

  private closeSection(): void {
    this.closeSensitiveInputs();
    if (this.onBackRequest()) { return; }
    this.selectedSectionId = settingsParentSection(this.selectedSectionId);
  }

  private sectionIcon(id: SettingsSectionId): Resource {
    if (id === SettingsSectionId.PersonalPrivacy) {
      return $r('app.media.settings_privacy');
    }
    if (id === SettingsSectionId.DataCollection) {
      return $r('app.media.settings_collection');
    }
    if (id === SettingsSectionId.ModelAgents) {
      return $r('app.media.settings_model');
    }
    if (id === SettingsSectionId.TaskAutomation) {
      return $r('app.media.settings_automation');
    }
    return $r('app.media.settings_storage');
  }

  private activeSectionTitle(): string {
    return settingsSectionTitle(this.selectedSectionId as SettingsSectionId);
  }

  private isCollectionSection(): boolean {
    return this.selectedSectionId === SettingsSectionId.DataCollection ||
      settingsParentSection(this.selectedSectionId) === SettingsSectionId.DataCollection;
  }

  private confirmDanger(config: SettingsConfirmConfig, action: () => void): void {
    promptAction.showDialog({
      title: config.title,
      message: config.message,
      buttons: [
        { text: '取消', color: settingsActionColor(SettingsActionKind.Secondary) },
        { text: config.confirmText, color: settingsActionColor(SettingsActionKind.Danger) }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        action();
      }
    }).catch(() => {});
  }

  private selectLocalNpuExecutionMode(mode: string): void {
    this.closeSensitiveInputs();
    if (mode === 'full_npu') {
      promptAction.showDialog({
        title: '开发中',
        message: '全图 NPU 功能正在开发中，暂未开放使用。',
        buttons: [{ text: '知道了', color: settingsActionColor(SettingsActionKind.Primary) }]
      }).catch(() => {});
      return;
    }
    if (mode === 'offline_npu2') {
      promptAction.showDialog({
        title: '离线 NPU 使用提示',
        message: '离线 NPU 目前仅支持 Kirin 9030 芯片。其他芯片请使用全 CPU 或在线 NPU。',
        buttons: [
          { text: '取消', color: settingsActionColor(SettingsActionKind.Secondary) },
          { text: '继续使用', color: settingsActionColor(SettingsActionKind.Primary) }
        ]
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        if (data.index === 1) {
          this.onLocalNpuExecutionModeChange(mode);
        }
      }).catch(() => {});
      return;
    }
    this.onLocalNpuExecutionModeChange(mode);
  }

  private confirmClearScreenshots(): void {
    this.confirmDanger({
      title: '清理截图',
      message: '确认执行该操作？将清理当前保存的截图调试产物。',
      confirmText: '清理'
    }, () => { this.onClearScreenshots(); });
  }

  private confirmDeleteDebugOutputs(): void {
    this.confirmDanger({
      title: '清理调试输出',
      message: '确认执行该操作？将删除调试输出文件，操作不可撤回。',
      confirmText: '清理'
    }, () => { this.onDeleteDebugOutputs(); });
  }

  private confirmDeleteModelConfigJson(): void {
    this.confirmDanger({
      title: '删除 Config',
      message: '确认执行该操作？将删除模型 Config 文件，后续需要重新生成或下载。',
      confirmText: '删除'
    }, () => { this.onDeleteModelConfigJson(); });
  }

  private confirmDeleteChunkVisionOmFiles(): void {
    this.confirmDanger({
      title: '删除 chunk OM 缓存',
      message: '确认删除当前模型的全部 chunk OM 缓存？下次遇到对应图片尺寸时需要重新在线编译。',
      confirmText: '删除'
    }, () => { this.onDeleteChunkVisionOmFiles(); });
  }

  private confirmDeleteDownloadedModel(item: DownloadedModelItem): void {
    this.confirmDanger({
      title: '删除模型',
      message: '确认删除“' + item.label + '”及其全部文件？此操作不可撤回。',
      confirmText: '删除'
    }, () => { this.onDeleteDownloadedModel(item.id); });
  }

  @Builder SectionTitle(id: SettingsSectionId) {
    Column() {
      Text(settingsSectionTitle(id))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.text('#11182F'))
        .width('100%')
      Text(settingsSectionSubtitle(id))
        .fontSize(12)
        .fontColor(AppTheme.text('#7B8290'))
        .width('100%')
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 14 })
    .onClick(() => { this.closeSensitiveInputs(); })
  }

  @Builder FieldLabel(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(AppTheme.text(SETTINGS_MUTED_TEXT_COLOR))
      .width('100%')
      .margin({ top: 8, bottom: 6 })
      .onClick(() => { this.closeSensitiveInputs(); })
  }

  @Builder DownloadedModelList() {
    Row() {
      Text('已下载').fontSize(14).fontColor($r('app.color.ui_text_secondary')).layoutWeight(1)
      Button('刷新')
        .height(40).fontSize(14).padding({ left: 12, right: 0 })
        .fontColor($r('app.color.ui_accent_blue')).backgroundColor(Color.Transparent)
        .enabled(!this.localModelDownloadBusy())
        .onClick(() => { this.onRefreshDownloadedModels(); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4 })

    if (this.downloadedModels.length > 0) {
      Column() {
        ForEach(this.downloadedModels, (item: DownloadedModelItem) => {
          Row({ space: 10 }) {
            Column({ space: 5 }) {
              Text(item.label)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ui_text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(item.statusText + ' · ' + item.sizeText)
                .fontSize(12)
                .fontColor(AppTheme.text(item.ready ? '#2D9B73' : '#D26B31'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button(!item.ready ? '未完成' : (this.selectedModelId === item.id ? '使用中' : '使用'))
              .height(36)
              .width(64)
              .fontSize(14).fontColor($r('app.color.ui_accent_blue'))
              .backgroundColor(AppTheme.background('#EEF4FF')).borderRadius(18)
              .enabled(this.selectedModelId !== item.id && item.ready && !this.localModelDownloadBusy())
              .onClick(() => { this.onSwitchDownloadedModel(item.id); })
            Button('删除')
              .height(44).width(44).padding(0).fontSize(14)
              .fontColor(AppTheme.text(settingsActionColor(SettingsActionKind.Danger)))
              .backgroundColor(Color.Transparent)
              .enabled(!this.localModelDownloadBusy())
              .onClick(() => { this.confirmDeleteDownloadedModel(item); })
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 12, bottom: 12 })
          CollectionFormDivider()
        }, (item: DownloadedModelItem) => item.id + ':' + item.statusText + ':' + item.sizeText + ':' + String(item.ready))
      }
      .width('100%')
    } else {
      Text('尚未下载模型').fontSize(14).fontColor($r('app.color.ui_text_secondary'))
        .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 18 })
      CollectionFormDivider()
    }
  }

  @Builder WechatAutoSummaryInput(label: string, value: string, placeholder: string,
    onValueChange: (value: string) => void, onNormalize: () => void) {
    CollectionFormDivider()
    CollectionFormInput({ label: label, value: value, placeholder: placeholder,
      onChangeValue: onValueChange, onBlurValue: onNormalize })
  }

  @Builder SettingToggle(label: string, desc: string, selected: boolean, onValueChange: (value: boolean) => void) {
    SettingToggleControl({
      label: label,
      desc: desc,
      selected: selected,
      onValueChange: (value: boolean) => {
        this.closeSensitiveInputs();
        onValueChange(value);
      }
    })
  }

  @Builder VoiceTtsStylePromptTextArea() {
    TextArea({ placeholder: '留空则不发送 user 风格消息', text: this.voiceTtsStylePrompt })
      .placeholderColor($r('app.color.ui_text_placeholder'))
      .caretColor($r('app.color.ui_accent_blue'))
      .height(96)
      .width('100%')
      .maxLines(5)
      .fontSize(13)
      .lineHeight(20)
      .fontColor(AppTheme.text(SETTINGS_MUTED_TEXT_COLOR))
      .backgroundColor(AppTheme.background(SETTINGS_INPUT_BACKGROUND_COLOR))
      .borderRadius(SETTINGS_CONTROL_RADIUS)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => { this.closeSensitiveInputs(); })
      .onFocus(() => { this.closeSensitiveInputs(); })
      .onChange((val: string) => {
        this.voiceTtsStylePrompt = val;
      })
  }

  @Builder VoiceTtsStylePromptInput() {
    this.FieldLabel('语音风格提示')
    if (this.voiceTtsStylePromptEditorRevision % 2 === 0) {
      this.VoiceTtsStylePromptTextArea()
    } else {
      // 角色预设切换会改变外部状态；输入组件自身有编辑态，切换分支可确保文本重建同步。
      this.VoiceTtsStylePromptTextArea()
    }
  }

  @Builder VoiceTtsRolePresetButton(preset: VoiceTtsRolePreset) {
    Button(preset.label)
      .height(36)
      .width('48%')
      .fontSize(12)
      .fontColor(AppTheme.text(this.voiceTtsRolePreset === preset.id ? Color.White : settingsActionColor(SettingsActionKind.Primary)))
      .backgroundColor(AppTheme.background(this.voiceTtsRolePreset === preset.id ? settingsActionColor(SettingsActionKind.Primary) :
        '#EEF3FF'))
      .borderRadius(10)
      .margin({ right: 6, bottom: 8 })
      .onClick(() => {
        this.closeSensitiveInputs();
        let selection: VoiceTtsRoleSelection = voiceTtsSelectionFromRolePreset(preset);
        this.voiceTtsRolePreset = selection.rolePreset;
        this.voiceTtsVoice = selection.voice;
        this.voiceTtsStylePrompt = selection.stylePrompt;
        this.voiceTtsStylePromptEditorRevision++;
      })
  }

  @Builder VoiceTtsVoicePresetButton(voice: VoiceTtsVoicePreset) {
    Button(voice)
      .height(34)
      .width('31%')
      .fontSize(11)
      .fontColor(AppTheme.text(this.voiceTtsVoice === voice ? Color.White : settingsActionColor(SettingsActionKind.Primary)))
      .backgroundColor(AppTheme.background(this.voiceTtsVoice === voice ? settingsActionColor(SettingsActionKind.Primary) : '#EEF3FF'))
      .borderRadius(10)
      .margin({ right: 6, bottom: 8 })
      .onClick(() => {
        this.closeSensitiveInputs();
        this.voiceTtsVoice = voice;
      })
  }

  @Builder VoiceTtsPresetSettings() {
    this.SettingToggle('流式语音合成', '开启后首批 PCM 到达即播放，失败时回退 WAV 合成',
      this.voiceTtsStreamingEnabled, (value: boolean) => { this.voiceTtsStreamingEnabled = value; })
    this.FieldLabel('助手朗读角色')
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(VOICE_TTS_ROLE_PRESETS, (preset: VoiceTtsRolePreset) => {
        this.VoiceTtsRolePresetButton(preset)
      }, (preset: VoiceTtsRolePreset) => preset.id)
    }
    .width('100%')
    this.FieldLabel('语音合成音色')
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(MIMO_CHINESE_VOICE_PRESETS, (voice: VoiceTtsVoicePreset) => {
        this.VoiceTtsVoicePresetButton(voice)
      }, (voice: VoiceTtsVoicePreset) => voice)
    }
    .width('100%')
    this.VoiceTtsStylePromptInput()
  }

  private isWechatAutoSummaryEnabled(): boolean {
    return this.wechatAutoSummaryEnabled === 'true';
  }

  private setWechatAutoSummaryEnabled(value: boolean): void {
    this.wechatAutoSummaryEnabled = value ? 'true' : 'false';
  }

  @Builder WechatAutoSummarySettings() {
    Column() {
      CollectionFormSwitch({ label: '微信消息自动汇总', detail: '采集任务按默认参数汇总最近会话',
        selected: this.isWechatAutoSummaryEnabled(),
        onChangeValue: (value: boolean): void => { this.setWechatAutoSummaryEnabled(value); } })
      if (this.isWechatAutoSummaryEnabled()) {
        this.WechatAutoSummaryInput('默认时间范围（天）', this.wechatAutoSummaryDefaultDays,
          DEFAULT_WECHAT_AUTO_SUMMARY_DAYS,
          (value: string) => { this.wechatAutoSummaryDefaultDays = value; },
          () => {
            this.wechatAutoSummaryDefaultDays = String(
              normalizeWechatAutoSummaryDays(this.wechatAutoSummaryDefaultDays));
          })
        this.WechatAutoSummaryInput('默认最近联系人数量', this.wechatAutoSummaryDefaultMaxContacts,
          DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS,
          (value: string) => { this.wechatAutoSummaryDefaultMaxContacts = value; },
          () => {
            this.wechatAutoSummaryDefaultMaxContacts = String(
              normalizeWechatAutoSummaryMaxContacts(this.wechatAutoSummaryDefaultMaxContacts));
          })
        Text('采集结果保存在本机，同步后可整理到个人记忆。')
        .fontSize(12)
        .fontColor(AppTheme.text('#747C8A'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })

        Row() {
          Text('高级参数')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#11182F'))
            .layoutWeight(1)
          Text(this.wechatAutoSummaryAdvancedOpen ? '收起' : '展开')
            .fontSize(12)
            .fontColor(AppTheme.text('#5B68FF'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 14 })
        .onClick(() => { this.wechatAutoSummaryAdvancedOpen = !this.wechatAutoSummaryAdvancedOpen; })

        if (this.wechatAutoSummaryAdvancedOpen) {
          this.WechatAutoSummaryInput('滑动速度', this.wechatAutoSummarySwipeSpeed,
            DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED,
            (value: string) => { this.wechatAutoSummarySwipeSpeed = value; },
            () => {
              this.wechatAutoSummarySwipeSpeed = String(
                normalizeWechatAutoSummarySwipeSpeed(this.wechatAutoSummarySwipeSpeed));
            })
          this.WechatAutoSummaryInput('历史滑动距离比例', this.wechatAutoSummaryHistorySwipeRatio,
            DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO,
            (value: string) => { this.wechatAutoSummaryHistorySwipeRatio = value; },
            () => {
              this.wechatAutoSummaryHistorySwipeRatio = String(
                normalizeWechatAutoSummaryHistorySwipeRatio(this.wechatAutoSummaryHistorySwipeRatio));
            })
          this.WechatAutoSummaryInput('稳定停止次数', this.wechatAutoSummaryStableSwipes,
            DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES,
            (value: string) => { this.wechatAutoSummaryStableSwipes = value; },
            () => {
              this.wechatAutoSummaryStableSwipes = String(
                normalizeWechatAutoSummaryStableSwipes(this.wechatAutoSummaryStableSwipes));
            })
          this.WechatAutoSummaryInput('最大历史滑动次数', this.wechatAutoSummaryMaxHistorySwipes,
            DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES,
            (value: string) => { this.wechatAutoSummaryMaxHistorySwipes = value; },
            () => {
              this.wechatAutoSummaryMaxHistorySwipes = String(
                normalizeWechatAutoSummaryMaxHistorySwipes(this.wechatAutoSummaryMaxHistorySwipes));
            })
          this.WechatAutoSummaryInput('导航等待秒数', this.wechatAutoSummaryWait,
            DEFAULT_WECHAT_AUTO_SUMMARY_WAIT,
            (value: string) => { this.wechatAutoSummaryWait = value; },
            () => {
              this.wechatAutoSummaryWait = String(normalizeWechatAutoSummaryWait(this.wechatAutoSummaryWait));
            })
        }
      }
    }
    .width('100%')
    .margin({ bottom: 0 })
  }

  @Builder ModelDownloadProgressPanel() {
    if (this.modelDownloadProgressVisible) {
      Column({ space: 10 }) {
        Row() {
          Text(this.modelScopeDownloading ? '正在下载' : (this.modelScopePauseRequested ? '已暂停' : '下载进度'))
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ui_text_primary'))
            .layoutWeight(1)
          Text(Math.max(0, Math.min(100, this.modelDownloadProgressPercent)).toString() + '%')
            .fontSize(14).fontColor($r('app.color.ui_accent_blue'))
          if (this.modelScopeDownloading) {
            Button(this.modelScopePauseRequested ? '暂停中' : '暂停')
              .height(36).fontSize(14).padding({ left: 14, right: 0 })
              .fontColor($r('app.color.ui_accent_blue')).backgroundColor(Color.Transparent)
              .enabled(!this.modelScopePauseRequested)
              .onClick((): void => { this.onPauseModelScopeDownload(); })
          }
        }
        .width('100%')

        Progress({ value: Math.max(0, Math.min(100, this.modelDownloadProgressPercent)), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.ui_accent_blue'))
          .backgroundColor($r('app.color.ui_surface_soft'))
          .borderRadius(6)
        Text(this.modelDownloadProgressText.length > 0 ? this.modelDownloadProgressText : this.modelDownloadProgressTitle)
          .fontSize(12).fontColor($r('app.color.ui_text_secondary'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(16).backgroundColor($r('app.color.ui_surface')).borderRadius(18)
      .margin({ bottom: 24 })
    }
  }

  @Builder SettingsListItem(item: SettingsSectionItem) {
    SettingsNavigationRow({ title: item.title, icon: this.sectionIcon(item.id),
      onOpen: (): void => { this.openSection(item.id); } })
  }

  @Builder DesktopCompanionEntry() {
    SettingsNavigationRow({ title: '桌面端 App', icon: $r('app.media.settings_desktop'),
      onOpen: (): void => { router.pushUrl({ url: 'pages/settings/DesktopCompanionPage' }); } })
  }

  @Builder SelfHdcTestEntry() {
    SettingsNavigationRow({ title: '手机 HDC', icon: $r('app.media.settings_phone'),
      onOpen: (): void => { router.pushUrl({ url: 'pages/settings/SelfHdcTestPage' }); } })
  }

  private setDebugEnabled(enabled: boolean): void {
    this.debugSwitchValue = enabled;
    try { DebugSettings.setEnabled(getContext(this) as common.Context, enabled); } catch (e) {
      showToastSafely('保存 Debug 设置失败：' + (e as Error).message, 2500);
    }
    this.debugSwitchValue = DebugSettings.isEnabled();
  }

  private onDebugSettingChanged(): void {
    this.debugSwitchValue = this.debugEnabled;
  }

  @Builder DebugSwitch() {
    Row({ space: 14 }) {
      Image($r('app.media.settings_debug')).width(24).height(24).objectFit(ImageFit.Contain)
      Text('开启 Debug').fontSize(17).fontColor($r('app.color.ui_text_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.debugSwitchValue })
        .selectedColor(AppTheme.background('#4F68FF'))
        .onChange((enabled: boolean): void => { this.setDebugEnabled(enabled); })
    }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 18, right: 18, top: 12, bottom: 12 })
  }

  @Builder SettingsSectionList() {
    Column({ space: 20 }) {
      HuaweiAccountCard({ sessionActive: $huaweiAccountSessionActive })
      Column() {
        ForEach(SETTINGS_SECTION_ITEMS.filter((item: SettingsSectionItem): boolean => item.id !== SettingsSectionId.StorageAbout),
          (item: SettingsSectionItem, index: number) => {
            if (index > 0) { SettingsListDivider() }
            this.SettingsListItem(item)
          }, (item: SettingsSectionItem): string => String(item.id))
      }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(22).clip(true)
      Column() {
        this.SelfHdcTestEntry()
        SettingsListDivider()
        this.DesktopCompanionEntry()
      }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(22).clip(true)
      Column() {
        this.DebugSwitch()
        SettingsListDivider()
        SettingsNavigationRow({ title: settingsSectionTitle(SettingsSectionId.StorageAbout), icon: this.sectionIcon(SettingsSectionId.StorageAbout),
          onOpen: (): void => { this.openSection(SettingsSectionId.StorageAbout); } })
      }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(22).clip(true)
    }
    .width('92%').constraintSize({ maxWidth: 720 })
    .padding({ top: APP_HEADER_CONTENT_GAP, bottom: 110 })
  }

  @Builder SettingsDetailHeader() {
    AppHeader({ title: this.activeSectionTitle(), showBackButton: true,
      onBackClick: (): void => { this.closeSection(); } })
  }

  @Builder SelectedSectionContent() {
    Column() {
      if (this.selectedSectionId === SettingsSectionId.CloudModelAdvanced) {
        this.CloudModelAdvancedSection()
      } else if (this.selectedSectionId === SettingsSectionId.PersonalPrivacy) {
        this.PrivacySection()
      } else if (this.selectedSectionId === SettingsSectionId.DataCollection) {
        this.DataCollectionSection()
      } else if (settingsParentSection(this.selectedSectionId) === SettingsSectionId.DataCollection) {
        this.CollectionSourceSection()
      } else if (this.selectedSectionId === SettingsSectionId.ModelAgents) {
        this.ModelAgentsSection()
      } else if (this.selectedSectionId === SettingsSectionId.TaskAutomation) {
        this.TaskAutomationSection()
      } else if (this.selectedSectionId === SettingsSectionId.StorageAbout) {
        this.StorageAboutSection()
      }
    }
    .width('100%')
  }

  @Builder PrivacySection() {
    Column() {
      this.SectionTitle(SettingsSectionId.PersonalPrivacy)
      this.PrivacyDeclarationEntry()
      SettingsGroupCard({
        title: '小艺读取个人记忆',
        subtitle: '需要 API 24 或更新系统；可查询已同步的各类记忆摘要',
        contentBuilder: () => { this.XiaoyiPersonalMemoryGroup() }
      })
      SettingsGroupCard({
        title: 'Agent 确认策略',
        subtitle: '控制本地与云端 Agent 动作是否需要人工确认',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.AgentConfirmPolicyGroup() }
      })
    }
    .width(SETTINGS_PAGE_HORIZONTAL_PADDING)
    .margin({ top: 16, bottom: 110 })
  }

  @Builder AgentConfirmPolicyGroup() {
    this.SettingToggle('本地 Agent 自动同意', '关闭后每次端侧模型动作都会弹窗确认', this.autoConfirm,
      (value: boolean) => { this.autoConfirm = value; })
    this.SettingToggle('云端 Agent 自动同意', '关闭后云端模型动作需要手动确认后发给 PC', this.cloudAutoConfirm,
      (value: boolean) => { this.cloudAutoConfirm = value; })
  }

  @Builder XiaoyiPersonalMemoryGroup() {
    this.SettingToggle('允许小艺查询个人记忆',
      '使用已配置的云端 Agent 查询外卖、微信等记忆；需登录及联网；不提供证件号码、详细住址',
      this.personalMemoryA2aEnabled && this.privacyConsentState === 'accepted',
      (enabled: boolean): void => {
        PersonalMemoryAccess.setEnabled(getContext(this) as common.Context, enabled).then((saved: boolean): void => {
          this.personalMemoryA2aEnabled = saved;
        }).catch((e: Error): void => {
          this.personalMemoryA2aEnabled = false;
          showToastSafely(e.message || '设置保存失败', 1800);
        });
      })
  }

  @Builder PrivacyDeclarationEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 5 }) {
          Text('隐私政策')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text($r('sys.color.ohos_id_color_text_primary')))
          Text('查看应用隐私政策')
            .fontSize(12)
            .fontColor(AppTheme.text($r('sys.color.ohos_id_color_text_secondary')))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('›').fontSize(24).fontColor(AppTheme.text($r('sys.color.ohos_id_color_text_secondary')))
      }
      .width('100%')
    }
    .width('92%')
    .padding(18)
    .borderRadius(20)
    .backgroundColor(AppTheme.background($r('sys.color.ohos_id_color_dialog_bg')))
    .margin({ top: 16 })
    .onClick(() => { HuaweiPrivacyAccess.openPolicy(this.getUIContext()); })
  }

  @Builder AvatarImageServiceGroup() {
    SettingInput({
      label: '数字分身图片服务',
      value: hiddenDefaultSettingEditorValue(this.avatarImageBaseUrl, DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl),
      placeholder: hiddenDefaultSettingPlaceholder(this.avatarImageBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl, '输入图片服务 URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.avatarImageBaseUrl = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'avatarImageApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: '数字分身图片 API Key',
      value: this.avatarImageApiKey,
      defaultValue: DEFAULT_ENDPOINT_CONFIG.avatarImageApiKey,
      placeholder: '图片服务密钥',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.avatarImageApiKey = value; }
    })
    SettingInput({
      label: '文生图模型',
      value: this.avatarTextToImageModel,
      placeholder: DEFAULT_ENDPOINT_CONFIG.avatarImageModel,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.avatarTextToImageModel = value; }
    })
    SettingInput({
      label: '图生图模型',
      value: this.avatarImageToImageModel,
      placeholder: DEFAULT_ENDPOINT_CONFIG.avatarImageModel,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.avatarImageToImageModel = value; }
    })
    SettingInput({
      label: '图片尺寸',
      value: this.avatarImageSize,
      placeholder: '默认 ' + DEFAULT_ENDPOINT_CONFIG.avatarImageSize,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.avatarImageSize = value; }
    })
  }

  @Builder CollectionSourceEntries() {
    CollectionSourceRow({ title: '日历分析', detail: '同步日程与个人记忆', icon: $r('app.media.source_calendar'),
      showSync: true, syncEnabled: this.calendarSourceSyncReady && !this.calendarMemoryRefreshing && !this.sourceSyncPending,
      syncing: this.sourceSyncPending === 'calendar', onSync: this.onQuickSyncCalendar,
      tint: '#FF9500', onOpen: (): void => { this.openSection(SettingsSectionId.CalendarAnalysis); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '邮箱分析', detail: '账号设置与近三天邮件筛选', icon: $r('app.media.source_mail'),
      showSync: true, syncEnabled: this.mailSourceSyncReady && !this.calendarMemoryRefreshing && !this.sourceSyncPending,
      syncing: this.sourceSyncPending === 'mail', onSync: this.onQuickSyncMail,
      onOpen: (): void => { this.openSection(SettingsSectionId.MailAnalysis); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '微信采集', detail: '默认范围与高级参数', icon: $r('app.media.source_wechat'),
      tint: '#34C759', onOpen: (): void => { this.openSection(SettingsSectionId.WechatCollection); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '图库分析', detail: '读取照片、截图并理解内容', icon: $r('app.media.source_gallery'),
      tint: '#AF52DE', onOpen: (): void => { router.pushUrl({ url: 'pages/gallery/GalleryPage' }); } })
  }

  @Builder CollectionAuxiliaryEntries() {
    CollectionSourceRow({ title: '文字识别', detail: 'OCR 预筛与并发', icon: $r('app.media.source_gallery'),
      tint: '#8E8E93', onOpen: (): void => { this.openSection(SettingsSectionId.OcrCollection); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '图片位置', detail: '拍摄位置解析与图片缩放', icon: $r('app.media.source_gallery'),
      tint: '#8E8E93', onOpen: (): void => { this.openSection(SettingsSectionId.MapCollection); } })
  }

  private changeStartupSyncEnabled(enabled: boolean): void {
    try {
      new StartupSourceSync((getContext(this) as common.Context).filesDir).setEnabled(enabled);
      this.startupSyncEnabled = enabled;
    } catch (e) { showToastSafely('自动更新设置未保存，请重试'); }
  }

  @Builder StartupSyncSettings() {
    CollectionFormSwitch({ label: '每日自动更新', selected: this.startupSyncEnabled,
      detail: '距离上次成功满24小时后，检查已开启的邮件、日历和新增聊天',
      onChangeValue: (enabled: boolean): void => { this.changeStartupSyncEnabled(enabled); } })
  }

  @Builder DataCollectionSection() {
    Column() {
      CollectionFormGroup({ title: '同步', footer: '距上次成功处理满24小时后，打开应用时检查已开启的来源。未授权或未配置的来源会跳过；失败可手动重试。关闭不影响手动操作。',
        contentBuilder: (): void => { this.StartupSyncSettings(); } })
      CollectionFormGroup({ title: '采集来源', contentBuilder: (): void => { this.CollectionSourceEntries(); } })
      CollectionFormGroup({ title: '辅助设置', contentBuilder: (): void => { this.CollectionAuxiliaryEntries(); } })
    }.width('92%').constraintSize({ maxWidth: 720 }).margin({ top: 12, bottom: 110 })
  }

  @Builder CollectionSourceSection() {
    Column() {
      if (this.selectedSectionId === SettingsSectionId.CalendarAnalysis) {
        CalendarMemoryPanel({ memoryRefreshing: this.calendarMemoryRefreshing,
          onSync: async (): Promise<void> => { await this.onReadCalendarMemory(); },
          onMemoryChanged: async (): Promise<void> => { await this.onSyncCalendarMemory(); } })
      } else if (this.selectedSectionId === SettingsSectionId.MailAnalysis) {
        MailSettingsPanel({ memoryRefreshing: this.calendarMemoryRefreshing,
          onChanged: (): void => { this.onMailChanged(); },
          onSync: async (): Promise<void> => { await this.onSyncMail(); } })
      } else if (this.selectedSectionId === SettingsSectionId.WechatCollection) {
        CollectionFormGroup({ title: '默认采集', footer: '设置自动保存。汇总页可以为本次采集调整联系人与时间范围。',
          contentBuilder: (): void => { this.WechatAutoSummarySettings(); } })
      } else if (this.selectedSectionId === SettingsSectionId.OcrCollection) {
        CollectionFormGroup({ title: '文字识别', footer: '设置自动保存，用于图库分析的本地文字识别。',
          contentBuilder: (): void => { this.OcrSettingsGroup(); } })
      } else if (this.selectedSectionId === SettingsSectionId.MapCollection) {
        CollectionFormGroup({ title: '图片位置', footer: '设置自动保存，位置解析需要有效的地图服务 Key。',
          contentBuilder: (): void => { this.MapSettingsGroup(); } })
      }
    }.width('92%').constraintSize({ maxWidth: 720 }).margin({ top: 12, bottom: 110 })
  }

  @Builder GalleryAnalysisGroup() {
    SettingInput({
      label: '图库 API Base URL',
      value: hiddenDefaultSettingEditorValue(this.galleryApiBaseUrl, DEFAULT_GALLERY_API_BASE_URL),
      placeholder: hiddenDefaultSettingPlaceholder(this.galleryApiBaseUrl, DEFAULT_GALLERY_API_BASE_URL,
        '输入图库 API Base URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryApiBaseUrl = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'galleryApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: '图库 API Key',
      value: this.galleryApiKey,
      defaultValue: DEFAULT_GALLERY_API_KEY,
      placeholder: '图库分析服务密钥',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.galleryApiKey = value; }
    })
    SettingInput({
      label: '图库大模型',
      value: this.galleryModel,
      placeholder: '留空则不发送 model 字段',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryModel = value; }
    })
    this.SettingToggle('字段级并发请求', '同一张图并发请求各分析字段，降低整包 JSON 解析失败概率',
      this.galleryParallelFieldRequests === 'true',
      (value: boolean) => { this.galleryParallelFieldRequests = value ? 'true' : 'false'; })
    SettingInput({
      label: '大模型并发请求数',
      value: this.galleryModelConcurrency,
      placeholder: DEFAULT_GALLERY_MODEL_CONCURRENCY,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryModelConcurrency = value; }
    })
  }

  @Builder OcrSettingsGroup() {
    CollectionFormSwitch({ label: '跳过本地 OCR', detail: '设备不支持本地 OCR 时开启',
      selected: this.gallerySkipOcr === 'true',
      onChangeValue: (value: boolean): void => { this.gallerySkipOcr = value ? 'true' : 'false'; } })
    CollectionFormDivider()
    CollectionFormSwitch({ label: 'OCR 关键词预筛', detail: '自动分析前先用关键词过滤图片',
      selected: this.galleryUseOcrKeywordFilter === 'true',
      onChangeValue: (value: boolean): void => { this.galleryUseOcrKeywordFilter = value ? 'true' : 'false'; } })
    CollectionFormDivider()
    CollectionFormInput({ label: 'OCR 并发请求数', value: this.galleryOcrConcurrency,
      placeholder: DEFAULT_GALLERY_OCR_CONCURRENCY, inputType: InputType.Number,
      onChangeValue: (value: string): void => { this.galleryOcrConcurrency = value; } })
  }

  @Builder EmbeddingSettingsGroup() {
    SettingInput({
      label: 'Embedding 并发请求数',
      value: this.galleryEmbeddingConcurrency,
      placeholder: DEFAULT_GALLERY_EMBEDDING_CONCURRENCY,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryEmbeddingConcurrency = value; }
    })
    this.SettingToggle('使用云端 Embedding API', '关闭时使用华为端侧 Embedding',
      this.galleryEmbeddingMode === 'remote',
      (value: boolean) => { this.galleryEmbeddingMode = value ? 'remote' : 'huawei_local'; })
    SettingInput({
      label: 'Embedding Base URL',
      value: hiddenDefaultSettingEditorValue(this.galleryEmbeddingBaseUrl, DEFAULT_GALLERY_EMBEDDING_BASE_URL),
      placeholder: hiddenDefaultSettingPlaceholder(this.galleryEmbeddingBaseUrl, DEFAULT_GALLERY_EMBEDDING_BASE_URL,
        '输入 Embedding Base URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryEmbeddingBaseUrl = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'galleryEmbeddingApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: 'Embedding API Key',
      value: this.galleryEmbeddingApiKey,
      defaultValue: DEFAULT_GALLERY_EMBEDDING_API_KEY,
      placeholder: 'Embedding 服务密钥',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.galleryEmbeddingApiKey = value; }
    })
    SettingInput({
      label: 'Embedding 模型',
      value: this.galleryEmbeddingModel,
      placeholder: DEFAULT_GALLERY_EMBEDDING_MODEL,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.galleryEmbeddingModel = value; }
    })
  }

  @Builder MapSettingsGroup() {
    CollectionFormInput({ label: '图片分析缩放比例', value: this.galleryImageScale, placeholder: DEFAULT_GALLERY_IMAGE_SCALE,
      onChangeValue: (value: string): void => { this.galleryImageScale = value; } })
    CollectionFormDivider()
    CollectionFormInput({ label: '高德 Web 服务 Key', value: this.galleryAmapWebKey, secret: true,
      placeholder: '用于拍摄位置逆地理编码',
      onChangeValue: (value: string): void => { this.galleryAmapWebKey = value; } })
  }

  @Builder ModelAgentsSection() {
    Column() {
      CollectionFormGroup({ title: '云端模型',
        contentBuilder: () => { this.UnifiedCloudModelGroup() }
      })
      CollectionFormGroup({ title: '本地模型',
        contentBuilder: () => { this.LocalModelGroup() }
      })
      this.ModelDownloadGroup()
    }
    .width(SETTINGS_PAGE_HORIZONTAL_PADDING)
    .margin({ top: 16, bottom: 110 })
  }

  @Builder CloudModelAdvancedSection() {
    Column() {
      this.SectionTitle(SettingsSectionId.CloudModelAdvanced)
      SettingsGroupCard({
        title: 'Planner · 任务规划',
        purpose: '用于云端对话、任务规划、个人记忆查询与信息整理。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.CloudPlannerGroup() }
      })
      SettingsGroupCard({
        title: 'Decider · 看图决策',
        purpose: '读取手机截图并决定点击、滑动、输入等操作，需要支持图片输入的模型。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.CloudDeciderGroup() }
      })
      SettingsGroupCard({
        title: '语音合成服务',
        purpose: '把 AI 回复合成为语音，用于助手朗读和语音聊天。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.VoiceTtsServiceGroup() }
      })
      SettingsGroupCard({
        title: '数字分身图片服务',
        purpose: '根据个人画像生成数字分身头像，可分别配置文生图和图生图模型。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.AvatarImageServiceGroup() }
      })
      SettingsGroupCard({
        title: '图库分析模型',
        purpose: '识别照片和截图，提取主题、内容摘要与生活记忆，需要支持图片输入的模型。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.GalleryAnalysisGroup() }
      })
      SettingsGroupCard({
        title: 'Embedding · 语义检索',
        purpose: '把图库内容摘要和搜索词转为向量，支持按含义查找图片，可选端侧或云端模式。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.EmbeddingSettingsGroup() }
      })
      SettingsGroupCard({
        title: '上下文压缩',
        purpose: '控制聊天历史何时压缩、保留多少轮对话，减少上下文占用。',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.ContextCompressionGroup() }
      })
    }
    .width(SETTINGS_PAGE_HORIZONTAL_PADDING)
    .margin({ top: 16, bottom: 110 })
  }

  private storedCloudSettings(): CloudModelConfig {
    return {
      plannerBaseUrl: this.cloudPlannerBaseUrl, plannerModel: this.cloudPlannerModel,
      plannerApiKey: this.cloudPlannerApiKey, deciderBaseUrl: this.cloudDeciderBaseUrl,
      deciderModel: this.cloudDeciderModel, deciderApiKey: this.cloudDeciderApiKey, apiKey: this.cloudApiKey
    };
  }

  private updateUnifiedCloudField(field: string, value: string): void {
    let next = updateUnifiedCloudSetting(this.storedCloudSettings(), field, value);
    this.cloudPlannerBaseUrl = next.plannerBaseUrl;
    this.cloudDeciderBaseUrl = next.deciderBaseUrl;
    this.cloudPlannerModel = next.plannerModel;
    this.cloudDeciderModel = next.deciderModel;
    this.cloudPlannerApiKey = next.plannerApiKey || '';
    this.cloudDeciderApiKey = next.deciderApiKey || '';
    this.cloudApiKey = next.apiKey;
  }

  @Builder UnifiedCloudModelGroup() {
    ModelSettingsField({
      label: 'API 地址',
      value: sharedCloudSettingEditorValue(this.cloudPlannerBaseUrl, this.cloudDeciderBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl),
      placeholder: cloudSettingValuesDiffer(this.cloudPlannerBaseUrl, this.cloudDeciderBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl) ?
        '独立配置' : '默认',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.updateUnifiedCloudField('url', value); }
    })
    CollectionFormDivider()
    ModelSettingsField({
      label: '模型名称',
      value: sharedCloudSettingEditorValue(this.cloudPlannerModel, this.cloudDeciderModel,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel, DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel),
      placeholder: cloudSettingValuesDiffer(this.cloudPlannerModel, this.cloudDeciderModel,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel, DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel) ?
        '独立配置' : '默认',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.updateUnifiedCloudField('model', value); }
    })
    CollectionFormDivider()
    ModelSettingsField({
      label: 'API Key', secret: true,
      value: sharedCloudSettingEditorValue(this.cloudPlannerApiKey, this.cloudDeciderApiKey,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey, DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey),
      placeholder: cloudSettingValuesDiffer(this.cloudPlannerApiKey, this.cloudDeciderApiKey,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey, DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey) ? '独立配置' : '默认',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.updateUnifiedCloudField('key', value); }
    })
    CollectionFormDivider()
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text('更多设置').fontSize(15).fontColor($r('app.color.ui_text_primary')).layoutWeight(1)
        if (cloudSettingsUseSeparateValues(this.storedCloudSettings(), defaultChatCloudConfig())) {
          Text('独立配置').fontSize(13).fontColor($r('app.color.ui_text_secondary')).margin({ right: 8 })
        }
        Text('›').fontSize(23).fontColor($r('app.color.ui_text_secondary'))
      }.width('100%')
    }.width('100%').height(52).padding({ left: 16, right: 16 }).backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.closeSensitiveInputs();
        this.openSection(SettingsSectionId.CloudModelAdvanced);
      })
  }

  @Builder CloudPlannerGroup() {
    SettingInput({
      label: 'Planner 服务',
      value: hiddenDefaultSettingEditorValue(this.cloudPlannerBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl),
      placeholder: hiddenDefaultSettingPlaceholder(this.cloudPlannerBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl, '输入 Planner 服务 URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.cloudPlannerBaseUrl = value; }
    })
    SettingInput({
      label: 'Planner Model',
      value: this.cloudPlannerModel,
      placeholder: DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel.length > 0 ?
        DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel : '留空则不传 model',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.cloudPlannerModel = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'cloudPlannerApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: 'Planner API Key',
      value: this.cloudPlannerApiKey,
      defaultValue: DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey,
      placeholder: 'Planner 服务密钥',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.cloudPlannerApiKey = value; }
    })
    SettingsActionRow({ contentBuilder: () => { this.CloudPlannerActionRow() } })
    SettingsOutputPanel({ title: 'Planner 测试结果', content: this.cloudOutput, aiGenerated: true })
  }

  @Builder CloudDeciderGroup() {
    SettingInput({
      label: 'Decider 服务',
      value: hiddenDefaultSettingEditorValue(this.cloudDeciderBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl),
      placeholder: hiddenDefaultSettingPlaceholder(this.cloudDeciderBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl, '输入 Decider 服务 URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.cloudDeciderBaseUrl = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'cloudDeciderApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: 'Decider API Key',
      value: this.cloudDeciderApiKey,
      defaultValue: DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey,
      placeholder: 'Decider 服务密钥',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.cloudDeciderApiKey = value; }
    })
    SettingInput({
      label: 'Decider Model',
      value: this.cloudDeciderModel,
      placeholder: '留空则不传 model',
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.cloudDeciderModel = value; }
    })
  }

  @Builder CloudPlannerActionRow() {
    SettingsActionButton({
      label: '测试 Planner',
      kind: SettingsActionKind.Success,
      onActionClick: async () => {
        this.closeSensitiveInputs();
        await this.onTestCloudPlanner();
      }
    })
  }

  @Builder VoiceTtsServiceGroup() {
    SettingInput({
      label: '语音合成服务',
      value: hiddenDefaultSettingEditorValue(this.voiceTtsBaseUrl, DEFAULT_ENDPOINT_CONFIG.voiceTtsBaseUrl),
      placeholder: hiddenDefaultSettingPlaceholder(this.voiceTtsBaseUrl,
        DEFAULT_ENDPOINT_CONFIG.voiceTtsBaseUrl, '输入语音合成服务 URL'),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.voiceTtsBaseUrl = value; }
    })
    SensitiveSettingInput({
      sensitiveId: 'voiceTtsApiKey',
      activeSensitiveId: this.activeSensitiveInputId,
      label: '语音合成 API Key',
      value: this.voiceTtsApiKey,
      defaultValue: DEFAULT_ENDPOINT_CONFIG.voiceTtsApiKey,
      placeholder: 'MiMO TTS 服务密钥，格式 tp-xxxxx',
      onActiveSensitiveChange: (value: string) => { this.setActiveSensitiveInput(value); },
      onValueChange: (value: string) => { this.voiceTtsApiKey = value; }
    })
    SettingInput({
      label: '语音合成模型',
      value: this.voiceTtsModel,
      placeholder: DEFAULT_ENDPOINT_CONFIG.voiceTtsModel,
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => { this.voiceTtsModel = value; }
    })
    this.VoiceTtsPresetSettings()
  }

  @Builder ContextCompressionGroup() {
    this.WechatAutoSummaryInput('上下文压缩阈值(%)', this.chatContextCompressionThresholdPercent, '默认 85，范围 50-95',
      (value: string) => { this.chatContextCompressionThresholdPercent = value; },
      () => {
        this.chatContextCompressionThresholdPercent =
          String(normalizeChatContextCompressionThresholdPercent(this.chatContextCompressionThresholdPercent));
      })
    this.WechatAutoSummaryInput('压缩保留轮数', this.chatContextRecentRounds, '默认 8，范围 2-20',
      (value: string) => { this.chatContextRecentRounds = value; },
      () => {
        this.chatContextRecentRounds = String(normalizeChatContextRecentRounds(this.chatContextRecentRounds));
      })
  }

  @Builder LocalModelGroup() {
    this.DownloadedModelList()
    Column({ space: 8 }) {
      Text('推理方式').fontSize(14).fontColor($r('app.color.ui_text_secondary'))
        .width('100%').margin({ bottom: 4 })
      Row({ space: 8 }) {
        this.NpuExecutionModeButton('CPU', 'cpu')
        this.NpuExecutionModeButton('在线 NPU', 'online')
      }.width('100%')
      Row({ space: 8 }) {
        this.NpuExecutionModeButton('离线 NPU', 'offline_npu2')
        this.NpuExecutionModeButton('全图 NPU · 开发中', 'full_npu')
      }.width('100%')
    }.width('100%').padding(16)
    CollectionFormDivider()
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text('模型缓存').fontSize(15).fontColor($r('app.color.ui_text_primary')).layoutWeight(1)
        Text(this.modelCacheExpanded ? '⌃' : '⌄').fontSize(20).fontColor($r('app.color.ui_text_secondary'))
      }.width('100%')
    }.width('100%').height(52).padding({ left: 16, right: 16 }).backgroundColor(Color.Transparent)
      .onClick((): void => { this.modelCacheExpanded = !this.modelCacheExpanded; })
    if (this.modelCacheExpanded) {
      Column() {
        SettingsActionRow({ contentBuilder: () => { this.ChunkOmCacheActionRow() } })
        SettingsOutputPanel({ title: '缓存文件', content: this.chunkOmCacheOutput })
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
    }
  }

  @Builder NpuExecutionModeButton(label: string, mode: string) {
    Button(label)
      .height(SETTINGS_BUTTON_HEIGHT)
      .layoutWeight(1)
      .fontSize(14)
      .fontColor(AppTheme.text(this.localNpuExecutionMode === mode ? Color.White : settingsActionColor(SettingsActionKind.Primary)))
      .backgroundColor(this.localNpuExecutionMode === mode ?
        AppTheme.filledBackground(settingsActionColor(SettingsActionKind.Primary)) : $r('app.color.ui_surface_soft'))
      .borderRadius(SETTINGS_CONTROL_RADIUS)
      .onClick(() => {
        this.selectLocalNpuExecutionMode(mode);
      })
  }

  @Builder ChunkOmCacheActionRow() {
    SettingsActionButton({
      label: '查看缓存',
      kind: SettingsActionKind.Secondary,
      onActionClick: () => { this.onListChunkVisionOmFiles(); }
    })
    SettingsActionButton({
      label: '清理缓存',
      kind: SettingsActionKind.Danger,
      onActionClick: () => { this.confirmDeleteChunkVisionOmFiles(); }
    })
  }

  @Builder HdcConnectionGroup() {
    SettingInput({
      label: 'HDC Server',
      value: this.hdcServerIp,
      placeholder: '默认 ' + DEFAULT_ENDPOINT_CONFIG.hdcServerUrl,
      inputEnabled: this.hdcInputEditable(),
      onInputFocus: () => { this.closeSensitiveInputs(); },
      onValueChange: (value: string) => {
        this.hdcServerIp = value;
        this.manualHdcServerIp = value;
        this.onMarkHdcManualEditing();
      }
    })
    Text(this.hdcAutoStatus)
      .fontSize(12)
      .fontColor(AppTheme.text(this.hdcStatusColor()))
      .width('100%')
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: 8, bottom: 8 })
    SettingsActionRow({ contentBuilder: () => { this.HdcPairActionRow() } })
    this.FieldLabel('无线 HDC 目标')
    Row() {
      TextInput({ placeholder: '默认 ' + DEFAULT_ENDPOINT_CONFIG.wirelessHdcTarget, text: this.wirelessIp })
        .placeholderColor($r('app.color.ui_text_placeholder'))
        .caretColor($r('app.color.ui_accent_blue'))
        .height(SETTINGS_FIELD_HEIGHT)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(AppTheme.text(this.hdcInputTextColor()))
        .backgroundColor(AppTheme.background(this.hdcInputBackgroundColor()))
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .padding({ left: 12, right: 12 })
        .enabled(this.hdcInputEditable())
        .onClick(() => { this.closeSensitiveInputs(); })
        .onFocus(() => { this.closeSensitiveInputs(); })
        .onChange((value: string) => {
          this.wirelessIp = value;
          this.onMarkHdcManualEditing();
        })
      Button('连接测试')
        .height(SETTINGS_FIELD_HEIGHT)
        .width(92)
        .fontSize(13)
        .fontColor(AppTheme.text(Color.White))
        .backgroundColor(AppTheme.filledBackground(settingsActionColor(SettingsActionKind.Special)))
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .margin({ left: 10 })
        .enabled(this.hdcInputEditable())
        .onClick(async () => { await this.onTestAndConnectHdc(); })
    }
    .width('100%')
  }

  @Builder HdcPairActionRow() {
    SettingsActionButton({
      label: this.hdcAutoConnecting ? '自动连接中' : '自动连接',
      kind: SettingsActionKind.Primary,
      actionEnabled: !this.hdcAutoConnecting,
      onActionClick: async () => { await this.onDiscoverHdc(); }
    })
    SettingsActionButton({
      label: '手动配对',
      kind: this.hdcManualPairing ? SettingsActionKind.Special : SettingsActionKind.Secondary,
      onActionClick: () => { this.onSetHdcManualPairing(); }
    })
  }

  @Builder ModelDownloadGroup() {
    CollectionFormGroup({ title: this.localModelRecommendation.visible ?
      (this.localModelRecommendation.recommendedModelId.length > 0 ? '推荐模型 · 可切换' : '推荐模型 · 有更新') : '推荐模型',
      contentBuilder: (): void => { this.LocalModelRecommendationNotice(); }
    })
    CollectionFormGroup({ title: '自定义模型',
      contentBuilder: (): void => { this.CustomModelDownloadForm(); }
    })
    this.ModelDownloadProgressPanel()
  }

  private localModelDownloadBusy(): boolean {
    return this.downloading || this.modelScopeDownloading;
  }

  private recommendedModelIsSelected(): boolean {
    return this.localModelRecommendation.recommendedModelId.length > 0 &&
      this.selectedModelId === this.localModelRecommendation.recommendedModelId;
  }

  private recommendedModelButtonLabel(): string {
    if (this.recommendedModelIsSelected()) { return '使用中'; }
    if (this.localModelRecommendation.recommendedModelId.length > 0) { return '使用'; }
    if (this.modelScopePauseRequested &&
      normalizeLocalModelRepo(this.modelScopeMnnRepo) === this.localModelRecommendation.recommendedRepo) {
      return '继续下载';
    }
    return '下载';
  }

  private customModelDownloadPaused(): boolean {
    let repo = normalizeLocalModelRepo(this.customModelScopeMnnRepo);
    return repo.length > 0 && this.modelScopePauseRequested && repo === normalizeLocalModelRepo(this.modelScopeMnnRepo);
  }

  private async downloadCustomLocalModel(): Promise<void> {
    if (this.localModelDownloadBusy()) { return; }
    let repo = normalizeLocalModelRepo(this.customModelScopeMnnRepo);
    if (repo.length === 0) {
      showToastSafely('请输入 ModelScope 模型仓库，格式为 owner/model-name');
      return;
    }
    this.closeSensitiveInputs();
    this.modelScopeMnnRepo = repo;
    await this.onDownloadModelScopeModel();
  }

  @Builder LocalModelRecommendationNotice() {
    Row({ space: 16 }) {
      Column({ space: 6 }) {
        Text(this.localModelRecommendation.recommendedRepo.split('/')[1] || this.localModelRecommendation.recommendedRepo)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.localModelRecommendation.recommendedRepo.split('/')[0] + ' · ModelScope')
          .fontSize(12).fontColor($r('app.color.ui_text_secondary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button(this.recommendedModelButtonLabel())
        .height(36).width(84).padding({ left: 8, right: 8 }).fontSize(14)
        .fontColor(this.recommendedModelIsSelected() ? $r('app.color.ui_accent_blue') : $r('app.color.ui_text_on_fill'))
        .backgroundColor(this.recommendedModelIsSelected() ? AppTheme.background('#EEF4FF') : $r('app.color.ui_fill_blue'))
        .borderRadius(18).enabled(!this.localModelDownloadBusy() && !this.recommendedModelIsSelected())
        .onClick(async (): Promise<void> => {
          this.closeSensitiveInputs();
          await this.onUseRecommendedLocalModel();
        })
    }
    .width('100%').padding(16)
  }

  @Builder CustomModelDownloadForm() {
    ModelSettingsField({ label: '模型仓库', value: this.customModelScopeMnnRepo,
      placeholder: 'owner/model-name', editable: !this.localModelDownloadBusy(),
      onInputFocus: (): void => { this.closeSensitiveInputs(); },
      onValueChange: (value: string): void => { this.customModelScopeMnnRepo = value; }
    })
    CollectionFormDivider()
    Button(this.customModelDownloadPaused() ? '继续下载' : '下载模型')
      .width('100%').height(50).fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.ui_accent_blue')).backgroundColor(Color.Transparent)
      .enabled(!this.localModelDownloadBusy())
      .onClick(async (): Promise<void> => { await this.downloadCustomLocalModel(); })
  }

  @Builder ConfigOutputGroup() {
    Row() {
      Text('线程数')
        .fontSize(14)
        .fontColor(AppTheme.text(SETTINGS_MUTED_TEXT_COLOR))
        .width(58)
      TextInput({ text: this.threadNumInput })
        .fontColor($r('app.color.ui_text_primary'))
        .placeholderColor($r('app.color.ui_text_placeholder'))
        .caretColor($r('app.color.ui_accent_blue'))
        .type(InputType.Number)
        .width(76)
        .height(SETTINGS_BUTTON_HEIGHT)
        .fontSize(13)
        .backgroundColor(AppTheme.background(SETTINGS_INPUT_BACKGROUND_COLOR))
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .padding({ left: 10, right: 10 })
        .onChange((value: string) => { this.threadNumInput = value; })
      Button('修改 Config')
        .height(SETTINGS_BUTTON_HEIGHT)
        .layoutWeight(1)
        .fontSize(12)
        .fontColor(AppTheme.text(Color.White))
        .backgroundColor(AppTheme.filledBackground(settingsActionColor(SettingsActionKind.Primary)))
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .margin({ left: 10 })
        .onClick(() => { this.onUpdateConfigThreadNum(); })
      Button('查看 Config')
        .height(SETTINGS_BUTTON_HEIGHT)
        .layoutWeight(1)
        .fontSize(12)
        .fontColor(AppTheme.text(Color.White))
        .backgroundColor(AppTheme.filledBackground(settingsActionColor(SettingsActionKind.Success)))
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .margin({ left: 10 })
        .onClick(() => { this.onShowConfigJson(); })
    }
    .width('100%')
    SettingsOutputPanel({ title: '本地输出', content: this.output })
    SettingsOutputPanel({ title: '云端输出', content: this.cloudOutput, aiGenerated: true })
  }

  @Builder TaskAutomationSection() {
    Column() {
      this.SectionTitle(SettingsSectionId.TaskAutomation)
      SettingsGroupCard({
        title: this.debugEnabled ? 'Workflow 与日志' : 'Workflow 文件',
        subtitle: this.debugEnabled ? '查看 Workflow 配置、daily-log 和运行日志' : '查看 Workflow 配置和 daily-log',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.WorkflowLogGroup() }
      })
      SettingsGroupCard({
        title: 'PC 控制后端',
        subtitle: '启动云端 PC 控制后端供 Agent 自动化使用',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.PcBackendGroup() }
      })
    }
    .width(SETTINGS_PAGE_HORIZONTAL_PADDING)
    .margin({ top: 16, bottom: 110 })
  }

  @Builder WorkflowLogGroup() {
    SettingsActionRow({ contentBuilder: () => { this.WorkflowLogActionRow() } })
  }

  @Builder WorkflowLogActionRow() {
    SettingsActionButton({
      label: 'Workflow 文件',
      kind: SettingsActionKind.Success,
      onActionClick: () => { router.pushUrl({ url: 'pages/task/WorkflowFileViewer' }); }
    })
    if (this.debugEnabled) {
      SettingsActionButton({
        label: 'Runtime Logs',
        kind: SettingsActionKind.Success,
        onActionClick: () => { router.pushUrl({ url: 'pages/LogView' }); }
      })
    }
  }

  @Builder PcBackendGroup() {
    SettingsActionRow({ contentBuilder: () => { this.PcBackendActionRow() } })
  }

  @Builder PcBackendActionRow() {
    SettingsActionButton({
      label: '启动云端 PC 控制后端',
      kind: SettingsActionKind.Special,
      onActionClick: async () => { await this.onStartCloudBackend(); }
    })
  }

  @Builder StorageAboutSection() {
    Column() {
      this.SectionTitle(SettingsSectionId.StorageAbout)
      SettingsGroupCard({
        title: '文件查看',
        subtitle: this.debugEnabled ? '查看截图、模型文件树和运行日志' : '查看截图和模型文件树',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.FileViewerGroup() }
      })
      SettingsGroupCard({
        title: '清理操作',
        subtitle: '删除类操作会先弹窗确认',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.CleanupActionGroup() }
      })
      SettingsGroupCard({
        title: '调试工具',
        subtitle: '进入算子精度测试和 LLM Profile 页面',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.DebugToolsGroup() }
      })
      SettingsGroupCard({
        title: '关于',
        subtitle: '当前应用与设置说明',
        onHeaderClick: () => { this.closeSensitiveInputs(); },
        contentBuilder: () => { this.AboutSettingsGroup() }
      })
    }
    .width(SETTINGS_PAGE_HORIZONTAL_PADDING)
    .margin({ top: 16, bottom: 110 })
  }

  @Builder FileViewerGroup() {
    SettingsActionRow({ contentBuilder: () => { this.FileViewerActionRow() } })
  }

  @Builder FileViewerActionRow() {
    SettingsActionButton({
      label: '列出截图',
      kind: SettingsActionKind.Success,
      onActionClick: () => { this.onListScreenshots(); }
    })
    SettingsActionButton({
      label: '模型文件树',
      kind: SettingsActionKind.Success,
      onActionClick: () => { this.onListModelFilesTree(); }
    })
    if (this.debugEnabled) {
      SettingsActionButton({
        label: 'Runtime Logs',
        kind: SettingsActionKind.Success,
        onActionClick: () => { router.pushUrl({ url: 'pages/LogView' }); }
      })
    }
  }

  @Builder CleanupActionGroup() {
    SettingsActionRow({ contentBuilder: () => { this.CleanupPrimaryActionRow() } })
    SettingsActionRow({ contentBuilder: () => { this.CleanupModelActionRow() } })
  }

  @Builder CleanupPrimaryActionRow() {
    SettingsActionButton({
      label: '清理截图',
      kind: SettingsActionKind.Danger,
      onActionClick: () => { this.confirmClearScreenshots(); }
    })
    SettingsActionButton({
      label: '清理调试输出',
      kind: SettingsActionKind.Danger,
      onActionClick: () => { this.confirmDeleteDebugOutputs(); }
    })
  }

  @Builder CleanupModelActionRow() {
    SettingsActionButton({
      label: '删除 Config',
      kind: SettingsActionKind.Danger,
      onActionClick: () => { this.confirmDeleteModelConfigJson(); }
    })
    SettingsActionButton({
      label: '删除 chunk OM',
      kind: SettingsActionKind.Danger,
      onActionClick: () => { this.confirmDeleteChunkVisionOmFiles(); }
    })
  }

  @Builder DebugToolsGroup() {
    SettingsActionRow({ contentBuilder: () => { this.DebugToolsActionRow() } })
  }

  @Builder DebugToolsActionRow() {
    SettingsActionButton({
      label: 'Op Precision Test',
      kind: SettingsActionKind.Warning,
      onActionClick: () => { router.pushUrl({ url: 'pages/OpTest' }); }
    })
    SettingsActionButton({
      label: 'LLM Op Profile',
      kind: SettingsActionKind.Secondary,
      onActionClick: () => { router.pushUrl({ url: 'pages/ProfileTest' }); }
    })
  }

  @Builder AboutSettingsGroup() {
    Text('ClawMate')
      .fontSize(13)
      .fontColor(AppTheme.text(SETTINGS_SECONDARY_TEXT_COLOR))
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 6, bottom: 4 })
  }

  @Builder SettingsMainHeader() {
    AppHeader({ title: '我的' })
  }

  @Builder SettingsMainContent() {
    Scroll(this.pageScroller) {
      this.SettingsSectionList()
    }
    .width('100%')
    .height('100%')
    .clip(false)
  }

  @Builder SettingsDetailContent() {
    Scroll(this.detailScroller) {
      Column() {
        this.SelectedSectionContent()
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .padding({ top: APP_HEADER_CONTENT_GAP })
    }
    .width('100%')
    .height('100%')
    .clip(false)
    .onAppear((): void => { this.scheduleDetailScroll(); })
  }

  build() {
    if (isSettingsSectionSelected(this.selectedSectionId)) {
      FrostedPage({
        pageBackgroundColor: this.isCollectionSection() ? '#F2F2F7' : SETTINGS_PAGE_BACKGROUND_COLOR,
        scrollers: [this.detailScroller],
        headerBuilder: (): void => { this.SettingsDetailHeader(); },
        contentBuilder: (): void => { this.SettingsDetailContent(); }
      })
    } else {
      FrostedPage({
        pageBackgroundColor: '#F6F7F9',
        scrollers: [this.pageScroller],
        headerBuilder: (): void => { this.SettingsMainHeader(); },
        contentBuilder: (): void => { this.SettingsMainContent(); }
      })
    }
  }
}
