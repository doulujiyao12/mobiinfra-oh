import { describe, it, expect } from '@ohos/hypium';
import { DataManagerFacade } from '../main/ets/datamanager/DataManagerFacade';
import {
  shouldOfferSyncReminder, syncSnapshotTimeMs, SYNC_REMINDER_INTERVAL_MS
} from '../main/ets/datamanager/DataManagerSyncReminder';

export default function dataManagerSyncReminderUnitTest() {
  describe('dataManagerSyncReminderUnitTest', () => {
    it('requiresAnExistingSyncThreeDaysOldAndNewRecords', 0, () => {
      let lastSyncAt = '2026-09-20T12:00:00';
      let lastSyncMs = syncSnapshotTimeMs(lastSyncAt);
      expect(Number.isFinite(lastSyncMs)).assertTrue();
      expect(shouldOfferSyncReminder(lastSyncAt, true, lastSyncMs + SYNC_REMINDER_INTERVAL_MS - 1)).assertFalse();
      expect(shouldOfferSyncReminder(lastSyncAt, true, lastSyncMs + SYNC_REMINDER_INTERVAL_MS)).assertTrue();
      expect(shouldOfferSyncReminder(lastSyncAt, false, lastSyncMs + SYNC_REMINDER_INTERVAL_MS)).assertFalse();
      expect(shouldOfferSyncReminder('', true, lastSyncMs + SYNC_REMINDER_INTERVAL_MS)).assertFalse();
      expect(shouldOfferSyncReminder('2026-02-30T12:00:00', true, lastSyncMs)).assertFalse();
    });

    it('comparesSavedEntryCountsWithTheLastSuccessfulSnapshot', 0, () => {
      let root = '/tmp/sync-reminder-' + String(Date.now());
      let facade = new DataManagerFacade(root);
      let storage = facade.storage;
      let lastSyncAt = '2026-09-20T12:00:00';
      let nowMs = syncSnapshotTimeMs(lastSyncAt) + SYNC_REMINDER_INTERVAL_MS;
      let dailyPath = storage.join(facade.paths.dailyLogRoot, '2026-09-20', 'test.md');
      let snapshotPath = storage.join(facade.paths.consolidationRoot, 'daily-log-snapshot.json');
      try {
        storage.writeTextAtomic(dailyPath, '# 记录\n\n1. 旧记录\n');
        storage.writeJsonAtomic(snapshotPath, {
          generated_at: lastSyncAt,
          root: 'workflows/daily-log',
          file_count: 1,
          entry_count: 1,
          tree_hash: 'last-sync',
          files: [{ path: '2026-09-20/test.md', sha256: 'old', entry_count: 1 }]
        });
        expect(facade.shouldRemindToSync(nowMs)).assertFalse();
        storage.writeTextAtomic(dailyPath, '# 记录\n\n1. 旧记录\n\n2. 新记录\n');
        expect(facade.shouldRemindToSync(nowMs)).assertTrue();
      } finally {
        storage.removeTree(root);
      }
    });

    it('usesFirstOpenTimeWhenTheAppHasNeverSynced', 0, () => {
      let root = '/tmp/sync-reminder-first-open-' + String(Date.now());
      let facade = new DataManagerFacade(root);
      let firstOpenAt = '2026-09-20T12:00:00';
      let nowMs = syncSnapshotTimeMs(firstOpenAt) + SYNC_REMINDER_INTERVAL_MS;
      try {
        facade.storage.writeTextAtomic(
          facade.storage.join(facade.paths.dailyLogRoot, '2026-09-20', 'test.md'), '# 记录\n\n1. 已保存的记录\n');
        expect(facade.shouldRemindToSync(nowMs)).assertFalse();
        expect(facade.shouldRemindToSync(nowMs, firstOpenAt)).assertTrue();
      } finally {
        facade.storage.removeTree(root);
      }
    });
  });
}
