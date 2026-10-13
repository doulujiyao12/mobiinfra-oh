import { PhoneHdcWorkflowBridge } from '../selfhdc/PhoneHdcWorkflowBridge';
import { WorkflowJsonMap } from '../WorkflowTypes';
import { wechatAutoSummaryDailyEntries } from './WechatAutoSummaryStorage';
import {
  WechatAutoSummaryConversation,
  WechatAutoSummaryJsonMap,
  WechatAutoSummaryMessage,
  WechatAutoSummaryRequest,
  WechatAutoSummaryResponse
} from './WechatAutoSummaryTypes';

type UiNode = Record<string, Object>;

interface Bounds { x1: number; y1: number; x2: number; y2: number; }
interface PhoneContact { name: string; preview: string; x: number; y: number; }
interface Point { x: number; y: number; }
interface SenderInference { role: string; basis: string; }
interface ChatEntry {
  kind: string;
  text: string;
  sender: string;
  senderRole: string;
  senderBasis: string;
  bounds: Bounds | null;
  textBounds: Bounds | null;
  images: Bounds[];
}
interface GuiSleep { action: string; seconds: number; }
interface GuiClick { action: string; x: number; y: number; }
interface GuiInput { action: string; x: number; y: number; text: string; submit_enter: boolean; }
interface GuiKey { action: string; key: string; }
interface GuiSwipe { action: string; direction: string; swipe_speed: number; }
interface GuiSwipeCoords {
  action: string;
  start_x: number;
  start_y: number;
  end_x: number;
  end_y: number;
  swipe_speed: number;
}
interface PhoneTimeRange { mode: string; start?: string; end?: string; }
interface PhoneContactMap { name: string; preview: string; }
interface PhoneConversation {
  title: string;
  contact: WechatAutoSummaryJsonMap;
  messages: WechatAutoSummaryMessage[];
  history_mode: string;
  time_range: PhoneTimeRange;
}

interface PhoneWechatTestAttributes {
  type: string;
  text?: string;
  bounds?: string;
  origBounds?: string;
  scrollable?: string;
}

interface PhoneWechatTestNode {
  attributes: PhoneWechatTestAttributes;
  children: PhoneWechatTestNode[];
}

function text(value: Object | undefined): string {
  return value === undefined || value === null ? '' : String(value).trim();
}

function children(node: UiNode): UiNode[] {
  let value = node['children'];
  return Array.isArray(value) ? value as UiNode[] : [];
}

function attrs(node: UiNode): UiNode {
  let value = node['attributes'];
  return value !== undefined && typeof value === 'object' ? value as UiNode : {};
}

function typeOf(node: UiNode): string { return text(attrs(node)['type']); }

function walk(node: UiNode, output: UiNode[] = []): UiNode[] {
  output.push(node);
  for (let child of children(node)) { walk(child, output); }
  return output;
}

function bounds(node: UiNode): Bounds | null {
  let value = text(attrs(node)['origBounds']) || text(attrs(node)['bounds']);
  let match = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(value);
  if (match === null) { return null; }
  return { x1: Number(match[1]), y1: Number(match[2]), x2: Number(match[3]), y2: Number(match[4]) };
}

function center(value: Bounds | null): Point {
  if (value === null) { return { x: 0, y: 0 } as Point; }
  return { x: Math.floor((value.x1 + value.x2) / 2), y: Math.floor((value.y1 + value.y2) / 2) } as Point;
}

function asArray(value: Bounds | null): number[] | undefined {
  return value === null ? undefined : [value.x1, value.y1, value.x2, value.y2];
}

function imageBounds(node: UiNode): Bounds[] {
  let result: Bounds[] = [];
  for (let candidate of walk(node)) {
    if (typeOf(candidate) === 'Image') {
      let value = bounds(candidate); if (value !== null) { result.push(value); }
    }
  }
  return result;
}

function textNodes(node: UiNode): string[] {
  let result: string[] = [];
  for (let candidate of walk(node)) {
    if (typeOf(candidate) === 'Text') {
      let value = text(attrs(candidate)['text']);
      if (value.length > 0) { result.push(value); }
    }
  }
  return result;
}

