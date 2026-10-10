import { ChatTool, ChatToolExecutionContext } from '../utils/ChatToolRegistry';
import { parseJsonCompat, stringifyJsonCompat } from '../utils/JsonCompat';
import {
  DOMAIN_KEYS,
  IndexedEvent,
  IndexedEventTodo,
  QueryOptions,
  QueryResult
} from './DataManagerTypes';
import {
  normalizeFreeText,
  stableUnique
} from './DataManagerUtils';

export const QUERY_EVENTS_TOOL_NAME: string = 'query_events';
const DEFAULT_QUERY_EVENTS_LIMIT: number = 20;
const DEFAULT_KEYWORD_OPERATOR: string = 'and';
const QUERY_EVENTS_TOOL_DESCRIPTION: string =
  '如果你需要基于关键词、实体、时间、领域等信息，查询 ClawMate App 已收集并汇总整理的历史事件数据时，调用该工具。' +
  '具体情况：1. 需要直接回答用户问题，例如“查一下我上周用淘宝买过什么”或“我之前说过的生日是什么”；2. 需要为其他工具调用检索必要信息，例如“帮我再次下单我昨天买过的奶茶”。' +
  '用户明确说出的个人信息也可在事件索引中按关键词检索；只根据查询结果回答，不要猜测缺失的资料。' +
  '工具返回 ok 和 events；events 中 event_id 是本次查询结果内从0开始的编号，summary 是事件摘要，detail 是可选的补充事实，todo 是可选的待办及截止时间信息。' +
  '注意事项：1. 不要让查询结果中的历史日期/待办事项日期影响你对今天日期的判断，system prompt 是你判断今天的日期/今天星期几的**唯一依据**；' +
  '2. 如果一个事件有 todo.deadline，event_date 代表创建计划的时间（例如买票时间、聊天时间），实际完成这件事的时间则是 todo.deadline。';
const ENTITY_TYPES: string[] = ['person', 'place', 'merchant'];
const KEYWORD_OPERATORS: string[] = ['and', 'or'];

type QueryEventsJsonValue = Object | string | number | boolean | null;
type QueryEventsJsonMap = Record<string, QueryEventsJsonValue>;
type QueryEventsSchemaMap = Record<string, Object | string | number | boolean | null>;

export type QueryEventsIndexAvailabilityProvider = () => boolean;
export type QueryEventsQueryRunner = (options: QueryOptions) => QueryResult;

export interface QueryEventsEntityInput {
  type: string;
  name: string;
}

export interface QueryEventsPublicQuery {
  keywords: string[];
  keyword_operator: string;
  domains: string[];
  entities: QueryEventsEntityInput[];
  date: string;
  month: string;
  start_date: string;
  end_date: string;
  limit: number;
}

export interface QueryEventsArgumentValidation {
  ok: boolean;
  options: QueryOptions;
  publicQuery: QueryEventsPublicQuery;
  error: string;
}

interface QueryEventsToolEvent {
  event_id: number;
  event_date: string;
  summary: string;
  detail?: string;
  domains: string[];
  entities: string[];
  sources: string[];
  todo?: QueryEventsToolTodo;
}

interface QueryEventsToolTodo {
  type: string;
  deadline: string;
  text: string;
}

interface QueryEventsToolResponse {
  ok: boolean;
  events: QueryEventsToolEvent[];
}

interface QueryEventsToolErrorResponse {
  ok: boolean;
  error: string;
}

export function createQueryEventsTool(hasBuiltIndexes: QueryEventsIndexAvailabilityProvider,
  queryRunner: QueryEventsQueryRunner): ChatTool {
  return {
    name: QUERY_EVENTS_TOOL_NAME,
    description: QUERY_EVENTS_TOOL_DESCRIPTION,
    parameters: queryEventsToolParameters(),
    strict: false,
    execute: async (argsText: string, _context: ChatToolExecutionContext): Promise<string> => {
      let normalized = normalizeQueryEventsToolArguments(argsText);
      if (!normalized.ok) {
        return queryEventsToolErrorPayload(normalized.error);
      }
      if (!hasBuiltIndexes()) {
        return queryEventsToolErrorPayload('ClawMate 事件索引尚未构建，请先同步或刷新数据后再查询。');
      }
      let result = queryRunner(normalized.options);
      return stringifyJsonCompat(queryEventsToolResponse(result) as Object);
    }
  };
}

