import { JSON as ArkJSON } from '@kit.ArkTS';
import { IndexedEvent, JsonMap, MemorySubjectRef } from '../datamanager/DataManagerTypes';
import { PERSON_FIELDS, PersonField } from '../datamanager/PersonMemory';

// A small presentation snapshot of the accepted facts, not a second memory
// query or a copy of the model prompt / raw index document.
export interface MemorySupplementItem {
  title: string;
  content: string;
  source: string;
  date: string;
  subject: string;
  status: string;
}

export const MEMORY_SUPPLEMENT_MAX_ITEMS: number = 16;

function readable(raw: string, depth: number = 0): string {
  let text = raw.trim().replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  const fence = /^```(?:json)?\s*\n?([\s\S]*?)\s*```$/i.exec(text);
  if (fence) { text = fence[1].trim(); }
  if (/^[\[{]/.test(text)) {
    if (depth >= 2) { return ''; }
    try {
      const value = ArkJSON.parse(text) as JsonMap;
      if (!value || Array.isArray(value) || typeof value !== 'object') { return ''; }
      for (let key of ['summary', 'normalized_fact', 'description', 'text', 'content']) {
        if (typeof value[key] === 'string') {
          const candidate = readable(value[key] as string, depth + 1);
          if (candidate) { return candidate; }
        }
      }
    } catch (e) { return ''; }
    return '';
  }
  return text.replace(/^\s*#{1,6}\s+/gm, '').replace(/\*\*|__/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/`([^`]+)`/g, '$1')
    .replace(/\[(?:索引事件|event_id|source_ref)[^\]]*\]/gi, '')
    .replace(/(?:file:\/\/[^\s；，]+|\S+\.md#\d+|person:[a-zA-Z0-9_:-]+)/g, '')
    .replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
}

function clipped(text: string, limit: number): string {
  return text.length > limit ? text.slice(0, limit - 1) + '…' : text;
}

export function eventMemorySupplement(event: IndexedEvent): MemorySupplementItem {
  const summary = readable(event.summary || '');
  const content = readable(event.normalized_fact || '') || summary || '这条相关记录已用于补充本次任务。';
  const source = (event.sources || []).map((value: string): string => readable(value))
    .filter((value: string): boolean => !!value && !/[\\/]|\.json|\.md|^com\./i.test(value)).slice(0, 2).join(' · ');
  const field = PERSON_FIELDS.find((item: PersonField): boolean => item.key === event.fact_source?.field);
  const subjects = (event.subjects || []).filter((subject: MemorySubjectRef): boolean => !subject.is_self)
    .map((subject: MemorySubjectRef): string => subject.name);
  let subject = subjects.join('、');
  const chat = event.chat_attribution;
  if (!subject && chat?.subject === 'other') { subject = chat.subject_name || ''; }
  const status = event.calendar ? '日程安排' : chat?.status === 'completed' ? '已完成' :
    chat?.status === 'pending' || event.todo?.text ? '待办事项' : '';
  const title = field ? field.label : (summary || content).split(/[\n。！？；]/)[0];
  return { title: clipped(title || '相关记忆', 32), content: clipped(content, 1200),
    source: event.fact_source?.authority === 'user_confirmed' ? '个人信息' : clipped(source || '个人记忆', 48),
    date: /^\d{4}-\d{2}-\d{2}$/.test(event.event_date || '') ? event.event_date : '',
    subject: clipped(readable(subject), 60), status: status };
}

export function profileMemorySupplement(text: string): MemorySupplementItem {
  const content = readable(text.replace(/【画像原文节选】/g, ''));
  const colon = content.indexOf('：');
  const section = colon > 0 && colon <= 12 ? content.slice(0, colon) : '';
  const body = section ? content.slice(colon + 1).trim() : content;
  return { title: section ? section + '相关背景' : '个人背景', content: clipped(body || '已补充相关个人背景。', 1200),
    source: '个人画像', date: '', subject: '', status: '' };
}

export function normalizeMemorySupplement(items?: MemorySupplementItem[]): MemorySupplementItem[] {
  if (!Array.isArray(items)) { return []; }
  const result: MemorySupplementItem[] = [];
  for (let item of items.slice(0, MEMORY_SUPPLEMENT_MAX_ITEMS)) {
    if (!item || typeof item !== 'object' || typeof item.content !== 'string') { continue; }
    const content = readable(item.content);
    if (!content) { continue; }
    result.push({ title: clipped(readable(typeof item.title === 'string' ? item.title : '') || '相关记忆', 32),
      content: clipped(content, 2400), source: clipped(readable(typeof item.source === 'string' ? item.source : '') || '个人记忆', 48),
      date: typeof item.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(item.date) ? item.date : '',
      subject: clipped(readable(typeof item.subject === 'string' ? item.subject : ''), 60),
      status: clipped(readable(typeof item.status === 'string' ? item.status : ''), 16) });
  }
  return result;
}

export function sameMemorySupplement(left: MemorySupplementItem[], right: MemorySupplementItem[]): boolean {
  return left.length === right.length && left.every((item: MemorySupplementItem, index: number): boolean =>
    item.title === right[index].title && item.content === right[index].content && item.source === right[index].source &&
    item.date === right[index].date && item.subject === right[index].subject && item.status === right[index].status);
}