function lists(root: UiNode): UiNode[] { return walk(root).filter((node: UiNode): boolean => typeOf(node) === 'List'); }

function bestList(root: UiNode, preferScrollable: boolean = false): UiNode | null {
  let all = lists(root); let selected: UiNode | null = null; let score = -1;
  for (let list of all) {
    let count = children(list).filter((node: UiNode): boolean => typeOf(node) === 'ListItem').length;
    let area = bounds(list); let areaScore = area === null ? 0 : (area.x2 - area.x1) * (area.y2 - area.y1);
    let scrollScore = preferScrollable && text(attrs(list)['scrollable']) === 'true' ? 1000000000 : 0;
    if (scrollScore + count * 1000000 + areaScore > score) {
      selected = list; score = scrollScore + count * 1000000 + areaScore;
    }
  }
  return selected;
}

function contacts(root: UiNode): PhoneContact[] {
  let list = bestList(root); if (list === null) { return []; }
  let result: PhoneContact[] = [];
  for (let item of children(list)) {
    if (typeOf(item) !== 'ListItem') { continue; }
    let values = textNodes(item); if (values.length === 0 || values[0] === '搜索') { continue; }
    let point = center(bounds(item)); if (point.x <= 0 || point.y <= 0) { continue; }
    result.push({ name: values[0], preview: values.slice(1).join(' '), x: point.x, y: point.y });
  }
  return result;
}

// 内容图片不应被当成头像：只在屏幕边缘的小尺寸近方形节点中选择头像。
function avatar(images: Bounds[], screenWidth: number): Bounds | null {
  let candidates: Bounds[] = images.filter((value: Bounds): boolean => {
    let width = value.x2 - value.x1; let height = value.y2 - value.y1;
    let centerX = (value.x1 + value.x2) / 2;
    let nearEdge = centerX <= screenWidth * 0.2 || centerX >= screenWidth * 0.8;
    return width >= 40 && height >= 40 && width <= 180 && height <= 180 && nearEdge &&
      Math.abs(width - height) <= Math.max(width, height) * 0.35;
  });
  if (candidates.length === 0) { return null; }
  candidates.sort((a: Bounds, b: Bounds): number => (a.x2 - a.x1) * (a.y2 - a.y1) - (b.x2 - b.x1) * (b.y2 - b.y1));
  return candidates[0];
}

// 无法可靠识别方向时保留 unknown，避免把本人或系统消息错误归到联系人名下。
function inferSender(images: Bounds[], textBounds: Bounds | null, screenCenter: number,
  screenWidth: number): SenderInference {
  let avatarBounds = avatar(images, screenWidth);
  if (avatarBounds !== null) {
    return { role: center(avatarBounds).x > screenCenter ? 'self' : 'other', basis: 'avatar' };
  }
  if (textBounds === null) { return { role: 'unknown', basis: 'unresolved' }; }
  let textCenter = center(textBounds).x;
  let margin = screenWidth * 0.08;
  if (textCenter > screenCenter + margin) { return { role: 'self', basis: 'text_bounds' }; }
  if (textCenter < screenCenter - margin) { return { role: 'other', basis: 'text_bounds' }; }
  return { role: 'unknown', basis: 'ambiguous_text_bounds' };
}

function mediaPlaceholder(images: Bounds[], screenWidth: number): string {
  let avatarBounds = avatar(images, screenWidth);
  return images.filter((value: Bounds): boolean => avatarBounds === null || value !== avatarBounds).length > 0 ? '[图片]' : '[文件]';
}

function isTimeSeparator(values: string[], textBounds: Bounds | null, images: Bounds[], screenCenter: number): boolean {
  if (images.length > 0 || values.length !== 1) { return false; }
  return textBounds === null || Math.abs(center(textBounds).x - screenCenter) <= screenCenter * 0.35;
}

