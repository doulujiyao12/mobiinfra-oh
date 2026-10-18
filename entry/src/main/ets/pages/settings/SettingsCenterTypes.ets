import { isMaskedSensitiveValue } from '../../utils/SensitiveValueUtils';

export enum SettingsSectionId {
  PersonalPrivacy = 0,
  DataCollection = 1,
  ModelAgents = 2,
  TaskAutomation = 3,
  StorageAbout = 4,
  CloudModelAdvanced = 5
}

export interface SettingsSectionItem {
  id: SettingsSectionId;
  title: string;
  subtitle: string;
}

export enum SettingsActionKind {
  Primary = 0,
  Secondary = 1,
  Success = 2,
  Warning = 3,
  Danger = 4,
  Special = 5
}

export interface SettingsConfirmConfig {
  title: string;
  message: string;
  confirmText: string;
}

export interface DownloadedModelItem {
  id: string;
  label: string;
  path: string;
  repo: string;
  sizeText: string;
  statusText: string;
  ready: boolean;
}

export const SETTINGS_SECTION_NONE: number = -1;
const SETTINGS_INPUT_SINGLE_LINE_LIMIT: number = 34;
const SETTINGS_SENSITIVE_INPUT_SINGLE_LINE_LIMIT: number = 24;

export const SETTINGS_SECTION_ITEMS: SettingsSectionItem[] = [
  {
    id: SettingsSectionId.ModelAgents,
    title: '模型与智能体',
    subtitle: '云端模型、本地推理与模型服务配置'
  },
  {
    id: SettingsSectionId.PersonalPrivacy,
    title: '个人与隐私',
    subtitle: '隐私授权、小艺记忆访问与动作确认'
  },
  {
    id: SettingsSectionId.DataCollection,
    title: '数据采集',
    subtitle: '微信汇总、OCR、图片缩放与地图配置'
  },
  {
    id: SettingsSectionId.TaskAutomation,
    title: '任务与自动化',
    subtitle: 'Agent 执行、Workflow 与运行日志'
  },
  {
    id: SettingsSectionId.StorageAbout,
    title: '存储与关于',
    subtitle: '模型文件、调试产物、版本与说明'
  }
];

// Secondary screen: it is reachable through Cloud Model's More Settings, not a sixth root settings item.
const CLOUD_MODEL_ADVANCED_SECTION: SettingsSectionItem = {
  id: SettingsSectionId.CloudModelAdvanced,
  title: '云端模型设置',
  subtitle: '按用途分别配置，填写后自动保存'
};

export function settingsSectionTitle(id: SettingsSectionId): string {
  if (id === SettingsSectionId.CloudModelAdvanced) { return CLOUD_MODEL_ADVANCED_SECTION.title; }
  for (let i = 0; i < SETTINGS_SECTION_ITEMS.length; i++) {
    if (SETTINGS_SECTION_ITEMS[i].id === id) {
      return SETTINGS_SECTION_ITEMS[i].title;
    }
  }
  return '';
}

export function settingsSectionSubtitle(id: SettingsSectionId): string {
  if (id === SettingsSectionId.CloudModelAdvanced) { return CLOUD_MODEL_ADVANCED_SECTION.subtitle; }
  for (let i = 0; i < SETTINGS_SECTION_ITEMS.length; i++) {
    if (SETTINGS_SECTION_ITEMS[i].id === id) {
      return SETTINGS_SECTION_ITEMS[i].subtitle;
    }
  }
  return '';
}

export function normalizeSettingsSectionId(id: number): number {
  if (id === SettingsSectionId.CloudModelAdvanced) { return id; }
  for (let i = 0; i < SETTINGS_SECTION_ITEMS.length; i++) {
    if (SETTINGS_SECTION_ITEMS[i].id === id) {
      return id;
    }
  }
  return SETTINGS_SECTION_NONE;
}

export function isSettingsSectionSelected(id: number): boolean {
  return normalizeSettingsSectionId(id) !== SETTINGS_SECTION_NONE;
}

export function settingsParentSection(id: number): number {
  return id === SettingsSectionId.CloudModelAdvanced ? SettingsSectionId.ModelAgents : SETTINGS_SECTION_NONE;
}

export function maskSensitiveSettingValue(value: string): string {
  if (value.length === 0) {
    return '';
  }
  if (value.length <= 4) {
    return '••••'.substring(0, value.length);
  }
  return value.substring(0, 4) + '••••••••' + value.substring(value.length - 4);
}

export function isMaskedSensitiveSettingValue(value: string): boolean {
  return isMaskedSensitiveValue(value);
}

export function restoreMaskedSensitiveSettingDefault(value: string, defaultValue: string): string {
  if (isMaskedSensitiveSettingValue(value)) {
    if (defaultValue.length > 0 && value === maskSensitiveSettingValue(defaultValue)) {
      return defaultValue;
    }
    return '';
  }
  return value;
}

function settingsTextExceedsSingleLine(text: string, singleLineLimit: number): boolean {
  let normalized = text.trim();
  if (normalized.indexOf('\n') >= 0) {
    return true;
  }
  return normalized.length > singleLineLimit;
}

// 设置页普通配置输入根据当前值或占位文案判断是否需要多行展示，避免 URL/模型名被单行截断。
export function settingsInputShouldUseMultiline(value: string, placeholder: string): boolean {
  let displayText = value.trim().length > 0 ? value : placeholder;
  return settingsTextExceedsSingleLine(displayText, SETTINGS_INPUT_SINGLE_LINE_LIMIT);
}

// 敏感配置右侧有显隐按钮，可用宽度更窄，因此使用更短阈值提前切到多行编辑/显示。
export function settingsSensitiveInputShouldUseMultiline(value: string, placeholder: string): boolean {
  let displayText = value.trim().length > 0 ? value : placeholder;
  return settingsTextExceedsSingleLine(displayText, SETTINGS_SENSITIVE_INPUT_SINGLE_LINE_LIMIT);
}
