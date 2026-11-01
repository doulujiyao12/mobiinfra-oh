import { JSON as ArkJSON } from '@kit.ArkTS';
import { IndexedEvent, JsonMap } from './DataManagerTypes';

export class ProfileResponseError extends Error {
  constructor(message: string) { super(message); this.name = 'ProfileResponseError'; }
}

// Aliases are scoped to a single request. Files and validated model results
// always retain the real evidence IDs; the model never has to copy long paths.
export class ProfileRequestCodec {
  private aliases: Map<string, string> = new Map<string, string>();
  private originals: Map<string, string> = new Map<string, string>();
  constructor(events: IndexedEvent[]) {
    events.slice().sort((a: IndexedEvent, b: IndexedEvent): number => a.event_id.localeCompare(b.event_id))
      .forEach((event: IndexedEvent, index: number) => {
        let alias = 'e' + String(index + 1);
        this.aliases.set(event.event_id, alias); this.originals.set(alias, event.event_id);
      });
  }
  encode(prompt: string): string {
    let payload = ArkJSON.parse(prompt) as JsonMap;
    let events = payload['events'];
    if (Array.isArray(events)) {
      (events as JsonMap[]).forEach((event: JsonMap) => { event['event_id'] = this.alias(String(event['event_id'])); });
    }
    ['candidate_claims', 'previous_claims'].forEach((field: string) => {
      let claims = payload[field];
      if (Array.isArray(claims)) {
        (claims as JsonMap[]).forEach((claim: JsonMap) => {
          let ids = claim['event_ids'];
          if (Array.isArray(ids)) { claim['event_ids'] = (ids as string[]).map((id: string): string => this.alias(id)); }
        });
      }
    });
    return ArkJSON.stringify(payload);
  }
  decode(payload: JsonMap): void {
    let claims = payload['claims'];
    if (!Array.isArray(claims)) { throw new ProfileResponseError('画像结果缺少 claims 数组'); }
    (claims as JsonMap[]).forEach((claim: JsonMap) => {
      if (!claim || typeof claim !== 'object' || !Array.isArray(claim['event_ids'])) {
        throw new ProfileResponseError('画像证据引用格式无效');
      }
      claim['event_ids'] = (claim['event_ids'] as string[]).map((id: string): string => {
        let original = this.originals.get(id);
        if (original !== undefined) { return original; }
        if (this.aliases.has(id)) { return id; }
        throw new ProfileResponseError('画像引用了本次输入不存在的证据');
      });
    });
  }
  private alias(id: string): string {
    let result = this.aliases.get(id);
    if (result === undefined) { throw new ProfileResponseError('画像输入包含无效证据'); }
    return result;
  }
}