function extractChatEntries(root: UiNode, fallback: string): ChatEntry[] {
  let list = bestList(root, true); if (list === null) { return []; }
  let rootBounds = bounds(root); let listBounds = bounds(list);
  let screenWidth = rootBounds === null ? (listBounds === null ? 1080 : listBounds.x2 - listBounds.x1) : rootBounds.x2 - rootBounds.x1;
  let screenCenter = screenWidth / 2; let result: ChatEntry[] = [];
  let items = children(list).filter((node: UiNode): boolean => typeOf(node) === 'ListItem');
  items.sort((a: UiNode, b: UiNode): number => (bounds(a)?.y1 || 0) - (bounds(b)?.y1 || 0));
  for (let item of items) {
    let values = textNodes(item); let images = imageBounds(item); let itemBounds = bounds(item);
    let textBounds: Bounds | null = null;
    for (let candidate of walk(item)) {
      if (typeOf(candidate) === 'Text' && text(attrs(candidate)['text']).length > 0) { textBounds = bounds(candidate); break; }
    }
    if (values.length === 0 && images.length === 0) { continue; }
    if (isTimeSeparator(values, textBounds, images, screenCenter)) {
      result.push({ kind: 'time', text: values[0], sender: '', senderRole: 'unknown', senderBasis: 'time_separator',
        bounds: itemBounds, textBounds: textBounds, images: images });
    } else {
      let inference = inferSender(images, textBounds, screenCenter, screenWidth);
      result.push({ kind: 'message', text: values.length > 0 ? values.join('\n') : mediaPlaceholder(images, screenWidth),
        sender: inference.role, senderRole: inference.role, senderBasis: inference.basis,
        bounds: itemBounds, textBounds: textBounds, images: images });
    }
  }
  return result;
}

function chatMessages(root: UiNode, fallback: string): WechatAutoSummaryMessage[] {
  return extractChatEntries(root, fallback).map((entry: ChatEntry): WechatAutoSummaryMessage => {
    let imageValues: number[][] = entry.images.map((value: Bounds): number[] => asArray(value) as number[]);
    let item: WechatAutoSummaryMessage = { kind: entry.kind, text: entry.text,
      sender: entry.sender === 'other' ? fallback : entry.sender, sender_role: entry.senderRole,
      sender_basis: entry.senderBasis };
    let itemBounds = asArray(entry.bounds); let textBounds = asArray(entry.textBounds);
    if (itemBounds !== undefined) { item.bounds = itemBounds; }
    if (textBounds !== undefined) { item.text_bounds = textBounds; }
    if (imageValues.length > 0) { item.image_bounds = imageValues; }
    return item;
  });
}

function normalizeHour(hour: number, period: string): number {
  if ((period === '下午' || period === '晚上') && hour < 12) { return hour + 12; }
  if (period === '中午' && hour < 11) { return hour + 12; }
  if (period === '凌晨' && hour === 12) { return 0; }
  return hour;
}

function parsedChatTime(value: string, reference: Date): number | null {
  let timeMatch = /(上午|下午|晚上|凌晨|中午)?\s*(\d{1,2}):(\d{2})/.exec(value);
  let date = new Date(reference.getTime()); let hasDate = false;
  if (value.indexOf('昨天') >= 0) { date.setDate(date.getDate() - 1); hasDate = true; }
  else if (value.indexOf('今天') >= 0) { hasDate = true; }
  let md = /(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)?/.exec(value);
  let slash = /(\d{1,2})\/(\d{1,2})/.exec(value);
  let weekday = /星期([一二三四五六日天])/.exec(value);
  if (md !== null) {
    let year = Number(md[1] || reference.getFullYear()); let month = Number(md[2]); let day = Number(md[3]);
    date = new Date(year, month - 1, day);
    if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) { return null; }
    hasDate = true;
  } else if (slash !== null) {
    let month = Number(slash[1]); let day = Number(slash[2]);
    date = new Date(reference.getFullYear(), month - 1, day);
    if (date.getMonth() !== month - 1 || date.getDate() !== day) { return null; }
    hasDate = true;
  }
  else if (weekday !== null) {
    let map: Record<string, number> = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 0, '天': 0 };
    let current = date.getDay(); let wanted = map[weekday[1]]; date.setDate(date.getDate() - ((current - wanted + 7) % 7)); hasDate = true;
  }
  if (timeMatch !== null) {
    date.setHours(normalizeHour(Number(timeMatch[2]), timeMatch[1] || ''), Number(timeMatch[3]), 0, 0); hasDate = true;
  } else if (hasDate) { date.setHours(0, 0, 0, 0); }
  return hasDate ? date.getTime() : null;
}

