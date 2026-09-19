import {
  AggregatedRecord,
  BooleanMap,
  CandidateFact,
  DailyLogParseResult,
  DedupDecision,
  DOMAIN_DISPLAY_NAMES,
  DOMAIN_KEYS,
  EntityMention,
  IndexedEvent,
  JsonMap,
  NumberedEntry,
  StringArrayMap,
  SourceEntry,
  createStringArrayMap
} from './DataManagerTypes';
import { parseJsonCompat } from '../utils/JsonCompat';
import { weekdayLabelFromDate as dateUtilsWeekdayLabelFromDate } from '../utils/DateUtils';

export const DAILY_LOG_METADATA_PATTERN: RegExp = /^<!-- DAILY_LOG_METADATA\n([\s\S]*?)\n-->\n*/;
export const STATE_FILE_SUFFIX: string = '.state.json';
export const RECENT_MATCH_DAYS: number = 7;
export const RECENT_MATCH_MAX_RECORDS: number = 0;

type RegExpMap = Record<string, RegExp>;

interface CandidateRecordScore {
  record: AggregatedRecord;
  score: number;
  position: number;
}

const DOMAIN_RULES: StringArrayMap = createStringArrayMap();
DOMAIN_RULES['eat'] = ['餐饮', '美食', '外卖', '用餐', '咖啡', '饮料', '餐厅', '食品', '早餐', '午餐', '晚餐'];
DOMAIN_RULES['wear'] = ['服装', '衣服', '裤', '裙', '鞋', '外套', '穿搭', '箱包', '背包'];
DOMAIN_RULES['live'] = ['住宿', '酒店', '宾馆', '房租', '住房', '家居', '公寓', '民宿'];
DOMAIN_RULES['travel'] = ['交通', '出行', '通勤', '乘车', '网约车', '出租车', '打车', '地铁', '公交', '高铁', '火车', '航班', '机票', '旅行', '旅游'];
DOMAIN_RULES['work'] = ['工作', '上班', '办公', '会议', '汇报', '协作', '加班', '出差'];

const PROFILE_DOMAIN_RULES: StringArrayMap = createStringArrayMap();
PROFILE_DOMAIN_RULES['eat'] = ['餐饮', '美食', '外卖', '用餐', '餐厅', '早餐', '午餐', '晚餐', '火锅', '牛肉面', '拉面', '烤肉', '汉堡', '奶茶', '咖啡', '饮料'];
PROFILE_DOMAIN_RULES['wear'] = ['服装', '衣服', '裤', '裙', '鞋', '外套', '穿搭', '箱包', '背包', '美妆', '护肤'];
PROFILE_DOMAIN_RULES['live'] = ['住宿', '酒店', '宾馆', '房租', '住房', '家居', '公寓', '民宿', '充电'];
PROFILE_DOMAIN_RULES['travel'] = ['交通', '出行', '通勤', '乘车', '网约车', '出租车', '打车', '地铁', '公交', '高铁', '火车', '航班', '机票', '旅行', '旅游', '邮轮', '潜水', '瀑布', '景区', '攻略'];
PROFILE_DOMAIN_RULES['work'] = ['工作', '上班', '办公', '会议', '汇报', '协作', '加班', '出差', 'PR', 'GitHub', 'GitLab', '代码', '分支', 'merge', 'rebase', 'debug', 'OCR', 'embedding', '应用开发', '接口', '权限', 'Agent'];

export function nowIsoLocal(): string {
  let date = new Date();
  let year = String(date.getFullYear());
  let month = String(date.getMonth() + 1).padStart(2, '0');
  let day = String(date.getDate()).padStart(2, '0');
  let hour = String(date.getHours()).padStart(2, '0');
  let minute = String(date.getMinutes()).padStart(2, '0');
  let second = String(date.getSeconds()).padStart(2, '0');
  return `${year}-${month}-${day}T${hour}:${minute}:${second}`;
}

export function normalizeFreeText(value: Object | string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) {
    return '';
  }
  return String(value).replace(/\s+/g, ' ').trim();
}