export function queryEventsToolParameters(): Object {
  let properties = createSchemaMap();
  properties['keywords'] = stringArraySchema('关键词过滤。传入用户想查找的词或短语，例如“咖啡”“酒店订单”，根据关键词匹配事件内容。' +
    '关键词召回基于精确匹配，所以你需要使用具体而不是较抽象的关键词参与检索。' +
    '尽可能只使用一个最重要的关键词，如果你指定了多个关键词，它们的逻辑组合方式由 keyword_operator 决定，默认为 and；优先使用 and 组合，若检索结果为空，你需要考虑改用 or 组合，或者对关键词的数量或表述进行精简，并重试最多3次；不能未经重试直接回答没有相关记录') as Object;
  properties['keyword_operator'] = enumStringSchema('多个 keywords 之间的组合方式。and 表示必须同时匹配全部关键词；or 表示匹配任一关键词即可。省略时默认 and。',
    KEYWORD_OPERATORS) as Object;
  properties['domains'] = enumArraySchema('领域过滤。可选值：eat 吃、wear 穿、live 住、travel 行、work 办公、other 其他。' +
    '多个领域之间用 or 组合，并会与其他过滤条件用 and 组合。', DOMAIN_KEYS) as Object;
  properties['entities'] = entitiesArraySchema() as Object;
  properties['date'] = stringSchema('精确日期过滤，格式 YYYY-MM-DD，例如 2026-06-18。不能和 month、start_date、end_date 同时使用。用户未说明年份时，必须根据系统消息中的当前日期补全年份。') as Object;
  properties['month'] = stringSchema('月份过滤，格式 YYYY-MM，例如 2026-06。不能和 date、start_date、end_date 同时使用。用户未说明年份时，必须根据系统消息中的当前日期补全年份。') as Object;
  properties['start_date'] = stringSchema('日期范围开始日期，格式 YYYY-MM-DD，例如 2026-06-01。可与 end_date 搭配，也可单独表示从该日开始。用户未说明年份时，必须根据系统消息中的当前日期补全年份。') as Object;
  properties['end_date'] = stringSchema('日期范围结束日期，格式 YYYY-MM-DD，例如 2026-06-30。可与 start_date 搭配，也可单独表示截至该日。用户未说明年份时，必须根据系统消息中的当前日期补全年份。') as Object;
  properties['limit'] = numberSchema('最多返回多少条事件。省略时默认返回 20 条；传 0 表示返回全部匹配事件。') as Object;

  let parameters = createSchemaMap();
  parameters['type'] = 'object';
  parameters['description'] = '查询 ClawMate App 已收集并汇总整理的事件。';
  parameters['properties'] = properties as Object;
  parameters['additionalProperties'] = false;
  return parameters as Object;
}

export function normalizeQueryEventsToolArguments(argsText: string): QueryEventsArgumentValidation {
  try {
    let parsed = parseJsonCompat<QueryEventsJsonValue>(argsText.trim().length === 0 ? '{}' : argsText.trim());
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('Tool arguments must be a JSON object.');
    }
    let args = parsed as QueryEventsJsonMap;
    assertAllowedFields(args);

    let keywords = readStringArray(args, 'keywords');
    let keywordOperator = readKeywordOperator(args);
    let domains = readDomains(args);
    let entities = readEntities(args);
    let date = readDateField(args, 'date');
    let month = readMonthField(args, 'month');
    let startDate = readDateField(args, 'start_date');
    let endDate = readDateField(args, 'end_date');
    validateTimeMode(date, month, startDate, endDate);
    let limit = readLimit(args);

    let options: QueryOptions = {
      keywords: keywords,
      keywordOperator: keywordOperator,
      includeTodoDeadlineInTimeRange: true,
      domains: domains,
      entities: entities.map((entity: QueryEventsEntityInput): string => entity.type + ':' + entity.name),
      date: date,
      month: month,
      startDate: startDate,
      endDate: endDate,
      workflowSceneIds: [],
      limit: limit
    };
    let publicQuery: QueryEventsPublicQuery = {
      keywords: keywords.slice(),
      keyword_operator: keywordOperator,
      domains: domains.slice(),
      entities: entities,
      date: date,
      month: month,
      start_date: startDate,
      end_date: endDate,
      limit: limit
    };
    return {
      ok: true,
      options: options,
      publicQuery: publicQuery,
      error: ''
    };
  } catch (e) {
    let err = e as Error;
    return {
      ok: false,
      options: emptyQueryOptions(),
      publicQuery: emptyPublicQuery(),
      error: err.message
    };
  }
}