function cutoffTimestamp(days: number, reference: Date): number {
  let value = new Date(reference.getTime()); value.setHours(0, 0, 0, 0); value.setDate(value.getDate() - Math.max(days - 1, 0));
  return value.getTime();
}

function viewport(root: UiNode): Bounds | null {
  let rootBounds = bounds(root); if (rootBounds !== null) { return rootBounds; }
  let list = bestList(root, true); return list === null ? null : bounds(list);
}

function atBoundary(entry: ChatEntry, view: Bounds | null, top: boolean): boolean {
  if (entry.bounds === null || view === null) { return false; }
  let height = Math.max(0, view.y2 - view.y1); if (height <= 0) { return false; }
  let margin = height * 0.2;
  return top ? entry.bounds.y1 <= view.y1 + margin || entry.bounds.y2 <= view.y1 + margin :
    entry.bounds.y2 >= view.y2 - margin || entry.bounds.y1 >= view.y2 - margin;
}

function overlapKey(entry: ChatEntry): string {
  if (entry.kind !== 'message' || entry.text === '[图片]' || entry.text === '[文件]') { return ''; }
  return entry.sender + '|' + entry.text.replace(/\s+/g, ' ');
}

function entryKey(entry: ChatEntry, time: number | null): string {
  return entry.kind + '|' + entry.sender + '|' + entry.text + '|' + (time === null ? '' : String(Math.floor(time / 60000))) +
    '|' + entry.images.map((value: Bounds): string => value.x1 + ',' + value.y1 + ',' + value.x2 + ',' + value.y2).join(';');
}

function dayStart(timestamp: number): number {
  let value = new Date(timestamp); value.setHours(0, 0, 0, 0); return value.getTime();
}

function mergeSnapshots(roots: UiNode[], title: string, days: number, reference: Date): WechatAutoSummaryMessage[] {
  let cutoff = cutoffTimestamp(days, reference); let merged: WechatAutoSummaryMessage[] = [];
  let seen: string[] = []; let previousBottom: string[] = [];
  let currentTime: number | null = null; let timeBeforeCurrentTime: number | null = null;
  for (let index = roots.length - 1; index >= 0; index--) {
    let root = roots[index]; let entries = extractChatEntries(root, title); let view = viewport(root);
    let firstTime: number | null = null;
    for (let entry of entries) { if (entry.kind === 'time') { firstTime = parsedChatTime(entry.text, reference); if (firstTime !== null) { break; } } }
    let incomingTime = currentTime; let incomingBeforeAnchor = timeBeforeCurrentTime;
    let prefixTime: number | null = null;
    if (firstTime === null) {
      prefixTime = incomingTime;
    } else if (incomingTime !== null && incomingTime < firstTime) {
      prefixTime = incomingTime;
    } else if (incomingTime !== null && incomingTime === firstTime) {
      prefixTime = incomingBeforeAnchor;
    }
    let skipUnanchoredUntilFirstTime = cutoff > 0 && prefixTime === null && firstTime !== null &&
      dayStart(firstTime) <= dayStart(cutoff);
    let hasSeenRootTime = false; let bottom: string[] = [];
    for (let entry of entries) {
      let entryTime = entry.kind === 'time' ? parsedChatTime(entry.text, reference) : null;
      if (skipUnanchoredUntilFirstTime && !hasSeenRootTime && entryTime === null) { continue; }
      if (entryTime !== null) {
        timeBeforeCurrentTime = currentTime; currentTime = entryTime; hasSeenRootTime = true;
      }
      let effective = entryTime !== null ? entryTime : (hasSeenRootTime ? currentTime : prefixTime);
      if (effective !== null && effective < cutoff) { let key = overlapKey(entry); if (key !== '' && atBoundary(entry, view, false)) { bottom.push(key); } continue; }
      let key = overlapKey(entry);
      if (key !== '' && atBoundary(entry, view, true) && previousBottom.indexOf(key) >= 0) { continue; }
      let fullKey = entryKey(entry, effective); if (seen.indexOf(fullKey) >= 0) { continue; }
      seen.push(fullKey);
      let item: WechatAutoSummaryMessage = { kind: entry.kind, text: entry.text,
        sender: entry.sender === 'other' ? title : entry.sender, sender_role: entry.senderRole,
        sender_basis: entry.senderBasis };
      let itemBounds = asArray(entry.bounds); let textBounds = asArray(entry.textBounds);
      if (itemBounds !== undefined) { item.bounds = itemBounds; }
      if (textBounds !== undefined) { item.text_bounds = textBounds; }
      if (entry.images.length > 0) { item.image_bounds = entry.images.map((value: Bounds): number[] => asArray(value) as number[]); }
      merged.push(item);
      if (key !== '' && atBoundary(entry, view, false)) { bottom.push(key); }
    }
    previousBottom = bottom;
  }
  return merged;
}

