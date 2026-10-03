import { DataManagerFacade } from '../datamanager/DataManagerFacade';
import { IndexedEvent, QueryOptions, QueryResult } from '../datamanager/DataManagerTypes';

const MAX_RESULTS: number = 5;
const MAX_CANDIDATES: number = 20;
const MAX_SUMMARY_LENGTH: number = 180;
const BLOCKED_CONTENT: RegExp = /身份证|证件号|护照|银行卡|家庭住址|详细地址|住址|地址|住在|小区|手机号|手机号码|(?:^|\D)1[3-9]\d{9}(?:\D|$)|(?:^|\D)\d{15}(?:\d{2}[\dXx])?(?:\D|$)/;

export interface PersonalMemoryAnswer {
  text: string;
  count: number;
}

export function isBlockedPersonalMemoryContent(text: string): boolean {
  return BLOCKED_CONTENT.test(text);
}

function canSharePersonalMemoryEvent(event: IndexedEvent): boolean {
  return event.summary.trim().length > 0 && !isBlockedPersonalMemoryContent(event.summary) &&
    !isBlockedPersonalMemoryContent(event.normalized_fact || '') &&
    !isBlockedPersonalMemoryContent((event.entities || []).join('\n')) &&
    !isBlockedPersonalMemoryContent((event.sources || []).join('\n')) &&
    !isBlockedPersonalMemoryContent(event.todo === undefined ? '' : event.todo.text || '');
}

// Filter before sending tool results to the model, as well as before replying to Xiaoyi.
export function personalMemorySafeQueryResult(result: QueryResult): QueryResult {
  let events = result.events.filter((event: IndexedEvent): boolean => canSharePersonalMemoryEvent(event));
  return { total_events: events.length, events: events, events_truncated: result.events_truncated };
}

export function personalMemoryQueryOptions(question: string): QueryOptions {
  let text = question.trim().slice(0, 200);
  let keywords: string[] = [];
  let workflowSceneIds: number[] = [];
  if (/微信/.test(text)) {
    // WeChat records can be classified under different memory scenes; match their indexed source or summary.
    keywords = ['微信'];
  } else if (/外卖|点餐/.test(text)) {
    // A takeout event need not repeat “外卖” in its summary, so use the existing scene index.
    workflowSceneIds = [1];
  } else if (/生日|出生日期|出生年月/.test(text)) {
    keywords = ['生日', '出生'];
  } else if (/单位|公司|工作|上班/.test(text)) {
    keywords = ['单位', '公司', '工作', '上班'];
  } else if (/学校|学历/.test(text)) {
    keywords = ['学校', '学历'];
  } else if (/姓名|名字|叫什么/.test(text)) {
    keywords = ['姓名', '名字'];
  } else if (/做了哪些事|做了什么|干了哪些事|干了什么|最近.*(做|干).*事/.test(text)) {
    // Overview questions have no literal keyword in the indexed events; use the newest indexed summaries.
    keywords = [];
  } else if (!/个人信息|个人记忆|你知道我/.test(text)) {
    keywords = [text];
  }
  return {
    keywords: keywords,
    keywordOperator: 'or',
    domains: [],
    entities: [],
    date: '',
    month: '',
    startDate: '',
    endDate: '',
    workflowSceneIds: workflowSceneIds,
    limit: MAX_CANDIDATES
  };
}

export function personalMemoryAnswer(result: QueryResult): PersonalMemoryAnswer {
  let lines: string[] = [];
  for (let event of result.events) {
    let summary = event.summary.trim();
    if (!canSharePersonalMemoryEvent(event)) {
      continue;
    }
    lines.push(summary.slice(0, MAX_SUMMARY_LENGTH));
    if (lines.length >= MAX_RESULTS) {
      break;
    }
  }
  return {
    text: lines.length > 0 ? lines.map((line: string): string => '• ' + line).join('\n') :
      '没有找到可向小艺提供的相关个人记忆。请确认已在应用中同步；证件号码、详细住址等内容不会通过此入口提供。',
    count: lines.length
  };
}

export function queryPersonalMemory(filesDir: string, question: string): PersonalMemoryAnswer {
  let facade = new DataManagerFacade(filesDir);
  if (!facade.hasBuiltIndexes()) {
    return { text: '尚未建立记忆索引，请先在 ClawMate 中同步。', count: 0 };
  }
  return personalMemoryAnswer(facade.queryIndexedEvents(personalMemoryQueryOptions(question)));
}
