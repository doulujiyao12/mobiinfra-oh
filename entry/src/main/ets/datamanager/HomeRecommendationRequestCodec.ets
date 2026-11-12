import { HomeRecommendationPlannerEvent, JsonMap } from './DataManagerTypes';

// The JSON and transport layers share this budget: one request and two retries.
export const HOME_RECOMMENDATION_ATTEMPTS: number = 3;

export function isRetryableHomeRecommendationRequestError(message: string): boolean {
  if (/MODEL_REPEATED_OUTPUT|取消|终止|已撤回|cancel|abort|destroy|登录|请先配置/i.test(message)) { return false; }
  let http = /Cloud HTTP (\d{3})/.exec(message);
  if (http) {
    let status = Number(http[1]);
    return status === 408 || status === 429 || (status >= 500 && status <= 599);
  }
  return /time(?:d)?[\s_-]*out|connection reset|connection refused|network|socket|连接中断/i.test(message);
}

// Short IDs belong only to this request. Persisted cards retain the original
// event IDs, so this does not invalidate existing indexes or reminder caches.
export class HomeRecommendationRequestCodec {
  private aliases: Map<string, string> = new Map<string, string>();
  private originals: Map<string, string> = new Map<string, string>();

  constructor(events: HomeRecommendationPlannerEvent[]) {
    events.forEach((event: HomeRecommendationPlannerEvent, index: number) => {
      if (event.event_id.length === 0 || this.aliases.has(event.event_id)) {
        throw new Error('提醒分析输入包含空编号或重复事项');
      }
      let alias = 'e' + String(index + 1);
      this.aliases.set(event.event_id, alias);
      this.originals.set(alias, event.event_id);
    });
  }

  encodeId(id: string): string {
    let alias = this.aliases.get(id);
    if (alias === undefined) { throw new Error('提醒分析输入包含无效事项'); }
    return alias;
  }

  validateAndDecode(payload: JsonMap): void {
    if (!Array.isArray(payload['recommendations'])) { throw new Error('关注规划缺少 recommendations 数组'); }
    let items = payload['recommendations'] as JsonMap[];
    let covered: Set<string> = new Set<string>();
    let decoded: string[][] = [];
    for (let item of items) {
      if (!item || typeof item !== 'object' || Array.isArray(item) || typeof item['title'] !== 'string' ||
        !(item['title'] as string).trim() || !Array.isArray(item['source_event_ids'])) {
        throw new Error('关注规划的 title 或 source_event_ids 字段不完整');
      }
      let ids = item['source_event_ids'] as string[];
      if (ids.length === 0) { throw new Error('关注规划的 source_event_ids 不能为空'); }
      let withinCard: Set<string> = new Set<string>();
      let originals: string[] = [];
      for (let id of ids) {
        if (typeof id !== 'string' || !this.originals.has(id.trim())) {
          throw new Error('关注规划包含未知来源编号；只能使用本次输入的 event_id（e1、e2 等）');
        }
        let alias = id.trim();
        if (withinCard.has(alias)) { continue; }
        if (covered.has(alias)) { throw new Error('关注规划将 ' + alias + ' 重复分配到多张卡片；同一事项只能归入一张卡片'); }
        withinCard.add(alias);
        covered.add(alias);
        originals.push(this.originals.get(alias) as string);
      }
      decoded.push(originals);
    }
    // A deliberate omission is different from an incomplete/truncated reply.
    // Retain full decision coverage without forcing every candidate onto Home.
    if (payload['skipped'] !== undefined && !Array.isArray(payload['skipped'])) {
      throw new Error('关注筛选的 skipped 必须是数组');
    }
    let skipped = (payload['skipped'] || []) as JsonMap[];
    let decodedSkipped: string[] = [];
    for (let item of skipped) {
      if (!item || typeof item !== 'object' || Array.isArray(item) || typeof item['event_id'] !== 'string' ||
        (item['reason'] !== 'resolved' && item['reason'] !== 'low_value' && item['reason'] !== 'not_now')) {
        throw new Error('关注筛选的 skipped 需要 event_id 和 reason（resolved、low_value 或 not_now）');
      }
      let alias = (item['event_id'] as string).trim();
      if (!this.originals.has(alias)) { throw new Error('关注筛选包含未知来源编号；只能使用本次输入的 event_id'); }
      if (covered.has(alias)) { throw new Error('关注筛选将 ' + alias + ' 重复分配；不能同时推荐和跳过同一事项'); }
      covered.add(alias);
      decodedSkipped.push(this.originals.get(alias) as string);
    }
    let missing = Array.from(this.originals.keys()).filter((id: string): boolean => !covered.has(id));
    if (missing.length > 0) {
      throw new Error('关注规划遗漏输入事项：已覆盖 ' + covered.size + '/' + this.originals.size +
        '，缺少 ' + missing.slice(0, 24).join('、') + (missing.length > 24 ? '等' : '') + '；每条输入须归入 recommendations 或说明原因放入 skipped');
    }
    // Do not partially mutate an invalid response before a corrective retry.
    items.forEach((item: JsonMap, index: number) => { item['source_event_ids'] = decoded[index]; });
    skipped.forEach((item: JsonMap, index: number) => { item['event_id'] = decodedSkipped[index]; });
  }
}