function payload(map: Record<string, Object>): WorkflowJsonMap { return map as Object as WorkflowJsonMap; }

// 供 Hypium 纯逻辑测试构造最小 UI dump；生产采集不依赖这些测试辅助方法。
export function phoneWechatTestNode(type: string, value: string, nodeBounds: string,
  childNodes: Object[] = [], scrollable: boolean = false): Object {
  let attributes: PhoneWechatTestAttributes = { type: type, text: value, origBounds: nodeBounds };
  if (scrollable) { attributes.scrollable = 'true'; }
  let children: PhoneWechatTestNode[] = childNodes.map((child: Object): PhoneWechatTestNode => child as PhoneWechatTestNode);
  let node: PhoneWechatTestNode = { attributes: attributes, children: children };
  return node as Object;
}

export function parsePhoneWechatChatTimeForTest(value: string, referenceIso: string): string {
  let parsed = parsedChatTime(value, new Date(referenceIso));
  return parsed === null ? '' : new Date(parsed).toISOString();
}

export function mergePhoneWechatSnapshotsForTest(roots: Object[], title: string, days: number,
  referenceIso: string): WechatAutoSummaryMessage[] {
  return mergeSnapshots(roots as UiNode[], title, days, new Date(referenceIso));
}

// 以最小 UI 树校验发送方向和导出字段，不依赖设备或云端模型。
export function extractPhoneWechatMessagesForTest(root: Object, title: string): WechatAutoSummaryMessage[] {
  return chatMessages(root as UiNode, title);
}

// 每个联系人解析完成后同步回调；调用方应完成落盘后再允许继续操作下一个联系人。
export type PhoneWechatConversationProgress =
  (conversation: WechatAutoSummaryConversation, collectedCount: number) => void;

/** 手机侧微信结构化采集器：只依赖 HDC + dumpLayout + 规则解析，不调用 Agent/VLM。 */
export class PhoneWechatCollector {
  private bridge: PhoneHdcWorkflowBridge;
  private log: (message: string) => void;

  constructor(bridge: PhoneHdcWorkflowBridge, log: (message: string) => void = (_: string): void => {}) {
    this.bridge = bridge; this.log = log;
  }

