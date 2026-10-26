import { JSON as ArkJSON } from '@kit.ArkTS';
import { DataManagerStorage } from './DataManagerStorage';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerModelConfig, DataManagerProgressCallback, IndexedEvent, ProfileModelPayload,
  createDataManagerProgress } from './DataManagerTypes';
import { dataManagerInfo } from './DataManagerLog';

export const PROFILE_BLOCK_POLICY: string = 'profile-month-tree-v1';
export interface ProfileBlockModel {
  profileCacheIdentity(config: DataManagerModelConfig): string;
  summarizeProfileBlock(domain: string, events: IndexedEvent[], config: DataManagerModelConfig): Promise<ProfileModelPayload>;
  combineProfileBlocks(domain: string, blocks: ProfileModelPayload[], events: IndexedEvent[],
    config: DataManagerModelConfig, final: boolean): Promise<ProfileModelPayload>;
}
interface ProfileBlockNode { key: string; hash: string; events: IndexedEvent[]; children: ProfileBlockNode[]; count: number; }
interface ProfileBlockReceipt { schema: string; key: string; hash: string; payloadHash: string; payload: ProfileModelPayload; }
export interface ProfileBlockStats { total: number; completed: number; reused: number; updated: number; modelCalls: number; }

// Successful nodes are independent checkpoints, outside the published index.
// No previous profile is fed back into this tree: deleted facts cannot survive
// through a stale parent summary. The raw events remain the source of truth.
export class ProfileBlockCache {
  private directory: string;
  private storage: DataManagerStorage;
  private model: ProfileBlockModel;
  stats: ProfileBlockStats = { total: 0, completed: 0, reused: 0, updated: 0, modelCalls: 0 };
  constructor(paths: DataManagerPaths, storage: DataManagerStorage, model: ProfileBlockModel) {
    this.directory = storage.join(paths.consolidationRoot, 'sync-cache', 'profile');
    this.storage = storage; this.model = model;
  }
  async build(domain: string, input: IndexedEvent[], config: DataManagerModelConfig,
    progress?: DataManagerProgressCallback): Promise<ProfileModelPayload> {
    if (!config.enabled || input.length === 0) {
      return { short_summary: '', summary: '', claims: [], generation: input.length === 0 ? 'empty' : 'model_unavailable' };
    }
    let events = input.slice().sort((a: IndexedEvent, b: IndexedEvent): number => a.event_id.localeCompare(b.event_id));
    let identity = this.storage.sha256Text(PROFILE_BLOCK_POLICY + this.model.profileCacheIdentity(config));
    let root = this.plan(domain, events, 0, identity);
    this.stats = { total: root.count, completed: 0, reused: 0, updated: 0, modelCalls: 0 };
    let result = await this.evaluate(domain, root, config, true, progress);
    dataManagerInfo('SYNC_PROFILE domain=' + domain + ' total=' + root.count + ' reused=' + this.stats.reused +
      ' updated=' + this.stats.updated + ' modelNodes=' + this.stats.modelCalls);
    return result;
  }
  private plan(key: string, events: IndexedEvent[], level: number, identity: string): ProfileBlockNode {
    let groups: Record<string, IndexedEvent[]> = {};
    let children: ProfileBlockNode[] = [];
    // Stable decade/year/quarter/month buckets do not shift when old data is
    // inserted. Oversized months split by event-id hash, not ordinal position.
    if (level < 4 || events.length > 48 || (events.length > 1 && ArkJSON.stringify(events).length > 20000)) {
      events.forEach((event: IndexedEvent) => {
        let date = /^\d{4}-\d{2}/.test(event.event_date) ? event.event_date : '0000-01';
        let bucket = level === 0 ? date.substring(0, 3) : level === 1 ? date.substring(0, 4) :
          level === 2 ? date.substring(0, 4) + '-Q' + Math.ceil(Number(date.substring(5, 7)) / 3) :
          level === 3 ? date.substring(0, 7) : this.storage.sha256Text(event.event_id).substring(0, level - 3);
        if (!groups[bucket]) { groups[bucket] = []; }
        groups[bucket].push(event);
      });
      if (level >= 12) { throw new Error('画像分块过大，请检查事件标识'); }
      Object.keys(groups).sort().forEach((bucket: string) => {
        children.push(this.plan(key + '/' + bucket, groups[bucket], level + 1, identity));
      });
    }
    let content = children.length > 0 ? children.map((child: ProfileBlockNode): string => child.key + ':' + child.hash).join('|') :
      ArkJSON.stringify(events);
    let hash = this.storage.sha256Text(identity + ':' + key + ':' + content);
    return { key: key, hash: hash, events: events, children: children,
      count: 1 + children.reduce((sum: number, child: ProfileBlockNode): number => sum + child.count, 0) };
  }
  private report(domain: string, progress?: DataManagerProgressCallback): void {
    if (progress) {
      progress(createDataManagerProgress('生成画像', '正在更新画像摘要 ' + this.stats.completed + '/' + this.stats.total +
        '，复用 ' + this.stats.reused + '，更新 ' + this.stats.updated,
        this.stats.completed, this.stats.total, 88));
    }
  }
  private async evaluate(domain: string, node: ProfileBlockNode, config: DataManagerModelConfig, final: boolean,
    progress?: DataManagerProgressCallback): Promise<ProfileModelPayload> {
    let filename = this.storage.join(this.directory, this.storage.sha256Text(node.key) + '.json');
    let cached = this.storage.readJson<ProfileBlockReceipt | null>(filename, null);
    if (cached && cached.schema === PROFILE_BLOCK_POLICY && cached.key === node.key && cached.hash === node.hash &&
      cached.payload && Array.isArray(cached.payload.claims) &&
      cached.payloadHash === this.storage.sha256Text(ArkJSON.stringify(cached.payload)) &&
      (cached.payload.generation === 'model' || cached.payload.generation === 'model_empty' || cached.payload.generation === 'model_block')) {
      this.stats.completed += node.count; this.stats.reused += node.count; this.report(domain, progress);
      return cached.payload;
    }
    let blocks: ProfileModelPayload[] = [];
    for (let child of node.children) { blocks.push(await this.evaluate(domain, child, config, false, progress)); }
    let payload: ProfileModelPayload;
    if (blocks.length === 1 && !final) { payload = blocks[0]; }
    else {
      this.stats.modelCalls++;
      payload = blocks.length === 0 ? await this.model.summarizeProfileBlock(domain, node.events, config) :
        await this.model.combineProfileBlocks(domain, blocks, node.events, config, final);
    }
    if (!payload || !Array.isArray(payload.claims) ||
      !['model', 'model_empty', 'model_block'].includes(payload.generation)) { throw new Error('画像摘要未完成，请重试同步'); }
    let receipt: ProfileBlockReceipt = { schema: PROFILE_BLOCK_POLICY, key: node.key, hash: node.hash,
      payloadHash: this.storage.sha256Text(ArkJSON.stringify(payload)), payload: payload };
    this.storage.writeJsonAtomic(filename, receipt);
    this.stats.completed++; this.stats.updated++; this.report(domain, progress);
    return payload;
  }
}
