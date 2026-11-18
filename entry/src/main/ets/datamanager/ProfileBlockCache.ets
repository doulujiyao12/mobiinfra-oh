import { JSON as ArkJSON } from '@kit.ArkTS';
import { DataManagerStorage } from './DataManagerStorage';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerModelConfig, DataManagerProgressCallback, IndexedEvent, ProfileModelPayload,
  createDataManagerProgress } from './DataManagerTypes';
import { dataManagerInfo } from './DataManagerLog';
import { profileEvidenceText } from './ProfileEvidence';

// Factual/model policy identity is independent of checkpoint layout. Retain
// this identity so an unchanged validated published v1 domain can migrate.
export const PROFILE_BLOCK_POLICY: string = 'profile-month-tree-v1';
export interface ProfileBlockModel {
  profileCacheIdentity(config: DataManagerModelConfig): string;
  summarizeProfileBlock(domain: string, events: IndexedEvent[], config: DataManagerModelConfig,
    onWork?: (message: string) => void): Promise<ProfileModelPayload>;
  combineProfileBlocks(domain: string, blocks: ProfileModelPayload[], events: IndexedEvent[],
    config: DataManagerModelConfig, final: boolean, onWork?: (message: string) => void): Promise<ProfileModelPayload>;
}
interface ProfileBlockNode { key: string; hash: string; events: IndexedEvent[]; children: ProfileBlockNode[]; count: number; }
interface ProfileBlockResult { payload: ProfileModelPayload; nextDue: number; }
interface ProfileBlockReceipt {
  schema: string; key: string; hash: string; payloadHash: string; payload: ProfileModelPayload;
  identity?: string; mergedAt?: number; nextDue?: number;
}
interface ProfileBlockCheckpoint { schema: string; versions: ProfileBlockReceipt[]; }
const CHECKPOINT_SCHEMA: string = 'profile-compact-tree-v2';
export interface ProfileBlockStats { total: number; completed: number; reused: number; updated: number; modelCalls: number; }

// Only dirty period summaries have a deadline. The end of the local calendar
// period can bring the first pending merge forward; late edits still coalesce.
const QUARTER_INTERVAL_DAYS: number = 7;
const YEAR_INTERVAL_DAYS: number = 30;

function periodDeadline(parts: string[], mergedAt: number): number {
  const year = Number(parts[2]);
  const quarterly = parts.length === 4;
  const month = quarterly ? Number(parts[3].slice(-1)) * 3 : 12;
  const end = new Date(year, month, 1).getTime();
  const due = mergedAt + (quarterly ? QUARTER_INTERVAL_DAYS : YEAR_INTERVAL_DAYS) * 24 * 60 * 60 * 1000;
  return end > mergedAt ? Math.min(end, due) : due;
}

function earliestDue(left: number, right: number): number {
  return left && right ? Math.min(left, right) : left || right;
}

