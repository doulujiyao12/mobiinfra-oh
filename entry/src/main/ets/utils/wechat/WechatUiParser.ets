import { JSON as ArkJSON } from '@kit.ArkTS';
import { WechatAutoSummaryMessage } from './WechatAutoSummaryTypes';

// The same List/ListItem/Text/Image structure and sender/time rules as the PC collector.
// No OCR, model call, private WeChat database access, or content-based shell commands.
export interface WechatUiAttributes {
  type?: string;
  text?: string;
  bounds?: string;
  origBounds?: string;
  scrollable?: string | boolean;
  bundleName?: string;
}
export interface WechatUiNode { attributes?: WechatUiAttributes; children?: WechatUiNode[]; }
export interface WechatBounds { left: number; top: number; right: number; bottom: number; }
export interface WechatText { text: string; bounds: WechatBounds | null; }
export interface WechatContact { name: string; bounds: WechatBounds; }
export interface WechatEntry extends WechatAutoSummaryMessage {
  bounds: WechatBounds | null;
  textBounds: WechatBounds | null;
  images: WechatBounds[];
}
export interface WechatChatPage { title: string; viewport: WechatBounds; entries: WechatEntry[]; }
interface WechatMergeCandidate { entry: WechatEntry; key: string; boundaryDuplicate: boolean; }

export function wechatBounds(node: WechatUiNode): WechatBounds | null {
  let value = node.attributes?.origBounds || node.attributes?.bounds || '';
  let m = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(value);
  if (!m) { return null; }
  let result: WechatBounds = { left: Number(m[1]), top: Number(m[2]), right: Number(m[3]), bottom: Number(m[4]) };
  return result.right > result.left && result.bottom > result.top ? result : null;
}

export function wechatNodes(root: WechatUiNode): WechatUiNode[] {
  let pending: WechatUiNode[] = [root];
  let nodes: WechatUiNode[] = [];
  while (pending.length > 0) {
    let node = pending.pop();
    if (!node) { continue; }
    if (nodes.length >= 50000) { throw new Error('WECHAT_UI_LIMIT: UI 节点超过上限'); }
    nodes.push(node);
    let children = node.children || [];
    for (let i = children.length - 1; i >= 0; i--) { pending.push(children[i]); }
  }
  return nodes;
}

export function parseWechatUi(text: string): WechatUiNode {
  let root = ArkJSON.parse(text) as WechatUiNode;
  if (!root || !root.attributes || !wechatBounds(root)) {
    throw new Error('WECHAT_UI_PARSE: 未获取到有效微信界面，请检查无线调试及微信前台状态');
  }
  let nodes = wechatNodes(root);
  for (let node of nodes) {
    let bundle = node.attributes?.bundleName;
    if (bundle && bundle !== 'com.tencent.wechat' && bundle !== 'com.tencent.mm') {
      throw new Error('WECHAT_UI_FOREGROUND: 当前界面包含其他应用，停止操作');
    }
  }
  return root;
}

export function wechatType(node: WechatUiNode): string { return node.attributes?.type || ''; }
export function wechatText(node: WechatUiNode): string { return (node.attributes?.text || '').trim(); }
function area(bounds: WechatBounds | null): number {
  return bounds ? (bounds.right - bounds.left) * (bounds.bottom - bounds.top) : 0;
}
export function wechatItems(node: WechatUiNode): WechatUiNode[] {
  return (node.children || []).filter((child: WechatUiNode): boolean => wechatType(child) === 'ListItem');
}
export function wechatList(root: WechatUiNode): WechatUiNode | null {
  let best: WechatUiNode | null = null;
  let bestScore = -1;
  for (let node of wechatNodes(root)) {
    if (wechatType(node) !== 'List' || !wechatBounds(node)) { continue; }
    let score = wechatItems(node).length * 100000000 + area(wechatBounds(node));
    if (score > bestScore) { best = node; bestScore = score; }
  }
  return best;
}
export function wechatTexts(root: WechatUiNode): WechatText[] {
  let result: WechatText[] = [];
  for (let node of wechatNodes(root)) {
    if (wechatType(node) === 'Text' && wechatText(node)) {
      result.push({ text: wechatText(node), bounds: wechatBounds(node) });
    }
  }
  return result.sort((a: WechatText, b: WechatText): number =>
    (a.bounds?.top || 0) - (b.bounds?.top || 0) || (a.bounds?.left || 0) - (b.bounds?.left || 0));
}
export function wechatContacts(root: WechatUiNode): WechatContact[] {
  let list = wechatList(root);
  let result: WechatContact[] = [];
  if (!list) { return result; }
  for (let item of wechatItems(list)) {
    let texts = wechatTexts(item);
    let bounds = wechatBounds(item);
    if (texts.length > 0 && texts[0].text !== '搜索' && bounds) {
      result.push({ name: texts[0].text, bounds: bounds });
    }
  }
  return result;
}

