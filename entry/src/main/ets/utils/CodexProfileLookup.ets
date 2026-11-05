import { codexUtf8Excerpt } from './CodexRequestBudget';

export interface CodexProfileFact { id: string; text: string; }
interface ProfileCandidate { text: string; key: string; score: number; order: number; }

// Read the already-built profile lazily, once per delegation. Never enumerate
// historical screenshots, raw chats, mail, calendar, or credentials.
export class CodexProfileLookup {
  private reader: () => string;
  private profile: string | null = null;
  private facts: CodexProfileFact[] = [];
  private byText: Map<string, CodexProfileFact> = new Map();
  constructor(reader: () => string) { this.reader = reader; }

  snapshot(): string {
    if (this.profile === null) { this.profile = this.reader(); }
    return this.profile;
  }

  search(keywords: string[]): CodexProfileFact[] {
    let terms = keywords.filter((term: string): boolean => typeof term === 'string')
      .map((term: string): string => term.trim().toLowerCase().slice(0, 40))
      .filter((term: string): boolean => term.length >= 2).slice(0, 8);
    if (terms.length === 0) { return []; }
    const profile = this.snapshot();
    let section = ''; let candidates: ProfileCandidate[] = []; let order = 0;
    for (let raw of profile.split(/\r?\n/)) {
      if (/^##\s+/.test(raw)) { section = raw.replace(/^##\s+/, '').trim(); continue; }
      if (/^#|^\s*$|^-\s*(生成时间|覆盖事件|时间范围|画像条目)[：:]/.test(raw) || /当前记录还不足以形成稳定/.test(raw)) { continue; }
      // A long domain overview is split into sentences so matching one topic
      // cannot disclose unrelated sentences from the same paragraph.
      for (let part of raw.replace(/^\s*[-*]\s*/, '').match(/[^。！？；]+[。！？；]?/g) || []) {
        let lower = part.toLowerCase(); let score = terms.reduce((sum: number, term: string): number => sum + Number(lower.includes(term)), 0);
        if (score === 0) { continue; }
        let excerpt = codexUtf8Excerpt(part.trim(), 1000);
        let text = (section ? section + '：' : '') + excerpt + (excerpt.length < part.trim().length ? '【画像原文节选】' : '');
        candidates.push({ text: text, key: part.trim(), score: score, order: order++ });
      }
    }
    candidates.sort((left: ProfileCandidate, right: ProfileCandidate): number => right.score - left.score || left.order - right.order);
    let result: CodexProfileFact[] = []; let seen = new Set<string>();
    for (let candidate of candidates) {
      if (seen.has(candidate.key)) { continue; }
      seen.add(candidate.key);
      let fact = this.byText.get(candidate.key);
      if (fact === undefined) {
        fact = { id: 'profile-' + (this.facts.length + 1), text: candidate.text };
        this.facts.push(fact); this.byText.set(candidate.key, fact);
      }
      result.push(fact);
      if (result.length === 6) { break; }
    }
    return result;
  }

  selected(ids: string[]): CodexProfileFact[] {
    return this.facts.filter((fact: CodexProfileFact): boolean => ids.includes(fact.id)).slice(0, 6);
  }
}