// Successful nodes are independent checkpoints, outside the published index.
// No previous profile is fed back into this tree: deleted facts cannot survive
// through a stale parent summary. The raw events remain the source of truth.
export class ProfileBlockCache {
  private directory: string;
  private storage: DataManagerStorage;
  private model: ProfileBlockModel;
  nextDue: number = 0;
  private identity: string = '';
  private asOf: number = 0;
  private updatedMonths: number = 0;
  private deferredPeriods: number = 0;
  stats: ProfileBlockStats = { total: 0, completed: 0, reused: 0, updated: 0, modelCalls: 0 };
  constructor(paths: DataManagerPaths, storage: DataManagerStorage, model: ProfileBlockModel) {
    this.directory = storage.join(paths.consolidationRoot, 'sync-cache', 'profile');
    this.storage = storage; this.model = model;
  }
  async build(domain: string, input: IndexedEvent[], config: DataManagerModelConfig,
    progress?: DataManagerProgressCallback): Promise<ProfileModelPayload> {
    this.nextDue = 0;
    this.asOf = Date.now();
    this.updatedMonths = 0;
    this.deferredPeriods = 0;
    if (!config.enabled || input.length === 0) {
      return { short_summary: '', summary: '', claims: [], generation: input.length === 0 ? 'empty' : 'model_unavailable' };
    }
    let events = input.slice().sort((a: IndexedEvent, b: IndexedEvent): number => a.event_id.localeCompare(b.event_id));
    let identity = this.storage.sha256Text(PROFILE_BLOCK_POLICY + this.model.profileCacheIdentity(config));
    this.identity = identity;
    let root = this.plan(domain, events, 0, identity);
    this.stats = { total: root.count, completed: 0, reused: 0, updated: 0, modelCalls: 0 };
    let result = await this.evaluate(domain, root, config, true, progress);
    dataManagerInfo('SYNC_PROFILE domain=' + domain + ' total=' + root.count + ' reused=' + this.stats.reused +
      ' updated=' + this.stats.updated + ' modelNodes=' + this.stats.modelCalls);
    this.nextDue = result.nextDue;
    if (progress) {
      progress(createDataManagerProgress('生成画像', '本次更新 ' + this.updatedMonths +
        ' 个月度分块，暂缓 ' + this.deferredPeriods + ' 个季度或年度合并',
        this.stats.completed, this.stats.total, 88));
    }
    return result.payload;
  }
  private plan(key: string, events: IndexedEvent[], level: number, identity: string): ProfileBlockNode {
    let groups: Record<string, IndexedEvent[]> = {};
    let children: ProfileBlockNode[] = [];
    // Stable decade/year/quarter/month buckets do not shift when old data is
    // inserted. Oversized months split by event-id hash, not ordinal position.
    if (level < 4 || events.length > 32 || (events.length > 1 && profileEvidenceText(events, true).length > 8000)) {
      events.forEach((event: IndexedEvent) => {
        let date = /^\d{4}-\d{2}/.test(event.event_date) ? event.event_date : '0000-01';
        let bucket = level === 0 ? date.substring(0, 3) : level === 1 ? date.substring(0, 4) :
          level === 2 ? date.substring(0, 4) + '-Q' + Math.ceil(Number(date.substring(5, 7)) / 3) :
          level === 3 ? date.substring(0, 7) : this.hashBucket(event.event_id, level - 3);
        if (!groups[bucket]) { groups[bucket] = []; }
        groups[bucket].push(event);
      });
      if (level >= 36) { throw new Error('画像分块过大，请检查事件标识'); }
      Object.keys(groups).sort().forEach((bucket: string) => {
        children.push(this.plan(key + '/' + bucket, groups[bucket], level + 1, identity));
      });
    }
    let content = children.length > 0 ? children.map((child: ProfileBlockNode): string => child.key + ':' + child.hash).join('|') :
      profileEvidenceText(events);
    let hash = this.storage.sha256Text(CHECKPOINT_SCHEMA + ':' + identity + ':' + key + ':' + content);
    return { key: key, hash: hash, events: events, children: children,
      count: 1 + children.reduce((sum: number, child: ProfileBlockNode): number => sum + child.count, 0) };
  }
  private hashBucket(id: string, bits: number): string {
    let hex = this.storage.sha256Text(id);
    let binary = '';
    for (let index = 0; index < Math.ceil(bits / 4); index++) {
      binary += parseInt(hex.substring(index, index + 1), 16).toString(2).padStart(4, '0');
    }
    return binary.substring(0, bits);
  }
  private report(domain: string, progress?: DataManagerProgressCallback): void {
    if (progress) {
      progress(createDataManagerProgress('生成画像', '摘要处理 ' + this.stats.completed + '/' + this.stats.total +
        '，缓存复用 ' + this.stats.reused + '，已生成 ' + this.stats.modelCalls,
        this.stats.completed, this.stats.total, 88));
    }
  }
  private async evaluate(domain: string, node: ProfileBlockNode, config: DataManagerModelConfig, final: boolean,
    progress?: DataManagerProgressCallback): Promise<ProfileBlockResult> {
    let filename = this.storage.join(this.directory, this.storage.sha256Text(node.key) + '.v2.json');
    let checkpoint = this.storage.readJson<ProfileBlockCheckpoint | null>(filename, null);
    let versions: ProfileBlockReceipt[] = checkpoint && checkpoint.schema === CHECKPOINT_SCHEMA &&
      Array.isArray(checkpoint.versions) ? checkpoint.versions.filter((item: ProfileBlockReceipt): boolean =>
        item !== null && typeof item === 'object' && typeof item.hash === 'string') : [];
    let cached = versions.find((item: ProfileBlockReceipt): boolean => item.hash === node.hash);
    if (cached && !(cached.schema === CHECKPOINT_SCHEMA && cached.key === node.key &&
      cached.payload && Array.isArray(cached.payload.claims) &&
      cached.payloadHash === this.storage.sha256Text(ArkJSON.stringify(cached.payload)) &&
      ['model', 'model_empty', 'model_block'].includes(cached.payload.generation))) { cached = undefined; }
    if (cached && (!cached.nextDue || cached.nextDue > this.asOf)) {
      this.stats.completed += node.count; this.stats.reused += node.count; this.report(domain, progress);
      return { payload: cached.payload, nextDue: cached.nextDue || 0 };
    }
    let blocks: ProfileModelPayload[] = [];
    let nextDue = 0;
    for (let child of node.children) {
      let result = await this.evaluate(domain, child, config, false, progress);
      blocks.push(result.payload);
      nextDue = earliestDue(nextDue, result.nextDue);
    }
    // Exact evidence hashes are the only route to reusing content. A previous
    // (different) hash supplies a clock only, never claims about removed facts.
    const parts = node.key.split('/');
    const isPeriod = parts.length === 3 || parts.length === 4;
    const previous = isPeriod ? versions.find((v: ProfileBlockReceipt): boolean =>
      v.schema === CHECKPOINT_SCHEMA && v.identity === this.identity && v.key === node.key && !!v.mergedAt) : undefined;
    const due = previous ? periodDeadline(parts, previous.mergedAt || 0) : 0;
    if (!cached && previous && previous.hash !== node.hash && blocks.length > 1 && due > this.asOf) {
      const fresh: ProfileModelPayload = { short_summary: '', summary: '', claims: [], generation: 'model_block' };
      for (let block of blocks) { fresh.claims = fresh.claims.concat(block.claims); }
      this.stats.completed++; this.deferredPeriods++; this.report(domain, progress);
      return { payload: fresh, nextDue: earliestDue(nextDue, due) };
    }
    let payload: ProfileModelPayload;
    if (blocks.length === 1 && !final) { payload = blocks[0]; }
    else if (cached) { payload = cached.payload; }
    else {
      if (progress) {
        progress(createDataManagerProgress('生成画像', '正在' + (blocks.length === 0 ? '分析新增事实' : '合并变化摘要') +
          '，缓存复用 ' + this.stats.reused + '，已完成 ' + this.stats.modelCalls + ' 个模型步骤',
          this.stats.completed, this.stats.total, 88));
      }
      this.stats.modelCalls++;
      let onWork = (message: string): void => {
        if (progress) { progress(createDataManagerProgress('生成画像', message + '，缓存复用 ' + this.stats.reused,
          this.stats.completed, this.stats.total, 88)); }
      };
      payload = blocks.length === 0 ? await this.model.summarizeProfileBlock(domain, node.events, config, onWork) :
        await this.model.combineProfileBlocks(domain, blocks, node.events, config, final, onWork);
    }
    if (!payload || !Array.isArray(payload.claims) ||
      !['model', 'model_empty', 'model_block'].includes(payload.generation)) { throw new Error('画像摘要未完成，请重试同步'); }
    if (!cached && parts.length === 5) { this.updatedMonths++; }
    let mergedAt = cached ? cached.mergedAt : previous?.mergedAt;
    if (!cached && isPeriod && blocks.length > 1) { mergedAt = Date.now(); }
    let receipt: ProfileBlockReceipt = { identity: this.identity, mergedAt: mergedAt,
      nextDue: nextDue, schema: CHECKPOINT_SCHEMA, key: node.key, hash: node.hash,
      payloadHash: this.storage.sha256Text(ArkJSON.stringify(payload)), payload: payload };
    // Keep two bounded versions: automatic selected-source updates and full
    // manual syncs must not evict one another's valid checkpoints.
    let saved: ProfileBlockCheckpoint = { schema: CHECKPOINT_SCHEMA,
      versions: [receipt].concat(versions.filter((item: ProfileBlockReceipt): boolean => item.hash !== node.hash)).slice(0, 2) };
    this.storage.writeJsonAtomic(filename, saved);
    this.stats.completed++; this.stats.updated++; this.report(domain, progress);
    return { payload: payload, nextDue: nextDue };
  }
}
