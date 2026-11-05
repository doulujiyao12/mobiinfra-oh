import { IndexedEvent, MemorySubjectRef, QueryOptions, QueryResult, StringMap } from './DataManagerTypes';
import { PERSONAL_INFO_MEMORY_SCENE_ID } from '../utils/WorkflowSceneConfig';

export interface PersonField { key: string; label: string; placeholder: string; group: string; limit: number; multiline: boolean; domain: string; }
export interface MemoryPerson { id: string; relation: string; label: string; values: StringMap; revision: number; updated_at: string; }
export interface PersonMemoryDocument { schema: number; people: MemoryPerson[]; }
export interface PersonSlot { id: string; relation: string; label: string; monogram: string; color: string; aliases: string[]; }

export const PERSON_MEMORY_REVISION_KEY: string = 'personMemoryRevision';
export const PERSON_SLOTS: PersonSlot[] = [
  { id: 'person:self', relation: 'self', label: '本人', monogram: '我', color: '#007AFF', aliases: ['我', '自己', '本人'] },
  { id: 'person:father', relation: 'father', label: '父亲', monogram: '父', color: '#6372A3', aliases: ['父亲', '爸爸'] },
  { id: 'person:mother', relation: 'mother', label: '母亲', monogram: '母', color: '#BC7393', aliases: ['母亲', '妈妈'] },
  { id: 'person:partner', relation: 'partner', label: '伴侣', monogram: '伴', color: '#A68558', aliases: ['伴侣', '爱人'] }
];
export const PERSON_FIELDS: PersonField[] = [
  { key: 'name', label: '姓名', placeholder: '填写姓名', group: '基本信息', limit: 60, multiline: false, domain: 'other' },
  { key: 'wechat_name', label: '微信昵称', placeholder: '常用的微信昵称', group: '基本信息', limit: 80, multiline: false, domain: 'other' },
  { key: 'birth_date', label: '出生日期', placeholder: '年-月-日，例如 1995-06-18', group: '基本信息', limit: 10, multiline: false, domain: 'other' },
  { key: 'company', label: '工作单位', placeholder: '公司、学校或机构', group: '工作与生活', limit: 160, multiline: false, domain: 'work' },
  { key: 'occupation', label: '职业 / 职务', placeholder: '从事的工作', group: '工作与生活', limit: 100, multiline: false, domain: 'work' },
  { key: 'home_address', label: '家庭住址', placeholder: '城市、街道及详细地址', group: '工作与生活', limit: 300, multiline: true, domain: 'live' },
  { key: 'phone', label: '联系电话', placeholder: '手机或固定电话', group: '联系方式', limit: 60, multiline: false, domain: 'other' },
  { key: 'email', label: '电子邮箱', placeholder: '邮箱地址', group: '联系方式', limit: 160, multiline: false, domain: 'other' },
  { key: 'notes', label: '其他想记住的事', placeholder: '称呼、习惯或其他补充', group: '补充', limit: 800, multiline: true, domain: 'other' }
];