function assertAllowedFields(args: QueryEventsJsonMap): void {
  let allowed: string[] = ['keywords', 'keyword_operator', 'domains', 'entities', 'date', 'month', 'start_date',
    'end_date', 'limit'];
  Object.keys(args).forEach((key: string) => {
    if (allowed.indexOf(key) < 0) {
      throw new Error('Unsupported query_events argument: ' + key);
    }
  });
}

function readStringArray(args: QueryEventsJsonMap, key: string): string[] {
  if (!hasField(args, key)) {
    return [];
  }
  let value = args[key];
  if (!Array.isArray(value)) {
    throw new Error(key + ' must be an array of strings.');
  }
  let items = value as QueryEventsJsonValue[];
  let result: string[] = [];
  for (let index = 0; index < items.length; index++) {
    let item = items[index];
    if (typeof item !== 'string') {
      throw new Error(key + '[' + String(index) + '] must be a string.');
    }
    let text = normalizeFreeText(item);
    if (text.length > 0) {
      result.push(text);
    }
  }
  return stableUnique(result);
}

function readKeywordOperator(args: QueryEventsJsonMap): string {
  let value = readOptionalString(args, 'keyword_operator');
  if (value.length === 0) {
    return DEFAULT_KEYWORD_OPERATOR;
  }
  let normalized = value.toLowerCase();
  if (KEYWORD_OPERATORS.indexOf(normalized) < 0) {
    throw new Error('keyword_operator must be "and" or "or".');
  }
  return normalized;
}

function readDomains(args: QueryEventsJsonMap): string[] {
  let domains = readStringArray(args, 'domains').map((item: string): string => item.toLowerCase());
  for (let domain of domains) {
    if (DOMAIN_KEYS.indexOf(domain) < 0) {
      throw new Error('domains contains unsupported value: ' + domain);
    }
  }
  return stableUnique(domains);
}

function readEntities(args: QueryEventsJsonMap): QueryEventsEntityInput[] {
  if (!hasField(args, 'entities')) {
    return [];
  }
  let value = args['entities'];
  if (!Array.isArray(value)) {
    throw new Error('entities must be an array of objects.');
  }
  let items = value as QueryEventsJsonValue[];
  let result: QueryEventsEntityInput[] = [];
  let seen: Record<string, boolean> = {};
  for (let index = 0; index < items.length; index++) {
    let item = items[index];
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      throw new Error('entities[' + String(index) + '] must be an object.');
    }
    let entity = readEntity(item as QueryEventsJsonMap, index);
    let key = entity.type + ':' + entity.name;
    if (!seen[key]) {
      seen[key] = true;
      result.push(entity);
    }
  }
  return result;
}

function readEntity(entity: QueryEventsJsonMap, index: number): QueryEventsEntityInput {
  let allowed: string[] = ['type', 'name'];
  Object.keys(entity).forEach((key: string) => {
    if (allowed.indexOf(key) < 0) {
      throw new Error('entities[' + String(index) + '] has unsupported field: ' + key);
    }
  });
  let type = readRequiredString(entity, 'type', 'entities[' + String(index) + '].type').toLowerCase();
  let name = readRequiredString(entity, 'name', 'entities[' + String(index) + '].name');
  if (ENTITY_TYPES.indexOf(type) < 0) {
    throw new Error('entities[' + String(index) + '].type must be person, place, or merchant.');
  }
  return {
    type: type,
    name: name
  };
}

