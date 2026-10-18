export interface GalleryAnalyzerConfig {
  apiBaseUrl: string;
  apiKey: string;
  model: string;
  amapWebKey: string;
  skipOcr: boolean;
  useOcrKeywordFilter: boolean;
  ocrConcurrency: number;
  modelConcurrency: number;
  embeddingConcurrency: number;
  parallelFieldRequests: boolean;
  embeddingMode: string;
  embeddingBaseUrl: string;
  embeddingApiKey: string;
  embeddingModel: string;
  imageScale: number;
}

export interface GalleryPhotoInput {
  uri: string;
  id?: string;
  date?: string;
  latitude?: number;
  longitude?: number;
  hdcSourcePath?: string;
  hdcSourceSize?: number;
  hdcModifiedAt?: number;
  hdcChecksum?: string;
}

export interface GalleryExifMetadata {
  dateTimeOriginal?: string;
  deviceMake?: string;
  deviceModel?: string;
  imageWidth?: string;
  imageHeight?: string;
  orientation?: string;
  gpsLatitude?: string;
  gpsLongitude?: string;
  gpsLatitudeRef?: string;
  gpsLongitudeRef?: string;
  latitude?: number;
  longitude?: number;
}

// 全量图库扫描的单项状态。status 只描述流程状态，skipReason 用于解释真正跳过的原因。
export interface GalleryScanItem {
  uri: string;
  thumbnailUri?: string;
  id: string;
  date: string;
  status: string;
  error: string;
  skipReason?: string;
  hdcSourcePath?: string;
  hdcSourceSize?: number;
  hdcModifiedAt?: number;
  hdcChecksum?: string;
}

// 全量扫描会话的落盘快照，用于暂停、恢复和页面重新进入后的进度恢复。
export interface GalleryScanSession {
  id: string;
  status: string;
  createdAt: number;
  updatedAt: number;
  total: number;
  processed: number;
  skipped: number;
  failed: number;
  items: GalleryScanItem[];
  source?: string;
  requestedCount?: number;
}

// 月度 AI 总结缓存。signature 绑定当月分析结果，结果变化时旧总结会自动失效。
export interface GalleryMonthSummaryCacheRecord {
  signature: string;
  title: string;
  summary: string;
  suggestion: string;
  rawText: string;
  updatedAt: number;
}

// 经纬度逆地理编码缓存。raw 为 EXIF/Gallery 原始坐标，amap 为高德坐标转换后的坐标。
export interface GalleryLocationCacheRecord {
  key: string;
  provider: string;
  rawLatitude: number;
  rawLongitude: number;
  amapLatitude: number;
  amapLongitude: number;
  formattedAddress: string;
  province: string;
  city: string;
  district: string;
  township: string;
  street: string;
  poiName: string;
  updatedAt: number;
}

export interface GalleryAnalysisResult {
  id: string;
  uri: string;
  thumbnailUri?: string;
  // HDC source references are shell paths, not URIs the app can open directly.
  hdcSourcePath?: string;
  hdcSourceSize?: number;
  hdcModifiedAt?: number;
  hdcChecksum?: string;
  title: string;
  category: string;
  summary: string;
  details: string[];
  tags: string[];
  ocrText: string;
  rawModelText: string;
  keywords: string[];
  date: string;
  embeddingRef: string;
  embeddingStatus: string;
  embeddingDimension: number;
  error: string;
  latitude?: number;
  longitude?: number;
  exif?: GalleryExifMetadata;
  // 拍摄坐标解析后的实际地址。写入结果文件后，详情页可以复用，避免重复请求地图服务。
  location?: GalleryLocationCacheRecord;
  createdAt: number;
}

// 单张图片分析返回值。cached 表示复用已有结果，skippedByKeyword 才表示被 OCR 关键词预筛跳过。
export interface GalleryAnalyzeOutcome {
  result: GalleryAnalysisResult;
  cached: boolean;
  skippedByKeyword?: boolean;
}

export interface GalleryAnalyzeOptions {
  shouldPause?: () => boolean;
  prepareInput?: (input: GalleryPhotoInput) => Promise<void>;
  onPrepareError?: (input: GalleryPhotoInput, error: string) => void;
  onItemDone?: (input: GalleryPhotoInput, outcome: GalleryAnalyzeOutcome) => void;
}

export interface GalleryEmbeddingRecord {
  id: string;
  uri: string;
  date: string;
  category: string;
  text: string;
  vector: number[];
  model: string;
  mode: string;
  createdAt: number;
}

// 分析器运行态进度。它只记录本次批处理增量，页面会叠加扫描会话 baseline 得到全量进度。
export interface GalleryProgress {
  selected: number;
  processed: number;
  skipped: number;
  pending: number;
  ocrDone: number;
  modelDone: number;
  embeddingDone: number;
  failed: number;
  current: string;
}

export type GalleryProgressHandler = (progress: GalleryProgress) => void;

export interface GalleryModelJson {
  title?: string;
  category?: string;
  summary?: string;
  details?: string[];
  tags?: string[];
  importance?: number;
}
