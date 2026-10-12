export const WECHAT_AUTO_SUMMARY_ENABLED_KEY: string = 'wechatAutoSummaryEnabled';
export const WECHAT_AUTO_SUMMARY_DEFAULT_DAYS_KEY: string = 'wechatAutoSummaryDefaultDays';
export const WECHAT_AUTO_SUMMARY_DEFAULT_MAX_CONTACTS_KEY: string = 'wechatAutoSummaryDefaultMaxContacts';
export const WECHAT_AUTO_SUMMARY_SWIPE_SPEED_KEY: string = 'wechatAutoSummarySwipeSpeed';
export const WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO_KEY: string = 'wechatAutoSummaryHistorySwipeRatio';
export const WECHAT_AUTO_SUMMARY_STABLE_SWIPES_KEY: string = 'wechatAutoSummaryStableSwipes';
export const WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES_KEY: string = 'wechatAutoSummaryMaxHistorySwipes';
export const WECHAT_AUTO_SUMMARY_WAIT_KEY: string = 'wechatAutoSummaryWait';
export const WECHAT_AUTO_SUMMARY_COLLECTION_MODE_KEY: string = 'wechatAutoSummaryCollectionMode';
export const WECHAT_AUTO_SUMMARY_COLLECTION_DAYS_INPUT_KEY: string = 'wechatAutoSummaryCollectionDaysInput';
export const WECHAT_AUTO_SUMMARY_COLLECTION_MAX_CONTACTS_INPUT_KEY: string =
  'wechatAutoSummaryCollectionMaxContactsInput';
export const WECHAT_AUTO_SUMMARY_COLLECTION_TARGET_CONTACT_INPUT_KEY: string =
  'wechatAutoSummaryCollectionTargetContactInput';

export const DEFAULT_WECHAT_AUTO_SUMMARY_ENABLED: string = 'false';
export const DEFAULT_WECHAT_AUTO_SUMMARY_DAYS: string = '7';
export const DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS: string = '10';
export const DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED: string = '2000';
export const DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO: string = '0.4';
export const DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES: string = '3';
export const DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES: string = '80';
export const DEFAULT_WECHAT_AUTO_SUMMARY_WAIT: string = '1.0';

export const WECHAT_AUTO_SUMMARY_MODE_RECENT: string = 'recent_contacts';
export const WECHAT_AUTO_SUMMARY_MODE_TARGET: string = 'target_contact';

export type WechatAutoSummaryJsonValue = Object | string | number | boolean | null;
export type WechatAutoSummaryJsonMap = Record<string, WechatAutoSummaryJsonValue>;

// 微信自动汇总请求参数，对齐 PC 侧采集服务的 snake_case JSON 字段。
export interface WechatAutoSummaryRequest {
  mode: string;
  days: number;
  max_contacts: number;
  target_contact: string;
  max_list_swipes?: number;
  swipe_speed: number;
  history_swipe_ratio: number;
  stable_swipes: number;
  max_history_swipes: number;
  wait: number;
  output_dir?: string;
}

// 单条聊天消息的结构，sender 仅在服务端能识别发言人时返回。
export interface WechatAutoSummaryMessage {
  kind: string;
  text: string | null;
  sender?: string | null;
  bounds?: number[];
  text_bounds?: number[];
  image_bounds?: number[][];
}

// 服务端会标注采集覆盖的时间语义；visible_page_only 表示只汇总本次可见页采集结果。
export interface WechatAutoSummaryTimeRange {
  start?: string;
  end?: string;
  mode?: string;
}

export interface WechatAutoSummaryConversation {
  title: string | null;
  contact?: WechatAutoSummaryJsonMap;
  dump?: string;
  snapshots?: string[];
  messages: WechatAutoSummaryMessage[];
  time_range?: WechatAutoSummaryTimeRange;
  history_mode?: string;
}

export interface WechatAutoSummaryResponse {
  status: string;
  message?: string;
  run_id?: string;
  started_at?: string;
  finished_at?: string;
  mode?: string;
  days?: number;
  target_contact?: string;
  contacts_requested?: number;
  contacts_collected?: number;
  home_dump?: string;
  history_mode?: string;
  conversations?: WechatAutoSummaryConversation[];
  daily_log_entries?: string[];
  artifacts?: WechatAutoSummaryJsonMap;
}

function isInvalidNumber(value: number): boolean {
  return isNaN(value) || !isFinite(value);
}