function readRequiredString(args: QueryEventsJsonMap, key: string, label: string): string {
  if (!hasField(args, key)) {
    throw new Error(label + ' is required.');
  }
  let value = args[key];
  if (typeof value !== 'string') {
    throw new Error(label + ' must be a string.');
  }
  let text = normalizeFreeText(value);
  if (text.length === 0) {
    throw new Error(label + ' must not be empty.');
  }
  return text;
}

function readOptionalString(args: QueryEventsJsonMap, key: string): string {
  if (!hasField(args, key)) {
    return '';
  }
  let value = args[key];
  if (typeof value !== 'string') {
    throw new Error(key + ' must be a string.');
  }
  return normalizeFreeText(value);
}

function readDateField(args: QueryEventsJsonMap, key: string): string {
  let value = readOptionalString(args, key);
  if (value.length === 0) {
    return '';
  }
  if (!isCalendarDate(value)) {
    throw new Error(key + ' must use YYYY-MM-DD and be a valid calendar date.');
  }
  return value;
}

function readMonthField(args: QueryEventsJsonMap, key: string): string {
  let value = readOptionalString(args, key);
  if (value.length === 0) {
    return '';
  }
  if (!/^\d{4}-\d{2}$/.test(value)) {
    throw new Error(key + ' must use YYYY-MM.');
  }
  let month = Number(value.substring(5, 7));
  if (month < 1 || month > 12) {
    throw new Error(key + ' must contain a month from 01 to 12.');
  }
  return value;
}

function validateTimeMode(date: string, month: string, startDate: string, endDate: string): void {
  let rangeUsed = startDate.length > 0 || endDate.length > 0;
  if (date.length > 0 && (month.length > 0 || rangeUsed)) {
    throw new Error('Use only one time filter mode: date, month, or start_date/end_date.');
  }
  if (month.length > 0 && rangeUsed) {
    throw new Error('Use only one time filter mode: date, month, or start_date/end_date.');
  }
  if (startDate.length > 0 && endDate.length > 0 && startDate > endDate) {
    throw new Error('start_date must be earlier than or equal to end_date.');
  }
}

function readLimit(args: QueryEventsJsonMap): number {
  if (!hasField(args, 'limit')) {
    return DEFAULT_QUERY_EVENTS_LIMIT;
  }
  let value = args['limit'];
  if (typeof value !== 'number' || isNaN(value) || Math.floor(value) !== value || value < 0) {
    throw new Error('limit must be a non-negative integer.');
  }
  return value;
}

function queryEventsToolResponse(result: QueryResult): QueryEventsToolResponse {
  let events: QueryEventsToolEvent[] = [];
  for (let index = 0; index < result.events.length; index++) {
    events.push(publicToolEvent(result.events[index], index));
  }
  return {
    ok: true,
    events: events
  };
}

function publicToolEvent(event: IndexedEvent, eventIndex: number): QueryEventsToolEvent {
  let output: QueryEventsToolEvent = {
    event_id: eventIndex,
    event_date: event.event_date,
    summary: event.summary,
    domains: (event.domains || []).slice(),
    entities: (event.entities || []).slice(),
    sources: (event.sources || []).slice()
  };
  let detail = toolEventDetail(event.summary, event.normalized_fact);
  if (detail.length > 0) {
    output.detail = detail;
  }
  let todo = toolEventTodo(event.todo);
  if (todo !== undefined) {
    output.todo = todo;
  }
  return output;
}

function toolEventDetail(summary: string, normalizedFact: string): string {
  let detail = normalizeFreeText(normalizedFact);
  if (detail.length === 0 || detail === normalizeFreeText(summary)) {
    return '';
  }
  return detail;
}