export function wechatTitle(root: WechatUiNode): string {
  let screen = wechatBounds(root);
  if (!screen) { return ''; }
  let listNodes = new Set<WechatUiNode>();
  for (let node of wechatNodes(root)) {
    if (wechatType(node) === 'List') { wechatNodes(node).forEach((item: WechatUiNode): void => { listNodes.add(item); }); }
  }
  let title = ''; let score = Number.MAX_VALUE;
  for (let node of wechatNodes(root)) {
    if (listNodes.has(node) || wechatType(node) !== 'Text') { continue; }
    let bounds = wechatBounds(node); let text = wechatText(node);
    if (!bounds || !text || /^\d+$/.test(text) || text === ':' || text === '搜索' ||
      bounds.top < screen.top + (screen.bottom - screen.top) * 0.035 ||
      bounds.bottom > screen.top + (screen.bottom - screen.top) * 0.16) { continue; }
    let candidate = Math.abs((bounds.left + bounds.right - screen.left - screen.right) / 2) + bounds.top / 10;
    if (candidate < score) { title = text; score = candidate; }
  }
  return title;
}

export function wechatIsHome(root: WechatUiNode): boolean {
  let nodes = wechatNodes(root);
  if (nodes.some((node: WechatUiNode): boolean => /^(TextInput|TextArea)$/.test(wechatType(node)))) { return false; }
  let texts = wechatTexts(root).map((item: WechatText): string => item.text);
  if (texts.indexOf('通讯录') >= 0 && texts.indexOf('发现') >= 0 &&
    /^微信(?:[（(]\d+[）)])?$/.test(wechatTitle(root))) { return true; }
  let list = wechatList(root);
  if (!list) { return false; }
  // Fixtures and some WeChat versions omit the tab bar. Require conversation time + preview rows.
  return wechatItems(list).some((item: WechatUiNode): boolean => {
    let row = wechatTexts(item);
    return row.length >= 3 && parseWechatTime(row[1].text, new Date()) !== null;
  });
}

function avatar(images: WechatBounds[]): WechatBounds | null {
  let selected: WechatBounds | null = null;
  for (let bounds of images) {
    let w = bounds.right - bounds.left; let h = bounds.bottom - bounds.top;
    if (w >= 40 && h >= 40 && Math.abs(w - h) <= Math.max(w, h) * 0.35 &&
      (!selected || area(bounds) < area(selected))) { selected = bounds; }
  }
  return selected;
}