function clampIntegerSetting(value: string, fallback: number, min: number, max: number): number {
  let text = value.trim();
  if (text.length === 0) {
    return fallback;
  }
  let parsed = Number(text);
  if (isInvalidNumber(parsed)) {
    return fallback;
  }
  let truncated = parsed < 0 ? Math.ceil(parsed) : Math.floor(parsed);
  if (truncated < min) {
    return min;
  }
  if (truncated > max) {
    return max;
  }
  return truncated;
}

function clampFloatSetting(value: string, fallback: number, min: number, max: number): number {
  let text = value.trim();
  if (text.length === 0) {
    return fallback;
  }
  let parsed = Number(text);
  if (isInvalidNumber(parsed)) {
    return fallback;
  }
  if (parsed < min) {
    return min;
  }
  if (parsed > max) {
    return max;
  }
  return parsed;
}

export function normalizeWechatAutoSummaryDays(value: string): number {
  return clampIntegerSetting(value, 7, 1, 90);
}

export function normalizeWechatAutoSummaryMaxContacts(value: string): number {
  return clampIntegerSetting(value, 10, 1, 50);
}

export function normalizeWechatAutoSummarySwipeSpeed(value: string): number {
  return clampIntegerSetting(value, 2000, 0, 20000);
}

export function normalizeWechatAutoSummaryHistorySwipeRatio(value: string): number {
  return clampFloatSetting(value, 0.4, 0.1, 0.95);
}

export function normalizeWechatAutoSummaryStableSwipes(value: string): number {
  return clampIntegerSetting(value, 3, 1, 10);
}

export function normalizeWechatAutoSummaryMaxHistorySwipes(value: string): number {
  return clampIntegerSetting(value, 80, 1, 300);
}

export function normalizeWechatAutoSummaryWait(value: string): number {
  return clampFloatSetting(value, 1.0, 0, 10);
}

export function normalizeWechatAutoSummaryMode(value: string): string {
  if (value === WECHAT_AUTO_SUMMARY_MODE_TARGET) {
    return WECHAT_AUTO_SUMMARY_MODE_TARGET;
  }
  return WECHAT_AUTO_SUMMARY_MODE_RECENT;
}

// 返回空字符串表示校验通过；非空中文文案可直接展示给用户。
export function validateWechatAutoSummaryRequest(request: WechatAutoSummaryRequest): string {
  if (request.mode !== WECHAT_AUTO_SUMMARY_MODE_RECENT && request.mode !== WECHAT_AUTO_SUMMARY_MODE_TARGET) {
    return '微信汇总采集模式无效';
  }
  if (isInvalidNumber(request.days) || request.days < 1 || request.days > 90) {
    return '汇总天数需在 1 到 90 天之间';
  }
  if (isInvalidNumber(request.max_contacts) || request.max_contacts < 1 || request.max_contacts > 50) {
    return '联系人数量需在 1 到 50 个之间';
  }
  if (isInvalidNumber(request.swipe_speed) || request.swipe_speed < 0 || request.swipe_speed > 20000) {
    return '滑动速度需在 0 到 20000 之间';
  }
  if (isInvalidNumber(request.history_swipe_ratio) || request.history_swipe_ratio < 0.1 ||
    request.history_swipe_ratio > 0.95) {
    return '历史滑动距离比例需在 0.1 到 0.95 之间';
  }
  if (isInvalidNumber(request.stable_swipes) || request.stable_swipes < 1 || request.stable_swipes > 10) {
    return '稳定判定次数需在 1 到 10 次之间';
  }
  if (isInvalidNumber(request.max_history_swipes) || request.max_history_swipes < 1 ||
    request.max_history_swipes > 300) {
    return '历史页最大滑动次数需在 1 到 300 次之间';
  }
  if (isInvalidNumber(request.wait) || request.wait < 0 || request.wait > 10) {
    return '页面等待时间需在 0 到 10 秒之间';
  }
  if (request.max_list_swipes !== undefined &&
    (isInvalidNumber(request.max_list_swipes) || request.max_list_swipes < 0 || request.max_list_swipes > 100)) {
    return '联系人列表最大滑动次数需在 0 到 100 次之间';
  }
  if (request.mode === WECHAT_AUTO_SUMMARY_MODE_TARGET && request.target_contact.trim().length === 0) {
    return '指定联系人模式需要填写联系人名称';
  }
  return '';
}