function toolEventTodo(todo: IndexedEventTodo): QueryEventsToolTodo | undefined {
  let type = normalizeFreeText(todo.type);
  let deadline = normalizeFreeText(todo.deadline);
  let text = normalizeFreeText(todo.text);
  if (type.length === 0 && deadline.length === 0 && text.length === 0) {
    return undefined;
  }
  return {
    type: type,
    deadline: deadline,
    text: text
  };
}

function queryEventsToolErrorPayload(error: string): string {
  let response: QueryEventsToolErrorResponse = {
    ok: false,
    error: error
  };
  return stringifyJsonCompat(response as Object);
}

function emptyQueryOptions(): QueryOptions {
  return {
    keywords: [],
    keywordOperator: DEFAULT_KEYWORD_OPERATOR,
    includeTodoDeadlineInTimeRange: false,
    domains: [],
    entities: [],
    date: '',
    month: '',
    startDate: '',
    endDate: '',
    workflowSceneIds: [],
    limit: DEFAULT_QUERY_EVENTS_LIMIT
  };
}

function emptyPublicQuery(): QueryEventsPublicQuery {
  return {
    keywords: [],
    keyword_operator: DEFAULT_KEYWORD_OPERATOR,
    domains: [],
    entities: [],
    date: '',
    month: '',
    start_date: '',
    end_date: '',
    limit: DEFAULT_QUERY_EVENTS_LIMIT
  };
}

function hasField(args: QueryEventsJsonMap, key: string): boolean {
  return Object.keys(args).indexOf(key) >= 0;
}

function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  let year = Number(value.substring(0, 4));
  let month = Number(value.substring(5, 7));
  let day = Number(value.substring(8, 10));
  let date = new Date(year, month - 1, day);
  return !isNaN(date.getTime()) && date.getFullYear() === year && date.getMonth() === month - 1 &&
    date.getDate() === day;
}

function createSchemaMap(): QueryEventsSchemaMap {
  return new Object() as QueryEventsSchemaMap;
}

function stringSchema(description: string): QueryEventsSchemaMap {
  let schema = createSchemaMap();
  schema['type'] = 'string';
  schema['description'] = description;
  return schema;
}

function enumStringSchema(description: string, values: string[]): QueryEventsSchemaMap {
  let schema = stringSchema(description);
  schema['enum'] = values as Object;
  return schema;
}

function numberSchema(description: string): QueryEventsSchemaMap {
  let schema = createSchemaMap();
  schema['type'] = 'integer';
  schema['description'] = description;
  schema['minimum'] = 0;
  return schema;
}

function stringArraySchema(description: string): QueryEventsSchemaMap {
  let schema = createSchemaMap();
  schema['type'] = 'array';
  schema['description'] = description;
  schema['items'] = stringSchema('单个查询词。') as Object;
  return schema;
}

function enumArraySchema(description: string, values: string[]): QueryEventsSchemaMap {
  let schema = createSchemaMap();
  schema['type'] = 'array';
  schema['description'] = description;
  let item = stringSchema('单个领域枚举值。');
  item['enum'] = values as Object;
  schema['items'] = item as Object;
  return schema;
}

function entitiesArraySchema(): QueryEventsSchemaMap {
  let typeSchema = stringSchema('实体类型。person 表示人，place 表示地点，merchant 表示商户或服务方。');
  typeSchema['enum'] = ENTITY_TYPES as Object;
  let nameSchema = stringSchema('实体名称，例如“张三”“上海虹桥站”“星巴克”。');
  let entityProperties = createSchemaMap();
  entityProperties['type'] = typeSchema as Object;
  entityProperties['name'] = nameSchema as Object;
  let entityItem = createSchemaMap();
  entityItem['type'] = 'object';
  entityItem['description'] = '实体过滤条件。多个实体之间是 OR 关系，并会与关键词、领域、时间等其他过滤条件取 AND。';
  entityItem['properties'] = entityProperties as Object;
  entityItem['required'] = ['type', 'name'] as Object;
  entityItem['additionalProperties'] = false;
  let schema = createSchemaMap();
  schema['type'] = 'array';
  schema['description'] = '实体过滤列表，用于按人物、地点、商户/服务方查询事件。';
  schema['items'] = entityItem as Object;
  return schema;
}
