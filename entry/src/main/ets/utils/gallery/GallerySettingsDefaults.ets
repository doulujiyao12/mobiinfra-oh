import { DEFAULT_ENDPOINT_CONFIG } from '../../config/DefaultEndpointConfig';

// 图库分析默认复用 Planner。模型名为空时，CloudModelClient 不会发送 model 字段。
export const DEFAULT_GALLERY_API_BASE_URL: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl;
export const DEFAULT_GALLERY_API_KEY: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey;
export const DEFAULT_GALLERY_MODEL: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel;
export const DEFAULT_GALLERY_SKIP_OCR: string = 'false';
export const DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER: string = 'true';
export const DEFAULT_GALLERY_OCR_CONCURRENCY: string = '3';
export const DEFAULT_GALLERY_MODEL_CONCURRENCY: string = '2';
export const DEFAULT_GALLERY_EMBEDDING_CONCURRENCY: string = '2';
export const DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS: string = 'true';
export const DEFAULT_GALLERY_EMBEDDING_MODE: string = 'huawei_local';
export const DEFAULT_GALLERY_EMBEDDING_BASE_URL: string = 'https://api.siliconflow.cn/v1';
export const DEFAULT_GALLERY_EMBEDDING_API_KEY: string = 'sk-zbvephbixllqmbyegaxcssrfczkqciqfskkvkfpffqiftgdo';
export const DEFAULT_GALLERY_EMBEDDING_MODEL: string = 'BAAI/bge-m3';
export const DEFAULT_GALLERY_IMAGE_SCALE: string = '0.9';
export const DEFAULT_GALLERY_AMAP_WEB_KEY: string = 'c9ebe32082120fd93624aa545fc1fc7c';

export const GALLERY_EMBEDDING_API_KEY_DEFAULT_SNAPSHOT: string = 'galleryDefault.embeddingApiKey';
export const GALLERY_AMAP_WEB_KEY_DEFAULT_SNAPSHOT: string = 'galleryDefault.amapWebKey';
export const GALLERY_API_BASE_URL_DEFAULT_SNAPSHOT: string = 'galleryDefault.apiBaseUrl';
export const GALLERY_API_KEY_DEFAULT_SNAPSHOT: string = 'galleryDefault.apiKey';
export const GALLERY_MODEL_DEFAULT_SNAPSHOT: string = 'galleryDefault.model';

const LEGACY_GALLERY_API_BASE_URLS: string[] = [
  'https://api.modelbest.co/v1',
  'https://api.modelbest.cn/v1'
];
const LEGACY_GALLERY_MODEL: string = 'MiniCPM-V-4.6-Instruct';

export function galleryApiUsesLegacyDefaults(apiBaseUrl: string, model: string): boolean {
  return LEGACY_GALLERY_API_BASE_URLS.includes(apiBaseUrl.trim()) && model.trim() === LEGACY_GALLERY_MODEL;
}

export function registerGallerySettingsDefaults(): void {
  PersistentStorage.persistProp('galleryApiBaseUrl', DEFAULT_GALLERY_API_BASE_URL);
  PersistentStorage.persistProp('galleryApiKey', DEFAULT_GALLERY_API_KEY);
  PersistentStorage.persistProp('galleryModel', DEFAULT_GALLERY_MODEL);
  PersistentStorage.persistProp('gallerySkipOcr', DEFAULT_GALLERY_SKIP_OCR);
  PersistentStorage.persistProp('galleryUseOcrKeywordFilter', DEFAULT_GALLERY_USE_OCR_KEYWORD_FILTER);
  PersistentStorage.persistProp('galleryOcrConcurrency', DEFAULT_GALLERY_OCR_CONCURRENCY);
  PersistentStorage.persistProp('galleryModelConcurrency', DEFAULT_GALLERY_MODEL_CONCURRENCY);
  PersistentStorage.persistProp('galleryEmbeddingConcurrency', DEFAULT_GALLERY_EMBEDDING_CONCURRENCY);
  PersistentStorage.persistProp('galleryParallelFieldRequests', DEFAULT_GALLERY_PARALLEL_FIELD_REQUESTS);
  PersistentStorage.persistProp('galleryEmbeddingMode', DEFAULT_GALLERY_EMBEDDING_MODE);
  PersistentStorage.persistProp('galleryEmbeddingBaseUrl', DEFAULT_GALLERY_EMBEDDING_BASE_URL);
  PersistentStorage.persistProp('galleryEmbeddingApiKey', DEFAULT_GALLERY_EMBEDDING_API_KEY);
  PersistentStorage.persistProp('galleryEmbeddingModel', DEFAULT_GALLERY_EMBEDDING_MODEL);
  PersistentStorage.persistProp('galleryImageScale', DEFAULT_GALLERY_IMAGE_SCALE);
  PersistentStorage.persistProp('galleryAmapWebKey', DEFAULT_GALLERY_AMAP_WEB_KEY);
  PersistentStorage.persistProp(GALLERY_EMBEDDING_API_KEY_DEFAULT_SNAPSHOT, '');
  PersistentStorage.persistProp(GALLERY_AMAP_WEB_KEY_DEFAULT_SNAPSHOT, '');
  PersistentStorage.persistProp(GALLERY_API_BASE_URL_DEFAULT_SNAPSHOT, '');
  PersistentStorage.persistProp(GALLERY_API_KEY_DEFAULT_SNAPSHOT, '');
  PersistentStorage.persistProp(GALLERY_MODEL_DEFAULT_SNAPSHOT, '');
}
