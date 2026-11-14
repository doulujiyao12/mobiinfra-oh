import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { WatchRecordingClient, watchConnectionMessage } from './WatchRecordingClient';
import { BusinessError } from '@kit.BasicServicesKit';
import { RecordingStore } from './RecordingStore';
import { RecordingRecord } from './RecordingTypes';
import { RecordingWatchCatalog, RecordingWatchItem, RecordingWatchSelection } from './RecordingWatchSelection';

export interface RecordingWatchDevice { id: string; name: string; }
export class RecordingWatchSync {
  private client: WatchRecordingClient | null = null;
  private epoch: number = 0;
  async discover(context: common.UIAbilityContext): Promise<RecordingWatchDevice[]> {
    try {
      let devices = await WatchRecordingClient.devices(context);
      return devices.map((device): RecordingWatchDevice => ({ id: device.randomId, name: device.name || '我的手表' }));
    } catch (e) { throw new Error(watchConnectionMessage(e as BusinessError)); }
  }
  async sync(context: common.UIAbilityContext, deviceId: string, store: RecordingStore,
    progress: (text: string) => void, onSaved: (record: RecordingRecord) => void,
    selection: RecordingWatchSelection): Promise<number> {
    const ids: string[] = Array.from(new Set<string>(selection.recordingIds));
    if (!selection.sourceId || ids.length === 0) { throw new Error('请先选择要同步的手表录音'); }
    let epoch = ++this.epoch; let count = 0;
    let client = new WatchRecordingClient(context); this.client = client;
    try {
      progress('正在连接手表'); await client.connect(deviceId);
      if (epoch !== this.epoch) { throw new Error('同步已停止'); }
      if (client.identity() !== selection.sourceId) { throw new Error('手表录音目录已变化，请重新选择录音'); }
      const existingRecords: Map<string, RecordingRecord> = this.localRecords(store, client.identity());
      for (let index = 0; index < ids.length; index++) {
        if (epoch !== this.epoch) { throw new Error('同步已停止'); }
        progress('正在接收录音 ' + (index + 1) + '/' + ids.length);
        let existing = existingRecords.get(ids[index]);
        // Keep an explicit local audio deletion even if it changed after listing.
        if (existing?.audioDeleted) { continue; }
        let saved = await client.download(ids[index], existing === undefined ? '' : store.audioPath(existing.id));
        if (epoch !== this.epoch) { throw new Error('同步已停止'); }
        progress('校验并保存第 ' + (count + 1) + ' 条录音');
        let record = await store.importWatch(saved);
        // The managed library now owns a durable copy; retain no second audio cache.
        if (saved.path !== store.audioPath(record.id) && fs.accessSync(saved.path)) {
          try { fs.unlinkSync(saved.path); } catch (e) { /* A verified library copy already exists. */ }
        }
        count++; onSaved(record);
      }
      return count;
    } finally { await client.close(); if (this.client === client) { this.client = null; } }
  }

  private localRecords(store: RecordingStore, sourceId: string): Map<string, RecordingRecord> {
    const records: Map<string, RecordingRecord> = new Map<string, RecordingRecord>();
    for (const record of store.list()) {
      if (record.watch?.sourceId === sourceId) { records.set(record.watch.recordingId, record); }
    }
    return records;
  }

  async catalog(context: common.UIAbilityContext, deviceId: string, store: RecordingStore,
    progress: (text: string) => void): Promise<RecordingWatchCatalog> {
    const epoch = ++this.epoch;
    const client = new WatchRecordingClient(context); this.client = client;
    try {
      progress('正在连接手表'); await client.connect(deviceId);
      if (epoch !== this.epoch) { throw new Error('连接已停止'); }
      const sourceId = client.identity();
      if (!sourceId) { throw new Error('手表身份信息无效，请重新连接'); }
      const local = this.localRecords(store, sourceId);
      const items: RecordingWatchItem[] = [];
      const seen: Set<string> = new Set<string>();
      const cursors: Set<string> = new Set<string>();
      let cursor = '';
      do {
        if (cursors.has(cursor)) { throw new Error('手表录音列表未能继续，请重新连接'); }
        cursors.add(cursor);
        const page = await client.list(cursor);
        if (epoch !== this.epoch) { throw new Error('连接已停止'); }
        for (const recording of page.recordings) {
          if (seen.has(recording.id)) { continue; }
          if (!recording.id || !Number.isFinite(recording.createdAt) || !Number.isFinite(recording.durationMs) ||
            !Number.isSafeInteger(recording.bytes) || recording.bytes <= 44 || recording.durationMs < 0) {
            throw new Error('手表录音信息无效，请刷新列表');
          }
          seen.add(recording.id);
          const existing = local.get(recording.id);
          items.push({ id: recording.id, createdAt: recording.createdAt, durationMs: recording.durationMs,
            bytes: recording.bytes, title: existing?.title || '',
            localState: existing?.audioDeleted ? 'audio-deleted' : existing ? 'saved' : 'new' });
        }
        progress('已找到 ' + items.length + ' 条录音');
        cursor = page.nextCursor;
      } while (cursor.length > 0);
      items.sort((left: RecordingWatchItem, right: RecordingWatchItem): number => right.createdAt - left.createdAt);
      return { sourceId: sourceId, items: items };
    } finally { await client.close(); if (this.client === client) { this.client = null; } }
  }
  async cancel(): Promise<void> { this.epoch++; let client = this.client; this.client = null; await client?.close(); }
}