export function wechatChatPage(root: WechatUiNode, expectedTitle: string): WechatChatPage {
  let list = wechatList(root); let screen = wechatBounds(root); let title = wechatTitle(root);
  let normalized = (value: string): string => value.trim().replace(/\s*[（(]\d+[）)]$/, '').toLowerCase();
  if (!list || !screen || wechatIsHome(root) || !title || normalized(title) !== normalized(expectedTitle)) {
    throw new Error('WECHAT_CHAT_MISMATCH: 未确认目标聊天页，停止点击和滑动；请返回微信聊天首页后重试');
  }
  let viewport = wechatBounds(list);
  if (!viewport) { throw new Error('WECHAT_CHAT_BOUNDS: 聊天列表没有有效坐标'); }
  let center = (screen.left + screen.right) / 2;
  let entries: WechatEntry[] = [];
  for (let item of wechatItems(list)) {
    let texts = wechatTexts(item);
    let images: WechatBounds[] = [];
    for (let node of wechatNodes(item)) {
      let bounds = wechatBounds(node);
      if (wechatType(node) === 'Image' && bounds) { images.push(bounds); }
    }
    if (texts.length === 0 && images.length === 0) { continue; }
    let image = avatar(images);
    let textBounds = texts.length > 0 ? texts[0].bounds : null;
    let text = texts.map((t: WechatText): string => t.text).join('\n');
    if (!text) { text = images.length > (image ? 1 : 0) ? '[图片]' : '[文件]'; }
    let time = images.length === 0 && texts.length === 1 &&
      (!textBounds || Math.abs((textBounds.left + textBounds.right) / 2 - center) <= center * 0.35) &&
      parseWechatTime(text, new Date()) !== null;
    let senderBounds = image || textBounds;
    let sender: string | null = time || !senderBounds ? null :
      ((senderBounds.left + senderBounds.right) / 2 > center ? 'self' : title);
    entries.push({ kind: time ? 'time' : 'message', text: text, sender: sender,
      bounds: wechatBounds(item), textBounds: textBounds, images: images });
  }
  let composer = wechatNodes(root).some((node: WechatUiNode): boolean => /^(TextInput|TextArea)$/.test(wechatType(node)));
  if (!composer && !(entries.some((entry: WechatEntry): boolean => entry.kind === 'time') &&
    entries.some((entry: WechatEntry): boolean => entry.kind === 'message' && entry.images.length > 0))) {
    throw new Error('WECHAT_CHAT_STRUCTURE: 未识别到聊天输入框或消息列表结构，停止滑动');
  }
  return { title: title, viewport: viewport, entries: entries };
}

export function wechatCutoff(days: number, now: Date): number {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() - Math.max(0, days - 1)).getTime();
}
export function parseWechatTime(text: string, now: Date): number | null {
  let time = /(上午|下午|晚上|凌晨|中午)?\s*(\d{1,2}):(\d{2})/.exec(text);
  let hour = time ? Number(time[2]) : 0; let minute = time ? Number(time[3]) : 0;
  let period = time ? time[1] : '';
  if ((period === '下午' || period === '晚上') && hour < 12) { hour += 12; }
  if (period === '中午' && hour < 11) { hour += 12; }
  if (period === '凌晨' && hour === 12) { hour = 0; }
  if (hour > 23 || minute > 59) { return null; }
  let date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let month = /(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)?/.exec(text);
  let slash = /(\d{1,2})\/(\d{1,2})/.exec(text);
  let weekday = /星期([一二三四五六日天])/.exec(text);
  if (text.indexOf('昨天') >= 0) { date.setDate(date.getDate() - 1); }
  else if (text.indexOf('今天') >= 0) { /* today */ }
  else if (month || slash) {
    let year = month && month[1] ? Number(month[1]) : now.getFullYear();
    let m = month ? Number(month[2]) : (slash ? Number(slash[1]) : 0);
    let d = month ? Number(month[3]) : (slash ? Number(slash[2]) : 0);
    date = new Date(year, m - 1, d);
    if (date.getFullYear() !== year || date.getMonth() !== m - 1 || date.getDate() !== d) { return null; }
  } else if (weekday) {
    let day = '日一二三四五六'.indexOf(weekday[1] === '天' ? '日' : weekday[1]);
    date.setDate(date.getDate() - (date.getDay() - day + 7) % 7);
  } else if (!time) { return null; }
  date.setHours(hour, minute, 0, 0);
  return date.getTime();
}

export function wechatPageFingerprint(page: WechatChatPage): string {
  // Positions matter: two screens can have identical text while the viewport still moves.
  return ArkJSON.stringify(page.entries);
}