  private async wait(seconds: number): Promise<void> {
    if (seconds <= 0) { return; }
    let action: GuiSleep = { action: 'sleep', seconds: seconds };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private async tap(x: number, y: number): Promise<void> {
    let action: GuiClick = { action: 'click', x: x, y: y };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private async inputAt(x: number, y: number, value: string): Promise<void> {
    let action: GuiInput = { action: 'input', x: x, y: y, text: value, submit_enter: true };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private async back(): Promise<void> {
    let action: GuiKey = { action: 'keyevent', key: 'BACK' };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private async swipeUp(speed: number): Promise<void> {
    let action: GuiSwipe = { action: 'swipe', direction: 'up', swipe_speed: speed };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private async swipeHistory(root: UiNode, ratio: number, speed: number): Promise<void> {
    let rootBounds = bounds(root); let list = bestList(root, true);
    let view = rootBounds !== null ? rootBounds : (list === null ? null : bounds(list));
    let x = view === null ? 540 : Math.floor((view.x1 + view.x2) / 2);
    let top = view === null ? 500 : view.y1;
    let bottom = view === null ? 2200 : view.y2;
    let distance = Math.max(40, (bottom - top) * ratio / 2);
    let middle = (top + bottom) / 2;
    let action: GuiSwipeCoords = { action: 'swipe_with_coords', start_x: x,
      start_y: Math.floor(middle - distance), end_x: x, end_y: Math.floor(middle + distance), swipe_speed: speed };
    await this.bridge.guiAction(payload(action as Object as Record<string, Object>));
  }

  private reachesCutoff(root: UiNode, days: number, reference: Date): boolean {
    let cutoff = cutoffTimestamp(days, reference);
    for (let entry of extractChatEntries(root, '')) {
      if (entry.kind === 'time') {
        let parsed = parsedChatTime(entry.text, reference);
        if (parsed !== null && parsed < cutoff) { return true; }
      }
    }
    return false;
  }

  private fingerprint(root: UiNode): string {
    return extractChatEntries(root, '').map((entry: ChatEntry): string =>
      entry.kind + '|' + entry.sender + '|' + entry.text).join('||');
  }

  private async findTarget(root: UiNode, name: string): Promise<PhoneContact | null> {
    let target = name.trim().toLocaleLowerCase();
    for (let item of contacts(root)) {
      let candidate = item.name.toLocaleLowerCase();
      if (candidate === target || candidate.indexOf(target) >= 0 || target.indexOf(candidate) >= 0) { return item; }
    }
    for (let node of walk(root)) {
      if (typeOf(node) !== 'Text' || text(attrs(node)['text']).toLocaleLowerCase().indexOf(target) < 0) { continue; }
      let point = center(bounds(node));
      if (point.x > 0 && point.y > 0) { return { name: name, preview: '', x: point.x, y: point.y }; }
    }
    return null;
  }

  private searchEntry(root: UiNode): Point | null {
    let candidates: Point[] = [];
    for (let node of walk(root)) {
      if (typeOf(node) === 'Text' && text(attrs(node)['text']) === '搜索') {
        let point = center(bounds(node)); if (point.x > 0 && point.y > 0) { candidates.push(point); }
      }
    }
    return candidates.length > 0 ? candidates[0] : null;
  }

  async collect(request: WechatAutoSummaryRequest,
    onConversation: PhoneWechatConversationProgress = (_conversation: WechatAutoSummaryConversation,
      _collectedCount: number): void => {}, runId: string = ''): Promise<WechatAutoSummaryResponse> {
    let started = new Date().toISOString();
    let referenceNow = new Date();
    await this.bridge.startApp('微信', 'com.tencent.wechat', true);
    await this.wait(request.wait);
    let conversations: WechatAutoSummaryConversation[] = [];
    let seen: string[] = [];
    let pages = request.mode === 'recent_contacts' ? (request.max_list_swipes === undefined ? 10 : request.max_list_swipes) : 0;
    let selected: PhoneContact[] = [];
    for (let page = 0; page <= pages && selected.length < request.max_contacts; page++) {
      let root = await this.bridge.dumpUiTree('wechat-home');
      let pageContacts = request.mode === 'target_contact' ? await this.findTarget(root, request.target_contact) : null;
      let activeRoot = root;
      if (request.mode === 'target_contact' && pageContacts === null) {
        let search = this.searchEntry(root);
        if (search !== null) {
          await this.tap(search.x, search.y); await this.wait(request.wait);
          await this.inputAt(search.x, search.y, request.target_contact); await this.wait(request.wait);
          activeRoot = await this.bridge.dumpUiTree('wechat-search-results');
          pageContacts = await this.findTarget(activeRoot, request.target_contact);
        }
      }
      let candidates: PhoneContact[] = request.mode === 'target_contact' ?
        (pageContacts === null ? [] : [pageContacts]) : contacts(activeRoot);
      for (let item of candidates) {
        if (seen.indexOf(item.name) < 0) { seen.push(item.name); selected.push(item); }
        if (request.mode === 'target_contact' || selected.length >= request.max_contacts) { break; }
      }
      if (request.mode === 'target_contact' || selected.length >= request.max_contacts || page === pages) { break; }
      await this.swipeUp(request.swipe_speed); await this.wait(request.wait);
    }
    if (selected.length === 0) { throw new Error('手机侧未识别到微信联系人，请确认已进入聊天首页'); }
    for (let item of selected) {
      await this.tap(item.x, item.y); await this.wait(request.wait);
      let roots: UiNode[] = [];
      let lastFingerprint = '';
      let stable = 0;
      let maxHistory = Math.max(0, request.max_history_swipes);
      for (let swipe = 0; swipe <= maxHistory; swipe++) {
        let root = await this.bridge.dumpUiTree('wechat-chat');
        roots.push(root);
        let currentFingerprint = this.fingerprint(root);
        stable = currentFingerprint === lastFingerprint ? stable + 1 : 0;
        lastFingerprint = currentFingerprint;
        if (this.reachesCutoff(root, request.days, referenceNow) || stable >= request.stable_swipes || swipe >= maxHistory) { break; }
        await this.swipeHistory(root, request.history_swipe_ratio, request.swipe_speed);
        await this.wait(request.wait);
      }
      let messages = mergeSnapshots(roots, item.name, request.days, referenceNow);
      let parsedTimes: number[] = [];
      for (let message of messages) {
        if (message.kind === 'time' && message.text !== null) {
          let parsed = parsedChatTime(message.text, referenceNow); if (parsed !== null) { parsedTimes.push(parsed); }
        }
      }
      let timeRange: PhoneTimeRange = { mode: roots.length > 1 ? 'history_scrolled' : 'visible_page_only' };
      if (parsedTimes.length > 0) {
        parsedTimes.sort((a: number, b: number): number => a - b);
        timeRange.start = new Date(parsedTimes[0]).toISOString();
        timeRange.end = new Date(parsedTimes[parsedTimes.length - 1]).toISOString();
      }
      let contact: PhoneContactMap = { name: item.name, preview: item.preview };
      let conversation: PhoneConversation = { title: item.name,
        contact: contact as Object as WechatAutoSummaryJsonMap, messages: messages,
        history_mode: roots.length > 1 ? 'history_scrolled' : 'visible_page_only', time_range: timeRange };
      conversations.push(conversation as WechatAutoSummaryConversation);
      onConversation(conversation as WechatAutoSummaryConversation, conversations.length);
      await this.back(); await this.wait(request.wait);
    }
    this.log('PHONE_WECHAT_COLLECT conversations=' + conversations.length + ' mode=' + request.mode);
    let response: WechatAutoSummaryResponse = { status: 'ok', message: 'phone collected ' + conversations.length + ' conversations',
      run_id: runId.length > 0 ? runId : 'wechat-phone-' + Date.now().toString(), started_at: started, finished_at: new Date().toISOString(),
      mode: request.mode, days: request.days, target_contact: request.target_contact,
      contacts_requested: request.mode === 'target_contact' ? 1 : request.max_contacts,
      contacts_collected: conversations.length, conversations: conversations };
    // 最终与增量产物使用同一个渲染器，避免完成时把“本人”标签覆盖回 self。
    response.daily_log_entries = wechatAutoSummaryDailyEntries(response);
    return response;
  }
}
