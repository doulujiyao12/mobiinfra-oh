import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { WatchRecordingClient, watchConnectionMessage } from './WatchRecordingClient';
import { BusinessError } from '@kit.BasicServicesKit';
import { RecordingStore } from './RecordingStore';
import { RecordingRecord } from './RecordingTypes';

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
    progress: (text: string) => void, onSaved: (record: RecordingRecord) => void): Promise<number> {
    let epoch = ++this.epoch; let count = 0;
    let client = new WatchRecordingClient(context); this.client = client;
    try {
      progress('正在连接手表'); await client.connect(deviceId);
      if (epoch !== this.epoch) { throw new Error('同步已停止'); }
      let cursor = '';
      do {
        let page = await client.list(cursor);
        for (let item of page.recordings) {
          if (epoch !== this.epoch) { throw new Error('同步已停止'); }
          progress('正在接收第 ' + (count + 1) + ' 条录音');
          let existing = store.findWatch(client.identity(), item.id);
          // Respect an explicit local audio deletion; periodic watch sync must
          // not silently download the same recording again.
          if (existing?.audioDeleted) { continue; }
          let saved = await client.download(item.id, existing === null ? '' : store.audioPath(existing.id));
          if (epoch !== this.epoch) { throw new Error('同步已停止'); }
          progress('校验并保存第 ' + (count + 1) + ' 条录音');
          let record = await store.importWatch(saved);
          // The managed library now owns a durable copy; retain no second audio cache.
          if (saved.path !== store.audioPath(record.id) && fs.accessSync(saved.path)) {
            try { fs.unlinkSync(saved.path); } catch (e) { /* A verified library copy already exists. */ }
          }
          count++; onSaved(record);
        }
        if (page.nextCursor && page.nextCursor === cursor) { throw new Error('手表录音列表未能继续，请重新连接'); }
        cursor = page.nextCursor;
      } while (cursor.length > 0);
      return count;
    } finally { await client.close(); if (this.client === client) { this.client = null; } }
  }
  async cancel(): Promise<void> { this.epoch++; let client = this.client; this.client = null; await client?.close(); }
}