export function personSlot(id: string): PersonSlot {
  const slot = PERSON_SLOTS.find((item: PersonSlot): boolean => item.id === id);
  if (!slot) { throw new Error('人物资料不存在'); }
  return slot;
}
export function emptyMemoryPerson(slot: PersonSlot): MemoryPerson {
  return { id: slot.id, relation: slot.relation, label: slot.label, values: {}, revision: 0, updated_at: '' };
}
export function normalizedPersonValues(values: StringMap, today: string): StringMap {
  const result: StringMap = {};
  for (let field of PERSON_FIELDS) {
    const raw = values[field.key];
    if (raw !== undefined && typeof raw !== 'string') { throw new Error(field.label + '格式不正确'); }
    const value = (raw || '').trim();
    if (value.length > field.limit) { throw new Error(field.label + '内容过长'); }
    if (value) { result[field.key] = value; }
  }
  const birth = result['birth_date'];
  if (birth) {
    const date = new Date(birth + 'T12:00:00');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(birth) || isNaN(date.getTime()) ||
      date.getFullYear() !== Number(birth.slice(0, 4)) || date.getMonth() + 1 !== Number(birth.slice(5, 7)) ||
      date.getDate() !== Number(birth.slice(8, 10)) || birth > today || birth < '1800-01-01') {
      throw new Error('请填写有效出生日期，格式为 年-月-日');
    }
  }
  return result;
}
export function samePersonValues(left: StringMap, right: StringMap): boolean {
  return PERSON_FIELDS.every((field: PersonField): boolean => (left[field.key] || '') === (right[field.key] || ''));
}
export function personSubject(person: MemoryPerson): MemorySubjectRef {
  return { id: person.id, relation: person.relation, name: person.values['name'] || person.label, is_self: person.relation === 'self' };
}
export function personMemoryEvents(people: MemoryPerson[]): IndexedEvent[] {
  const result: IndexedEvent[] = [];
  for (let person of people) {
    const slot = personSlot(person.id);
    const aliases = [person.label, person.values['name'] || '', person.values['wechat_name'] || ''].concat(slot.aliases).filter((s: string): boolean => !!s);
    for (let field of PERSON_FIELDS) {
      const value = person.values[field.key];
      if (!value) { continue; }
      const text = person.label + (person.values['name'] ? '（' + person.values['name'] + '）' : '') + '的' + field.label + '：' + value;
      result.push({ event_id: 'person-fact:' + person.id + ':' + field.key, subjects: [personSubject(person)],
        fact_source: { kind: 'person_profile', subject_id: person.id, field: field.key, authority: 'user_confirmed' },
        source_state_file: 'people-memory/subjects.json', record_id: PERSON_FIELDS.indexOf(field) + 1,
        event_date: person.updated_at.slice(0, 10), last_seen_date: person.updated_at.slice(0, 10),
        summary: text, normalized_fact: text, tags: ['用户填写', '当前资料', person.label],
        source_refs: ['person://' + person.id + '/' + field.key], sources: ['用户填写的人物资料'],
        workflow_scene_ids: [PERSONAL_INFO_MEMORY_SCENE_ID], image_paths: [],
        todo: { type: '', deadline: '', text: '', agent_task: '' }, keywords: aliases.concat([field.label, value]),
        domains: [field.domain], entity_mentions: [{ type: 'person', name: person.values['name'] || person.label, aliases: aliases }],
        enrichment_method: 'user_confirmed', entities: aliases.map((alias: string): string => 'person:' + alias), profile_domains: [] });
    }
  }
  return result;
}
export function eventMatchesSubjects(event: IndexedEvent, subjectIds: string[] = []): boolean {
  return subjectIds.length === 0 || (event.subjects || []).some((subject: MemorySubjectRef): boolean => subjectIds.includes(subject.id));
}
export function queryPersonFacts(events: IndexedEvent[], options: QueryOptions): IndexedEvent[] {
  return events.filter((event: IndexedEvent): boolean => {
    if (!eventMatchesSubjects(event, options.subjectIds)) { return false; }
    if (options.domains.length && !options.domains.some((domain: string): boolean => event.domains.includes(domain))) { return false; }
    if (options.workflowSceneIds.length && !options.workflowSceneIds.includes(PERSONAL_INFO_MEMORY_SCENE_ID)) { return false; }
    if (options.date && event.event_date !== options.date || options.month && !event.event_date.startsWith(options.month) ||
      options.startDate && event.event_date < options.startDate || options.endDate && event.event_date > options.endDate) { return false; }
    if (options.entities.length && !options.entities.some((selector: string): boolean =>
      event.entities.some((entity: string): boolean => entity.toLowerCase() === selector.toLowerCase()))) { return false; }
    const content = [event.summary].concat(event.keywords, event.sources).join(' ').toLowerCase();
    const matches = options.keywords.map((keyword: string): boolean => content.includes(keyword.toLowerCase()));
    return matches.length === 0 || (options.keywordOperator === 'or' ? matches.some((match: boolean): boolean => match) : matches.every((match: boolean): boolean => match));
  });
}
export function mergePersonFactResults(history: QueryResult, current: IndexedEvent[], limit: number): QueryResult {
  if (current.length === 0) { return history; }
  const known = new Set<string>(current.map((event: IndexedEvent): string => event.event_id));
  const combined = current.concat(history.events.filter((event: IndexedEvent): boolean => !known.has(event.event_id)));
  const total = history.total_events + current.length;
  const maximum = limit > 0 ? limit : combined.length;
  return { total_events: total, events: combined.slice(0, maximum), events_truncated: history.events_truncated || total > maximum };
}
