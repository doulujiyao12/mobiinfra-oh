import { DataManagerStorage } from './DataManagerStorage';
import { MemoryPerson, PERSON_SLOTS, PersonSlot, PersonMemoryDocument, emptyMemoryPerson, normalizedPersonValues,
  personSlot, samePersonValues, personMemoryEvents } from './PersonMemory';
import { IndexedEvent, StringMap } from './DataManagerTypes';
import { formatLocalDateKey } from '../utils/DateUtils';
import { nowIsoLocal } from './DataManagerUtils';

// Current, editable subject facts form a small independent index source. Keep
// it outside historical index transactions so a running sync cannot revert a
// user's edit. One atomic document is the source of truth and query projection.
export class PersonMemoryStore {
  private storage: DataManagerStorage;
  private path: string;
  constructor(filesDir: string, storage: DataManagerStorage = new DataManagerStorage()) {
    this.storage = storage; this.path = storage.join(filesDir, 'people-memory', 'subjects.json');
  }
  people(): MemoryPerson[] {
    if (!this.storage.exists(this.path)) { return PERSON_SLOTS.map(emptyMemoryPerson); }
    const document = this.storage.readJson<PersonMemoryDocument | null>(this.path, null);
    if (!document || document.schema !== 1 || !Array.isArray(document.people)) { throw new Error('人物资料读取失败，请稍后重试'); }
    const seen = new Set<string>();
    for (let person of document.people) {
      if (!person || typeof person.id !== 'string' || seen.has(person.id) || !person.values || typeof person.values !== 'object' || Array.isArray(person.values) ||
        !Number.isInteger(person.revision) || person.revision < 0 || typeof person.updated_at !== 'string') { throw new Error('人物资料格式不正确'); }
      const slot = personSlot(person.id);
      if (person.relation !== slot.relation || person.label !== slot.label) { throw new Error('人物归属信息不正确'); }
      person.values = normalizedPersonValues(person.values, formatLocalDateKey(new Date()));
      if (person.revision > 0 && !/^\d{4}-\d{2}-\d{2}T/.test(person.updated_at)) { throw new Error('人物资料更新时间不正确'); }
      seen.add(person.id);
    }
    return PERSON_SLOTS.map((slot: PersonSlot): MemoryPerson => document.people.find((person: MemoryPerson): boolean => person.id === slot.id) || emptyMemoryPerson(slot));
  }
  save(id: string, values: StringMap, expectedRevision: number): MemoryPerson {
    personSlot(id);
    const people = this.people();
    const previous = people.find((person: MemoryPerson): boolean => person.id === id) as MemoryPerson;
    if (previous.revision !== expectedRevision) { throw new Error('资料已在其他页面更新，请返回后重新打开'); }
    const today = formatLocalDateKey(new Date());
    const normalized = normalizedPersonValues(values, today);
    if (samePersonValues(previous.values, normalized)) { return previous; }
    const next: MemoryPerson = { id: previous.id, relation: previous.relation, label: previous.label, values: normalized,
      revision: previous.revision + 1, updated_at: nowIsoLocal() };
    const document: PersonMemoryDocument = { schema: 1, people: people.map((person: MemoryPerson): MemoryPerson => person.id === id ? next : person) };
    this.storage.writeJsonAtomic(this.path, document);
    return next;
  }
  events(): IndexedEvent[] { return personMemoryEvents(this.people()); }
  hasFacts(): boolean { return this.people().some((person: MemoryPerson): boolean => Object.keys(person.values).length > 0); }
}
