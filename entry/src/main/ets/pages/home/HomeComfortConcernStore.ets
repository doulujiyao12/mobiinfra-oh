import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { HomeComfortConcern, homeComfortConcernTitle } from './HomeEmotionalSupport';

export interface HomeComfortSnapshot {
  schema: string;
  day: string; // Last checked day; previous topics remain visible across days.
  input: string;
  concerns: HomeComfortConcern[];
}

// Small, app-private cache for the last successful topics/check. The check day
// controls regeneration, not expiry of the last nonempty conversation topics.
export class HomeComfortConcernStore {
  private storage: DataManagerStorage;
  private path: string;

  constructor(filesDir: string, storage: DataManagerStorage = new DataManagerStorage()) {
    this.storage = storage;
    this.path = storage.join(filesDir, 'home-comfort', 'concerns.json');
  }

  load(day: string): HomeComfortSnapshot | null {
    let snapshot = this.storage.readJson<HomeComfortSnapshot | null>(this.path, null);
    if (!snapshot || snapshot.schema !== 'home-comfort-v1' || typeof snapshot.day !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(snapshot.day) || snapshot.day > day || typeof snapshot.input !== 'string' ||
      !Array.isArray(snapshot.concerns) || snapshot.concerns.length > 3) { return null; }
    let valid = snapshot.concerns.every((item: HomeComfortConcern): boolean => item !== null && typeof item === 'object' &&
      typeof item.id === 'string' && typeof item.title === 'string' && typeof item.summary === 'string' &&
      typeof item.opening === 'string' && typeof item.category === 'string' && Array.isArray(item.evidence) &&
      (item.subject === 'self' || (item.subject === 'other' && typeof item.subjectName === 'string' && item.subjectName.length > 0)));
    if (!valid) { return null; }
    snapshot.concerns.forEach((item: HomeComfortConcern) => {
      item.title = homeComfortConcernTitle(item.title, item.subject || 'self', item.subjectName || '');
    });
    return snapshot.concerns.every((item: HomeComfortConcern): boolean => item.title.length > 0) ? snapshot : null;
  }

  save(day: string, input: string, concerns: HomeComfortConcern[]): void {
    let snapshot: HomeComfortSnapshot = { schema: 'home-comfort-v1', day: day, input: input, concerns: concerns.slice(0, 3) };
    this.storage.ensureDir(this.storage.dirname(this.path));
    this.storage.writeJsonAtomic(this.path, snapshot);
  }
}
