export interface WorkflowSceneConfig {
  sceneId: number;
  tabId: string;
  label: string;
  color: string;
}

export const PERSONAL_INFO_MEMORY_SCENE_ID: number = 12;

const WORKFLOW_SCENES: WorkflowSceneConfig[] = [
  { sceneId: 0, tabId: 'shopping', label: '购物', color: '#765BFF' },
  { sceneId: 1, tabId: 'takeout', label: '外卖', color: '#39BFA3' },
  { sceneId: 2, tabId: 'entertainment', label: '娱乐', color: '#8066FF' },
  { sceneId: 3, tabId: 'chat', label: '聊天', color: '#4B8BFF' },
  { sceneId: 4, tabId: 'life', label: '生活', color: '#D97706' },
  { sceneId: 5, tabId: 'social', label: '社交', color: '#D9467D' },
  { sceneId: 6, tabId: 'travel', label: '差旅', color: '#0EA5E9' }
];

// DataManager 记忆层需要接纳图库分析和聊天提取的个人信息，工作流任务页仍只展示原 7 类采集场景。
// 图库“餐饮”与既有“外卖”消费场景合并，避免汇总页出现重复页签。
const MEMORY_EXTRA_SCENES: WorkflowSceneConfig[] = [
  { sceneId: 8, tabId: 'gallery-document', label: '文档', color: '#64748B' },
  { sceneId: 9, tabId: 'gallery-health', label: '健康', color: '#10B981' },
  { sceneId: 10, tabId: 'gallery-work', label: '办公', color: '#2563EB' },
  { sceneId: 11, tabId: 'gallery-other', label: '图库', color: '#9333EA' },
  { sceneId: PERSONAL_INFO_MEMORY_SCENE_ID, tabId: 'personal-info', label: '个人信息', color: '#4F6FA8' }
];

export function workflowSceneConfigs(): WorkflowSceneConfig[] {
  return WORKFLOW_SCENES.slice();
}

export function memorySceneConfigs(): WorkflowSceneConfig[] {
  return WORKFLOW_SCENES.concat(MEMORY_EXTRA_SCENES);
}

export function normalizeMemorySceneId(sceneId: number): number {
  // 早期图库接入曾使用 7 表示“餐饮”；该场景与既有“外卖”(1) 重复，统一迁移到外卖。
  if (sceneId === 7) {
    return 1;
  }
  return sceneId;
}

export function normalizeMemorySceneIds(sceneIds: number[]): number[] {
  let output: number[] = [];
  sceneIds.forEach((sceneId: number) => {
    let normalized = normalizeMemorySceneId(sceneId);
    if (!isNaN(normalized) && normalized >= 0 && output.indexOf(normalized) < 0) {
      output.push(normalized);
    }
  });
  return output.sort((left: number, right: number) => left - right);
}

export function workflowSceneById(sceneId: number): WorkflowSceneConfig {
  for (let scene of WORKFLOW_SCENES) {
    if (scene.sceneId === sceneId) {
      return scene;
    }
  }
  return WORKFLOW_SCENES[0];
}

export function workflowSceneByIndex(index: number): WorkflowSceneConfig {
  if (index >= 0 && index < WORKFLOW_SCENES.length) {
    return WORKFLOW_SCENES[index];
  }
  return WORKFLOW_SCENES[0];
}

export function workflowSceneLabel(sceneId: number): string {
  return workflowSceneById(sceneId).label;
}

export function memorySceneLabel(sceneId: number): string {
  let normalizedSceneId = normalizeMemorySceneId(sceneId);
  let scenes = memorySceneConfigs();
  for (let scene of scenes) {
    if (scene.sceneId === normalizedSceneId) {
      return scene.label;
    }
  }
  return workflowSceneLabel(normalizedSceneId);
}