export function normalizeLookupText(value: Object | string | number | boolean | null | undefined): string {
  return normalizeFreeText(value)
    .toLowerCase()
    .replace(/[\s\u3000]+/g, '')
    .replace(/[，。；、：:（）()“”"'`~!@#$%^&*+\-=[\]{}\\|/?<>.,;]/g, '');
}

export function normalizeDedupText(value: string): string {
  return normalizeFreeText(value)
    .replace(/^(\d{4}-\d{2}-\d{2}|\d{1,2}-\d{1,2}号?|\d{1,2}月\d{1,2}日)[:：\s-]*/g, '');
}

export function normalizedSimilarityKey(value: string): string {
  return normalizeDedupText(value)
    .toLowerCase()
    .replace(/[^\w\u4e00-\u9fff]+/g, '');
}

export function extractAmountTokens(value: string): string[] {
  let tokens: string[] = [];
  let pattern = /\d+(?:\.\d+)?元/g;
  let match: RegExpExecArray | null = pattern.exec(value);
  while (match !== null) {
    tokens.push(match[0]);
    match = pattern.exec(value);
  }
  return stableUnique(tokens).sort();
}

export function normalizedTransactionSignature(value: string): string {
  let normalized = normalizeDedupText(value)
    .replace(/(收益发放|发放|交通出行|投资理财|支出|消费|买入)/g, '')
    .replace(/\d+(?:\.\d+)?元/g, '');
  return normalizedSimilarityKey(normalized);
}

export function summarizeText(value: string, maxLength: number = 80): string {
  let text = normalizeFreeText(value);
  if (text.length <= maxLength) {
    return text;
  }
  return text.substring(0, maxLength) + '...';
}

function compactChineseProfileText(value: Object | string | number | boolean | null | undefined): string {
  return normalizeFreeText(value).replace(/[^\u4e00-\u9fff]/g, '');
}

export function normalizeProfileShortSummary(value: Object | string | number | boolean | null | undefined): string {
  let compact = compactChineseProfileText(value);
  return compact.length === 4 ? compact : '';
}

export function profileShortSummaryFromText(domain: string, value: string, fallback: string = '近期记录'): string {
  let compact = compactChineseProfileText(value);
  let displayName = DOMAIN_DISPLAY_NAMES[domain] || '';
  if (displayName.length > 0 && compact.startsWith(displayName + '领域')) {
    compact = compact.substring((displayName + '领域').length);
  }
  let fillerWords: string[] = [
    '该领域',
    '领域',
    '呈现出',
    '这些倾向',
    '倾向',
    '用户',
    '数据',
    '记录显示',
    '记录',
    '主要',
    '来自',
    '近期',
    '最近',
    '话题',
    '反复出现',
    '出现',
    '可以',
    '看到'
  ];
  fillerWords.forEach((word: string) => {
    compact = compact.replace(new RegExp(word, 'g'), '');
  });
  if (compact.length >= 4) {
    return compact.substring(0, 4);
  }
  let fallbackCompact = compactChineseProfileText(fallback);
  if (fallbackCompact.length === 0) {
    return '';
  }
  let padded = compact + fallbackCompact;
  if (padded.length >= 4) {
    return padded.substring(0, 4);
  }
  return '近期记录';
}

export function stableUnique(values: string[]): string[] {
  let result: string[] = [];
  let seen: BooleanMap = {};
  for (let value of values) {
    let text = normalizeFreeText(value);
    if (text.length > 0 && !seen[text]) {
      seen[text] = true;
      result.push(text);
    }
  }
  return result;
}

export function stableUniqueNumbers(values: number[]): number[] {
  let result: number[] = [];
  let seen: Record<string, boolean> = {};
  for (let value of values) {
    if (isNaN(value)) {
      continue;
    }
    let key = String(value);
    if (!seen[key]) {
      seen[key] = true;
      result.push(value);
    }
  }
  return result;
}

export function workflowSceneIdFromMetadata(metadata: JsonMap): number {
  let value = Number(metadata['task_scene_id']);
  return isNaN(value) ? -1 : value;
}

export function normalizeTags(values: Object | string[] | null | undefined): string[] {
  if (!Array.isArray(values)) {
    return [];
  }
  return stableUnique(values.map((item: string) => normalizeFreeText(item))).slice(0, 20);
}

export function isIsoDate(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value);
}

export function monthKeyFromDate(value: string): string {
  return isIsoDate(value) ? value.substring(0, 7) : '';
}

export function dateToTime(value: string): number {
  if (!isIsoDate(value)) {
    return 0;
  }
  return new Date(value + 'T00:00:00').getTime();
}

export function weekdayLabelFromDate(value: string): string {
  return dateUtilsWeekdayLabelFromDate(value);
}

export function addDays(value: string, days: number): string {
  let time = dateToTime(value);
  if (time <= 0) {
    return value;
  }
  let date = new Date(time + days * 86400000);
  return date.toISOString().substring(0, 10);
}

export function parseDailyLogDocument(content: string): DailyLogParseResult {
  let result: DailyLogParseResult = {
    workflow_metadata: {},
    latest_entry_index: 0,
    body: content
  };
  let match = DAILY_LOG_METADATA_PATTERN.exec(content);
  if (!match) {
    return result;
  }
  try {
    let parsed = parseJsonCompat<JsonMap>(match[1]);
    if (parsed && typeof parsed === 'object') {
      if (parsed['workflow_metadata'] && typeof parsed['workflow_metadata'] === 'object') {
        result.workflow_metadata = parsed['workflow_metadata'] as JsonMap;
      }
      let latest = Number(parsed['latest_entry_index']);
      result.latest_entry_index = isNaN(latest) ? 0 : latest;
    }
  } catch (e) {
  }
  result.body = content.substring(match[0].length);
  return result;
}

export function parseNumberedEntries(body: string): NumberedEntry[] {
  let entries: NumberedEntry[] = [];
  let normalized = body.trim();
  if (normalized.length === 0) {
    return entries;
  }
  let pattern = /(?:^|\n\s*\n)(\d+)\.\s+([\s\S]*?)(?=\n\s*\n\d+\.\s+|$)/g;
  let match: RegExpExecArray | null = pattern.exec(normalized);
  while (match !== null) {
    let text = match[2].trim();
    if (text.length > 0) {
      let entry: NumberedEntry = {
        index: Number(match[1]),
        text: text
      };
      entries.push(entry);
    }
    match = pattern.exec(normalized);
  }
  return entries;
}

export function sourceRef(sourceDate: string, fileName: string, entryIndex: number): string {
  return `${sourceDate}/${fileName}#${entryIndex}`;
}

export function sourceDisplayName(value: string): string {
  let parts = sourceFileNameParts(value);
  if (parts[0] === 'app-chat') {
    return parts[1] === 'local' ? '端侧聊天' : '云端聊天';
  }
  let name = parts.length > 0 ? parts[parts.length - 1] : '';
  let legacyName = appKeyFromTaskName(name);
  return appDisplayNameFromKey(legacyName) || normalizeFreeText(legacyName) || '未知来源';
}

export function sourceAppDisplayName(value: string): string {
  let parts = sourceFileNameParts(value);
  if (parts[0] === 'app-chat') {
    return sourceDisplayName(value);
  }
  let packageName = parts.length > 0 ? parts[0] : '';
  let fromPackage = appDisplayNameFromPackage(packageName);
  if (fromPackage.length > 0) {
    return fromPackage;
  }
  let workflowName = parts.length > 1 ? parts[1] : '';
  let fromWorkflow = appDisplayNameFromTask(workflowName);
  if (fromWorkflow.length > 0) {
    return fromWorkflow;
  }
  if (parts.length > 1 && packageName.length > 0) {
    return packageDisplayNameFallback(packageName);
  }
  return sourceDisplayName(value);
}

function sourceContextDisplayNames(value: string): string[] {
  let parts = sourceFileNameParts(value);
  if (parts.length <= 2 || parts[0] === 'app-chat') {
    return [];
  }
  let workflowName = normalizeLookupText(parts[1]);
  // 微信自动采集第三段是 run_id，图库导出第三段是图库分类；二者都不是联系人/业务对象。
  if (workflowName === 'wechat_auto_summary' || workflowName === 'wechatautosummary' ||
    workflowName === 'gallery_analysis' || workflowName === 'galleryanalysis') {
    return [];
  }
  return stableUnique(parts.slice(2).map((part: string) => normalizeFreeText(part))).filter((part: string) => part.length > 0);
}

function sourceFileNameParts(value: string): string[] {
  let withoutHash = normalizeFreeText(value).split('#')[0];
  let pieces = withoutHash.split(/[\\/]/);
  let name = pieces.length > 0 ? pieces[pieces.length - 1] : withoutHash;
  if (name.endsWith(STATE_FILE_SUFFIX)) {
    name = name.substring(0, name.length - STATE_FILE_SUFFIX.length);
  }
  if (name.endsWith('.md')) {
    name = name.substring(0, name.length - 3);
  }
  return name.split('__').map((part: string) => normalizeFreeText(part)).filter((part: string) => part.length > 0);
}

function appDisplayNameFromPackage(packageName: string): string {
  let normalized = normalizeLookupText(packageName);
  let mappings: Record<string, string> = {};
  mappings['comtencentmm'] = '微信';
  mappings['comtencentwechat'] = '微信';
  mappings['comhuaweiphotos'] = '图库';
  mappings['comjdharmony'] = '京东';
  mappings['comctripharmony'] = '携程';
  mappings['comalipaymobileclient'] = '支付宝';
  mappings['comsankuaimeituan'] = '美团';
  mappings['commeituanwaimai'] = '美团外卖';
  mappings['commeituantakeoutnew'] = '美团外卖';
  mappings['comsankuaidianping'] = '大众点评';
  mappings['comtaobaotaobao'] = '淘宝';
  mappings['comtencentvideohm'] = '腾讯视频';
  mappings['tvdanmakubili'] = '哔哩哔哩';
  mappings['comxinginxhshos'] = '小红书';
  mappings['comxinginxhs_hos'] = '小红书';
  mappings['comautonaviminimap'] = '高德地图';
  mappings['comhuaweihealth'] = '华为运动健康';
  mappings['meeleeleme'] = '饿了么';
  return mappings[normalized] || '';
}

function appDisplayNameFromTask(taskName: string): string {
  let key = appKeyFromTaskName(taskName);
  return appDisplayNameFromKey(key);
}

function appKeyFromTaskName(taskName: string): string {
  let key = normalizeFreeText(taskName).replace(/^\d+_(?:basic_gui_)?task_/, '');
  key = key.replace(/_v\d+$/g, '');
  return key;
}

function appDisplayNameFromKey(key: string): string {
  if (key === 'alipay') {
    return '支付宝';
  }
  if (key === 'dianping') {
    return '大众点评';
  }
  if (key === 'tencent_video') {
    return '腾讯视频';
  }
  if (key === 'xiaohongshu') {
    return '小红书';
  }
  if (key === 'ele') {
    return '饿了么';
  }
  if (key === 'weixin') {
    return '微信';
  }
  return '';
}

function packageDisplayNameFallback(packageName: string): string {
  let parts = normalizeFreeText(packageName).split('.').filter((part: string) => part.length > 0);
  if (parts.length === 0) {
    return '未知来源';
  }
  return parts[parts.length - 1];
}

export function eventSourceNames(sourceRefs: string[], sourceStateFile: string): string[] {
  let refs = sourceRefs.length > 0 ? sourceRefs : [sourceStateFile];
  let names: string[] = [];
  refs.forEach((item: string) => {
    let appName = sourceAppDisplayName(item);
    if (appName.length > 0 && appName !== '未知来源') {
      names.push(appName);
    }
    names = names.concat(sourceContextDisplayNames(item));
  });
  if (names.length === 0) {
    names.push(sourceDisplayName(sourceStateFile));
  }
  return stableUnique(names);
}

export function heuristicSplit(entry: SourceEntry): CandidateFact[] {
  let text = normalizeFreeText(entry.entry_text);
  if (text.length === 0) {
    return [];
  }
  let parts = extractAtomicClauses(text);
  if (parts.length > 0) {
    return parts.map((part: string): CandidateFact => {
      let normalized = normalizeFreeText(part);
      return {
        summary: normalized,
        normalized_fact: normalized,
        event_date: entry.source_date,
        tags: [],
        model_notes: 'heuristic_atomic_split',
        raw_excerpt: text,
        source_ref: entry.source_ref,
        source_date: entry.source_date,
        workflow_scene_id: entry.workflow_scene_id,
        dedup_text: normalizeDedupText(normalized)
      };
    });
  }
  return [{
    summary: summarizeText(text, 60) || '未命名记录',
    normalized_fact: text,
    event_date: entry.source_date,
    tags: [],
    model_notes: 'heuristic_split',
    raw_excerpt: text,
    source_ref: entry.source_ref,
    source_date: entry.source_date,
    workflow_scene_id: entry.workflow_scene_id,
    dedup_text: normalizeDedupText(text)
  }];
}

export function extractAtomicClauses(text: string): string[] {
  let normalized = normalizeFreeText(text);
  if (normalized.length === 0) {
    return [];
  }
  let transactionClauses = extractTransactionClauses(normalized);
  if (transactionClauses.length > 0) {
    return transactionClauses;
  }
  let segments: string[] = [];
  let markerPattern = /(?:账单列表显示了|具体记录有[:：]|记录有[:：]|账单如下[:：])(.*?)(?:。|$)/g;
  let markerMatch: RegExpExecArray | null = markerPattern.exec(normalized);
  while (markerMatch !== null) {
    segments.push(markerMatch[1]);
    markerMatch = markerPattern.exec(normalized);
  }
  if (segments.length === 0 && extractAmountTokens(normalized).length <= 1) {
    return [];
  }
  if (segments.length === 0) {
    segments.push(normalized);
  }
  let clauses: string[] = [];
  let seen: BooleanMap = {};
  for (let segment of segments) {
    let normalizedSegment = segment.replace(/以及/g, '，');
    let parts = normalizedSegment.split(/[，；。]/);
    for (let part of parts) {
      let clause = normalizeFreeText(part)
        .replace(/^(包括|显示了|具体记录有|记录有|账单如下)[:：\s]*/g, '');
      if (clause.length === 0 || extractAmountTokens(clause).length === 0) {
        continue;
      }
      let key = normalizeDedupText(clause);
      if (key.length > 0 && !seen[key]) {
        seen[key] = true;
        clauses.push(clause);
      }
    }
  }
  return clauses;
}

export function extractTransactionClauses(text: string): string[] {
  if (extractAmountTokens(text).length <= 1) {
    return [];
  }
  let cleaned = text
    .replace(/^当前页面显示了.*?(?:订单记录|消费记录|账单记录)[，,:：\s]*/g, '')
    .replace(/^近期在\d+家店(?:有)?消费(?:过|记录)?[，,:：\s]*/g, '');
  let orderMarker = '(?:其中最近一单是|其中有一单是|最近一单是|第一单(?:同样是|是)?|第二单(?:同样是|是)?|第三单(?:同样是|是)?|第[一二三四五六七八九十\\d]+单(?:同样是|是)?|接着是|随后是)';
  let leadingOrderMarkerPattern = new RegExp('^' + orderMarker, 'g');
  let chunks = cleaned.split(/[。]/);
  let clauses: string[] = [];
  let seen: BooleanMap = {};
  for (let chunk of chunks) {
    let normalizedChunk = normalizeFreeText(chunk.replace(/[；;]+$/g, ''));
    if (normalizedChunk.length === 0 || extractAmountTokens(normalizedChunk).length === 0) {
      continue;
    }
    let parts = normalizedChunk.split(new RegExp('(?=' + orderMarker + ')', 'g'));
    if (parts.length === 0) {
      parts = [normalizedChunk];
    }
    for (let part of parts) {
      let clause = normalizeFreeText(part.replace(/^[，。；;\s]+|[，。；;\s]+$/g, ''));
      if (clause.length === 0 || extractAmountTokens(clause).length === 0) {
        continue;
      }
      leadingOrderMarkerPattern.lastIndex = 0;
      clause = clause
        .replace(leadingOrderMarkerPattern, '')
        .replace(/^(同样是|还有一单是|还有|一单是)/g, '');
      clause = normalizeFreeText(clause.replace(/^[，。；;\s]+|[，。；;\s]+$/g, ''));
      if (clause.length === 0) {
        continue;
      }
      let key = normalizeDedupText(clause);
      if (key.length > 0 && !seen[key]) {
        seen[key] = true;
        clauses.push(clause);
      }
    }
  }
  return clauses;
}

export function atomicizeCandidateFacts(entry: SourceEntry, facts: CandidateFact[]): CandidateFact[] {
  let atomicFacts: CandidateFact[] = [];
  let seen: BooleanMap = {};
  for (let fact of facts) {
    let clauses = extractAtomicClauses(fact.normalized_fact);
    if (clauses.length === 0) {
      clauses = extractAtomicClauses(fact.raw_excerpt);
    }
    if (clauses.length > 0) {
      for (let clause of clauses) {
        let dedupText = normalizeDedupText(clause);
        if (dedupText.length === 0 || seen[dedupText]) {
          continue;
        }
        seen[dedupText] = true;
        let atomicFact: CandidateFact = {
          summary: summarizeText(clause),
          normalized_fact: clause,
          event_date: fact.event_date || entry.source_date,
          tags: fact.tags.slice(),
          model_notes: fact.model_notes || 'atomicized_from_model_fact',
          raw_excerpt: fact.raw_excerpt,
          source_ref: fact.source_ref,
          source_date: fact.source_date,
          workflow_scene_id: fact.workflow_scene_id,
          dedup_text: dedupText
        };
        atomicFacts.push(atomicFact);
      }
      continue;
    }
    let dedupText = normalizeDedupText(fact.normalized_fact);
    if (dedupText.length > 0 && !seen[dedupText]) {
      seen[dedupText] = true;
      let atomicFact: CandidateFact = {
        summary: summarizeText(fact.summary || fact.normalized_fact),
        normalized_fact: normalizeFreeText(fact.normalized_fact),
        event_date: fact.event_date || entry.source_date,
        tags: fact.tags.slice(),
        model_notes: fact.model_notes,
        raw_excerpt: fact.raw_excerpt,
        source_ref: fact.source_ref,
        source_date: fact.source_date,
        workflow_scene_id: fact.workflow_scene_id,
        dedup_text: dedupText
      };
      atomicFacts.push(atomicFact);
    }
  }
  return atomicFacts;
}

export function selectRecentScopeRecords(records: AggregatedRecord[], fact: CandidateFact): AggregatedRecord[] {
  let factDate = isIsoDate(fact.event_date) ? fact.event_date : fact.source_date;
  if (!isIsoDate(factDate)) {
    return [];
  }
  let factTime = dateToTime(factDate);
  if (factTime <= 0) {
    return [];
  }
  let lowerTime = factTime - (RECENT_MATCH_DAYS - 1) * 86400000;
  return records.filter((record: AggregatedRecord) => {
    let firstSeenDate = normalizeFreeText(record.first_seen_date);
    let firstSeenTime = dateToTime(firstSeenDate);
    return firstSeenTime >= lowerTime && firstSeenTime <= factTime;
  });
}

export function findExactExistingMatch(records: AggregatedRecord[], fact: CandidateFact): AggregatedRecord | null {
  let key = normalizedSimilarityKey(fact.dedup_text || fact.normalized_fact);
  let amounts = extractAmountTokens(fact.dedup_text || fact.normalized_fact);
  for (let record of records) {
    let recordKey = normalizedSimilarityKey(record.dedup_text || record.normalized_fact);
    if (record.source_refs.indexOf(fact.source_ref) >= 0 && key.length > 0 && key === recordKey) {
      return record;
    }
    if (record.source_refs.indexOf(fact.source_ref) >= 0 && amounts.length > 0 && sameStringSet(amounts, extractAmountTokens(record.dedup_text || record.normalized_fact))) {
      return record;
    }
  }
  for (let record of records) {
    let recordKey = normalizedSimilarityKey(record.dedup_text || record.normalized_fact);
    if (key.length > 0 && key === recordKey) {
      return record;
    }
  }
  return null;
}

function sameStringSet(left: string[], right: string[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

export function overlapScore(left: string, right: string): number {
  let leftTerms = indexTerms(left);
  let rightTerms = indexTerms(right);
  if (leftTerms.length === 0 || rightTerms.length === 0) {
    return 0;
  }
  let rightSet: BooleanMap = {};
  rightTerms.forEach((term: string) => {
    rightSet[term] = true;
  });
  let score = 0;
  leftTerms.forEach((term: string) => {
    if (rightSet[term]) {
      score++;
    }
  });
  return score;
}

export function selectCandidateRecords(records: AggregatedRecord[], fact: CandidateFact, limit: number): AggregatedRecord[] {
  if (records.length === 0) {
    return [];
  }
  if (limit <= 0) {
    return records;
  }
  let factKey = normalizedSimilarityKey(fact.dedup_text);
  let factAmounts = extractAmountTokens(fact.dedup_text);
  let scored: CandidateRecordScore[] = records
    .map((record: AggregatedRecord, index: number): CandidateRecordScore => {
      let recordKey = normalizedSimilarityKey(record.dedup_text);
      let score = 0;
      if (factKey.length > 0 && recordKey.length > 0) {
        if (factKey === recordKey) {
          score += 100;
        } else if (factKey.indexOf(recordKey) >= 0 || recordKey.indexOf(factKey) >= 0) {
          score += 40;
        }
      }
      score += sharedStringCount(factAmounts, extractAmountTokens(record.dedup_text)) * 20;
      let item: CandidateRecordScore = {
        record: record,
        score: score,
        position: index
      };
      return item;
    })
    .sort((left, right) => {
      if (left.score !== right.score) {
        return right.score - left.score;
      }
      return right.position - left.position;
    })
    .filter(item => item.score > 0)
    .slice(0, limit);
  if (scored.length === 0) {
    return records.slice(Math.max(0, records.length - limit));
  }
  return scored.map((item: CandidateRecordScore) => item.record);
}

function sharedStringCount(left: string[], right: string[]): number {
  let rightMap: BooleanMap = {};
  right.forEach((item: string) => rightMap[item] = true);
  let count = 0;
  left.forEach((item: string) => {
    if (rightMap[item]) {
      count++;
    }
  });
  return count;
}

export function updateExistingRecord(record: AggregatedRecord, fact: CandidateFact, decision: DedupDecision): void {
  record.last_seen_date = record.last_seen_date > fact.source_date ? record.last_seen_date : fact.source_date;
  let sourceDate = fact.event_date || fact.source_date;
  if (record.source_dates.indexOf(sourceDate) < 0) {
    record.source_dates.push(sourceDate);
    record.source_dates.sort();
  }
  if (record.source_refs.indexOf(fact.source_ref) < 0) {
    record.source_refs.push(fact.source_ref);
  }
  if (!isNaN(fact.workflow_scene_id) && fact.workflow_scene_id >= 0 && record.workflow_scene_ids.indexOf(fact.workflow_scene_id) < 0) {
    record.workflow_scene_ids.push(fact.workflow_scene_id);
    record.workflow_scene_ids.sort((left: number, right: number) => left - right);
  }
  if (record.raw_excerpts.indexOf(fact.raw_excerpt) < 0) {
    record.raw_excerpts.push(fact.raw_excerpt);
  }
  let mergedSummary = normalizeFreeText(decision.merged_summary);
  let mergedFact = normalizeFreeText(decision.merged_fact);
  if (mergedSummary.length > 0) {
    record.summary = summarizeText(mergedSummary);
  }
  if (mergedFact.length > 0) {
    record.normalized_fact = mergedFact;
    record.dedup_text = normalizeDedupText(mergedFact);
  } else if (preferRicherFact(record.normalized_fact, fact.normalized_fact)) {
    record.normalized_fact = fact.normalized_fact;
    record.summary = summarizeText(fact.summary || fact.normalized_fact);
    record.dedup_text = normalizeDedupText(fact.normalized_fact);
  }
  let tags = normalizeTags(decision.merged_tags);
  record.tags = stableUnique(record.tags.concat(tags).concat(fact.tags));
  let decisionValue = normalizeFreeText(decision.decision);
  if (decisionValue.length > 0) {
    record.dedup_status = decisionValue;
  }
  let reason = normalizeFreeText(decision.reason) || fact.model_notes;
  if (reason.length > 0 && record.model_notes.indexOf(reason) < 0) {
    record.model_notes.push(reason);
  }
}

function detailScore(value: string): number {
  let text = normalizeFreeText(value);
  if (text.length === 0) {
    return 0;
  }
  let score = text.length;
  if (text.indexOf('下单时间') >= 0) {
    score += 40;
  }
  if (text.indexOf('订单') >= 0) {
    score += 20;
  }
  if (/[“"'].+?[”"']/.test(text)) {
    score += 20;
  }
  if (/\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}/.test(text)) {
    score += 20;
  }
  return score;
}

function preferRicherFact(current: string, candidate: string): boolean {
  let currentText = normalizeFreeText(current);
  let candidateText = normalizeFreeText(candidate);
  if (candidateText.length === 0) {
    return false;
  }
  if (currentText.length === 0) {
    return true;
  }
  return detailScore(candidateText) > detailScore(currentText);
}

export function createNewRecord(nextRecordId: number, fact: CandidateFact, decision: DedupDecision): AggregatedRecord {
  let reason = normalizeFreeText(decision.reason) || fact.model_notes;
  return {
    record_id: nextRecordId,
    first_seen_date: fact.event_date || fact.source_date,
    last_seen_date: fact.source_date,
    source_refs: [fact.source_ref],
    source_dates: stableUnique([fact.event_date || fact.source_date, fact.source_date]).sort(),
    workflow_scene_ids: !isNaN(fact.workflow_scene_id) && fact.workflow_scene_id >= 0 ? [fact.workflow_scene_id] : [],
    summary: summarizeText(fact.summary || fact.normalized_fact),
    normalized_fact: normalizeFreeText(fact.normalized_fact),
    raw_excerpts: [fact.raw_excerpt],
    tags: stableUnique(fact.tags),
    dedup_status: normalizeFreeText(decision.decision) || 'new',
    model_notes: reason.length > 0 ? [reason] : [],
    dedup_text: fact.dedup_text
  };
}

export function escapeTableCell(value: string): string {
  return normalizeFreeText(value).replace(/\|/g, '\\|');
}

export function renderConsolidatedMarkdown(records: AggregatedRecord[]): string {
  let lines: string[] = [
    '| 序号 | 记录日期 | 最近来源日期 | 内容 | 来源条目 | 去重状态 |',
    '| --- | --- | --- | --- | --- | --- |'
  ];
  for (let record of records) {
    let refs = record.source_refs.slice(Math.max(0, record.source_refs.length - 3))
      .map((item: string) => escapeTableCell(item)).join('<br>') || '-';
    lines.push(`| ${record.record_id} | ${escapeTableCell(record.first_seen_date)} | ${escapeTableCell(record.last_seen_date)} | ${escapeTableCell(record.normalized_fact)} | ${refs} | ${escapeTableCell(record.dedup_status)} |`);
  }
  return lines.join('\n') + '\n';
}

export function deriveRuleKeywords(event: IndexedEvent): string[] {
  let text = `${event.summary || ''} ${event.normalized_fact || ''}`;
  return deriveKeywordsFromText(text);
}

function deriveKeywordsFromText(text: string): string[] {
  let values: string[] = [];
  let lower = text.toLowerCase();
  Object.keys(DOMAIN_RULES).forEach((domain: string) => {
    DOMAIN_RULES[domain].forEach((term: string) => {
      if (lower.indexOf(term.toLowerCase()) >= 0) {
        values.push(term);
      }
    });
  });
  let tokenPattern = /[A-Za-z][A-Za-z0-9_.-]*|\d+(?:\.\d+)?元?/g;
  let tokenMatch: RegExpExecArray | null = tokenPattern.exec(text);
  while (tokenMatch !== null) {
    if (tokenMatch[0].length > 1) {
      values.push(tokenMatch[0]);
    }
    tokenMatch = tokenPattern.exec(text);
  }
  let phrases = text.split(/[，。；、：:（）()“”"'\s]+/);
  for (let phrase of phrases) {
    let item = phrase.trim();
    if (item.length >= 2 && item.length <= 18 && !item.startsWith('当前页面') && !item.startsWith('这张截图')) {
      values.push(item);
    }
  }
  return stableUnique(values).slice(0, 30);
}

export function deriveRuleDomains(event: IndexedEvent): string[] {
  let text = `${event.summary || ''} ${event.normalized_fact || ''}`.toLowerCase();
  let result: string[] = [];
  Object.keys(DOMAIN_RULES).forEach((domain: string) => {
    let matched = DOMAIN_RULES[domain].some((term: string) => text.indexOf(term.toLowerCase()) >= 0);
    if (matched) {
      result.push(domain);
    }
  });
  return result.length > 0 ? stableUnique(result) : ['other'];
}

export function normalizeDomains(rawDomains: string[]): string[] {
  let result = stableUnique(rawDomains.map((item: string) => item.toLowerCase()).filter((item: string) => DOMAIN_KEYS.indexOf(item) >= 0));
  if (result.length > 1 && result.indexOf('other') >= 0) {
    result = result.filter((item: string) => item !== 'other');
  }
  return result;
}

export function deriveProfileDomains(event: IndexedEvent): string[] {
  let domains = normalizeDomains(event.domains || []);
  let candidates: string[] = [];
  domains.forEach((domain: string) => {
    if (domain !== 'other' && hasProfileDomainEvidence(event, domain)) {
      candidates.push(domain);
    }
  });
  if (candidates.length > 0) {
    return stableUnique(candidates);
  }
  if (domains.length === 1 && domains[0] === 'other') {
    return ['other'];
  }
  return [];
}

function eventProfileText(event: IndexedEvent): string {
  return [
    event.summary,
    event.normalized_fact,
    ...(event.tags || []),
    ...(event.keywords || []),
    ...(event.sources || []),
    ...(event.entities || [])
  ].join(' ');
}

function hasProfileDomainEvidence(event: IndexedEvent, domain: string): boolean {
  let rules = PROFILE_DOMAIN_RULES[domain] || [];
  if (rules.length === 0) {
    return false;
  }
  let text = eventProfileText(event).toLowerCase();
  for (let rule of rules) {
    if (text.indexOf(rule.toLowerCase()) >= 0) {
      return true;
    }
  }
  return false;
}

export function normalizeEntityName(value: Object | string | number | boolean | null | undefined): string {
  return normalizeFreeText(value)
    .replace(/^[“"'「『]+/, '')
    .replace(/[”"'」』]+$/, '')
    .trim();
}

export function entityLookupKey(type: string, name: string): string {
  return `${type}:${normalizeLookupText(normalizeEntityName(name))}`;
}

export function entityDisplayKey(type: string, name: string): string {
  return `${type}:${normalizeEntityName(name)}`;
}

export function normalizeEntityMentions(rawEntities: EntityMention[]): EntityMention[] {
  if (!Array.isArray(rawEntities)) {
    return [];
  }
  let result: EntityMention[] = [];
  let seen: BooleanMap = {};
  for (let entity of rawEntities) {
    let entityType = normalizeFreeText(entity.type).toLowerCase();
    if (['person', 'place', 'merchant'].indexOf(entityType) < 0) {
      continue;
    }
    let name = normalizeEntityName(entity.name);
    let key = entityLookupKey(entityType, name);
    if (name.length === 0 || seen[key]) {
      continue;
    }
    let aliases = stableUnique((entity.aliases || []).map((item: string) => normalizeEntityName(item)))
      .filter((item: string) => entityLookupKey(entityType, item) !== key);
    let mention: EntityMention = {
      type: entityType,
      name: name,
      aliases: aliases
    };
    result.push(mention);
    seen[key] = true;
  }
  return result;
}

export function deriveRuleEntities(event: IndexedEvent): EntityMention[] {
  let text = `${event.summary || ''} ${event.normalized_fact || ''}`;
  let result: EntityMention[] = [];
  let patterns: RegExpMap = new Object() as RegExpMap;
  patterns['person'] = /(?:人物|联系人姓名|联系人|聊天对象|姓名)\s*[:：]\s*[“"']?([^，。；;\n“”"']{2,40})/g;
  patterns['place'] = /(?:地点|位置|目的地|地址|场馆)\s*[:：]\s*[“"']?([^，。；;\n“”"']{2,60})/g;
  patterns['merchant'] = /(?:商户|商家|门店|店铺)\s*[:：]\s*[“"']?([^，。；;\n“”"']{2,60})/g;
  Object.keys(patterns).forEach((type: string) => {
    let pattern = patterns[type];
    let match: RegExpExecArray | null = pattern.exec(text);
    while (match !== null) {
      let mention: EntityMention = {
        type: type,
        name: match[1],
        aliases: []
      };
      result.push(mention);
      match = pattern.exec(text);
    }
  });
  let chatPattern = /(?:与|和)\s*[“"']([^“”"']{2,40})[”"']\s*的?(?:聊天|对话)/g;
  let chatMatch: RegExpExecArray | null = chatPattern.exec(text);
  while (chatMatch !== null) {
    let mention: EntityMention = {
      type: 'person',
      name: chatMatch[1],
      aliases: []
    };
    result.push(mention);
    chatMatch = chatPattern.exec(text);
  }
  return normalizeEntityMentions(result);
}

export function indexTerms(value: string): string[] {
  let compact = normalizeLookupText(value);
  let terms: string[] = [];
  let cjkPattern = /[\u4e00-\u9fff]+/g;
  let cjkMatch: RegExpExecArray | null = cjkPattern.exec(compact);
  while (cjkMatch !== null) {
    let run = cjkMatch[0];
    for (let i = 0; i < run.length - 1; i++) {
      terms.push(run.substring(i, i + 2));
    }
    cjkMatch = cjkPattern.exec(compact);
  }
  let tokenPattern = /[a-z0-9_]+/g;
  let tokenMatch: RegExpExecArray | null = tokenPattern.exec(compact);
  while (tokenMatch !== null) {
    let token = tokenMatch[0];
    for (let i = 0; i < token.length - 1; i++) {
      terms.push(token.substring(i, i + 2));
    }
    tokenMatch = tokenPattern.exec(compact);
  }
  return stableUnique(terms);
}

export function eventSearchText(event: IndexedEvent): string {
  return [event.summary, event.normalized_fact, ...(event.keywords || [])].join(' ');
}

export function sourceSearchText(event: IndexedEvent): string {
  return (event.sources || []).join(' ');
}

export function publicEvent(event: IndexedEvent): IndexedEvent {
  return event;
}

export function displayDomainName(domain: string): string {
  return DOMAIN_DISPLAY_NAMES[domain] || domain;
}

export type DataManagerAsyncTask<T> = () => Promise<T>;

interface DataManagerTaskCursor {
  nextIndex: number;
}

async function runLimitedTaskWorker<T>(tasks: DataManagerAsyncTask<T>[], results: T[], cursor: DataManagerTaskCursor): Promise<void> {
  while (true) {
    let index = cursor.nextIndex;
    cursor.nextIndex++;
    if (index >= tasks.length) {
      return;
    }
    results[index] = await tasks[index]();
  }
}

export async function runLimitedTasks<T>(tasks: DataManagerAsyncTask<T>[], concurrency: number): Promise<T[]> {
  let results: T[] = [];
  if (tasks.length === 0) {
    return results;
  }
  let limit = Math.max(1, Math.min(concurrency, tasks.length));
  let cursor: DataManagerTaskCursor = {
    nextIndex: 0
  };
  let workers: Promise<void>[] = [];
  for (let index = 0; index < limit; index++) {
    workers.push(runLimitedTaskWorker(tasks, results, cursor));
  }
  await Promise.all(workers);
  return results;
}
