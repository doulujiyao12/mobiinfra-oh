import { ProfileClaim, ProfileDomainState, ProfileState } from './DataManagerTypes';

const NOTE_LIMIT: number = 50;
const INTRO: string = '我留意到，';

interface ProfileObservation {
  domain: ProfileDomainState;
  claim: ProfileClaim;
}

function addressedToReader(value: string): string {
  // “用户体验” can be the topic of a sentence, not a reference to the reader.
  const text = value.trim().replace(/^(?:该用户|用户本人|用户)(?=的|在|对|偏好|喜欢|习惯|关注|倾向|经常|通常|可能|近期|最近|多次|更|常|曾|不)/, '你')
    .replace(/[。.!！]+$/, '');
  return text.replace(/^(?=偏好|喜欢|倾向于|经常使用|习惯于|关注着)/, '你');
}

// Work from the published model conclusions. Keep qualifiers and whole statements,
// even when that means using only one domain in the available space.
export function collectionProfileNote(profile: ProfileState): string {
  const candidates: ProfileObservation[] = [];
  for (const key of Object.keys(profile.domains)) {
    const domain = profile.domains[key];
    if (!domain.event_count || (domain.generation && domain.generation !== 'model')) { continue; }
    for (const claim of domain.claims || []) {
      if ((claim.confidence === 'high' || claim.confidence === 'medium') && claim.evidence_count >= 2 && claim.statement) {
        candidates.push({ domain: domain, claim: claim });
      }
    }
  }
  candidates.sort((a: ProfileObservation, b: ProfileObservation): number =>
    Number(b.claim.confidence === 'high') - Number(a.claim.confidence === 'high') ||
    b.claim.evidence_count - a.claim.evidence_count ||
    (b.claim.end_date || '').localeCompare(a.claim.end_date || ''));

  const usedDomains = new Set<string>();
  const sentences: string[] = [];
  let note = INTRO;
  for (const candidate of candidates) {
    if (usedDomains.has(candidate.domain.domain)) { continue; }
    const sentence = addressedToReader(candidate.claim.statement);
    if (!sentence || sentences.includes(sentence) || note.length + sentence.length + 1 > NOTE_LIMIT) { continue; }
    note += sentence + '。';
    sentences.push(sentence);
    usedDomains.add(candidate.domain.domain);
    if (sentences.length === 2) { break; }
  }
  if (sentences.length) { return note; }
  // Older or more verbose profiles can still have a concise model-generated domain summary.
  for (const candidate of candidates) {
    const summary = addressedToReader(candidate.domain.summary || '');
    if (summary && INTRO.length + summary.length + 1 <= NOTE_LIMIT) { return INTRO + summary + '。'; }
    const label = (candidate.domain.short_summary || '').trim();
    if (/^[\u4e00-\u9fff]{4}$/.test(label)) { return '我在你的记录里，几次看到了「' + label + '」。'; }
  }
  return '';
}
