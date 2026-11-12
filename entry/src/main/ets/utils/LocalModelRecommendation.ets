import { DEFAULT_MODELSCOPE_MNN_REPO } from '../config/ModelDownloadConfig';

export const LOCAL_MODEL_RECOMMENDATION_IGNORED_REPO_KEY: string = 'localModelRecommendation.ignoredRepo';

export interface DownloadedModelItem {
  id: string;
  label: string;
  path: string;
  repo: string;
  sizeText: string;
  statusText: string;
  ready: boolean;
}

export interface LocalModelRecommendation {
  visible: boolean;
  currentName: string;
  currentRepo: string;
  recommendedRepo: string;
  recommendedModelId: string;
}

export function normalizeLocalModelRepo(value: string): string {
  let repo = value.trim().replace(/^modelscope:/i, '').replace(/^ModelScope\//i, '').replace(/\/$/, '');
  let parts = repo.split('/').map((part: string): string => part.trim());
  return parts.length === 2 && parts[0].length > 0 && parts[1].length > 0 ? parts.join('/') : '';
}

export function createLocalModelRecommendation(selectedId: string, models: DownloadedModelItem[],
  defaultRepo: string = DEFAULT_MODELSCOPE_MNN_REPO): LocalModelRecommendation {
  let recommended = normalizeLocalModelRepo(defaultRepo);
  let current = models.find((item: DownloadedModelItem): boolean => item.id === selectedId);
  let currentRepo = current ? normalizeLocalModelRepo(current.repo) : '';
  let installed = models.find((item: DownloadedModelItem): boolean =>
    item.ready && normalizeLocalModelRepo(item.repo) === recommended);
  return {
    visible: recommended.length > 0 && current !== undefined && current.ready && currentRepo !== recommended,
    currentName: current ? current.label : '',
    currentRepo: currentRepo,
    recommendedRepo: recommended,
    recommendedModelId: installed ? installed.id : ''
  };
}

export function shouldRemindLocalModelRecommendation(status: LocalModelRecommendation, ignoredRepo: string): boolean {
  return status.visible && normalizeLocalModelRepo(ignoredRepo) !== status.recommendedRepo;
}