function overlapKey(entry: WechatEntry): string {
  if (entry.kind !== 'message' || !entry.text || entry.text === '[图片]' || entry.text === '[文件]') { return ''; }
  return ArkJSON.stringify([entry.kind, entry.sender, entry.text.replace(/\s+/g, ' ').trim()]);
}
function boundary(entry: WechatEntry, viewport: WechatBounds, top: boolean): boolean {
  let bounds = entry.bounds;
  if (!bounds) { return false; }
  let margin = (viewport.bottom - viewport.top) * 0.2;
  return top ? bounds.top <= viewport.top + margin : bounds.bottom >= viewport.bottom - margin;
}

function pageOverlap(previous: string[], current: string[]): number {
  // KMP: only remove the ordered overlap between adjacent pages. A global text set
  // would incorrectly delete separate "好的" messages sharing the same time anchor.
  if (previous.length === 0 || current.length === 0) { return 0; }
  let keys = current.concat(['WECHAT_PAGE_BOUNDARY']).concat(previous);
  let prefix: number[] = [0];
  for (let i = 1; i < keys.length; i++) {
    let count = prefix[i - 1];
    while (count > 0 && keys[i] !== keys[count]) { count = prefix[count - 1]; }
    if (keys[i] === keys[count]) { count++; }
    prefix.push(count);
  }
  return Math.min(prefix[prefix.length - 1], previous.length, current.length);
}

// Match the PC time-anchor and page-boundary rules, while preserving repeated
// messages within a page and messages repeated outside adjacent viewport overlaps.
export function mergeWechatPages(pages: WechatChatPage[], days: number, now: Date): WechatAutoSummaryMessage[] {
  let cutoff = wechatCutoff(days, now);
  let messages: WechatAutoSummaryMessage[] = [];
  let previousKeys: string[] = [];
  let previousBottom = new Map<string, number>();
  let currentTime: number | null = null; let beforeTime: number | null = null;
  for (let p = pages.length - 1; p >= 0; p--) {
    let page = pages[p]; let firstTime: number | null = null;
    for (let entry of page.entries) {
      let value = entry.kind === 'time' ? parseWechatTime(entry.text || '', now) : null;
      if (value !== null) { firstTime = value; break; }
    }
    let prefix: number | null = firstTime === null ? currentTime :
      (currentTime !== null && currentTime < firstTime ? currentTime : (currentTime === firstTime ? beforeTime : null));
    let skipPrefix = prefix === null && firstTime !== null && wechatCutoff(1, new Date(firstTime)) <= cutoff;
    let anchored = false;
    let bottom = new Map<string, number>();
    let overlaps = new Map<string, number>();
    let candidates: WechatMergeCandidate[] = [];
    for (let entry of page.entries) {
      let parsed = entry.kind === 'time' ? parseWechatTime(entry.text || '', now) : null;
      if (skipPrefix && !anchored && parsed === null) { continue; }
      if (parsed !== null) { beforeTime = currentTime; currentTime = parsed; anchored = true; }
      let effective = entry.kind === 'time' ? parsed : (anchored ? currentTime : prefix);
      let overlap = overlapKey(entry);
      if (overlap && boundary(entry, page.viewport, false)) { bottom.set(overlap, (bottom.get(overlap) || 0) + 1); }
      if (effective !== null && effective < cutoff) { continue; }
      let key = ArkJSON.stringify([entry.kind, entry.sender, entry.text, effective,
        entry.text === '[图片]' || entry.text === '[文件]' ? entry.images : []]);
      let duplicate = false;
      if (overlap && boundary(entry, page.viewport, true)) {
        let count = (overlaps.get(overlap) || 0) + 1; overlaps.set(overlap, count);
        duplicate = count <= (previousBottom.get(overlap) || 0);
      }
      candidates.push({ entry: entry, key: key, boundaryDuplicate: duplicate });
    }
    let keys = candidates.map((item: WechatMergeCandidate): string => item.key);
    let overlap = pageOverlap(previousKeys, keys);
    for (let i = overlap; i < candidates.length; i++) {
      let item = candidates[i];
      if (!item.boundaryDuplicate) {
        messages.push({ kind: item.entry.kind, text: item.entry.text, sender: item.entry.sender });
      }
    }
    previousKeys = keys;
    previousBottom = bottom;
  }
  return messages;
}
