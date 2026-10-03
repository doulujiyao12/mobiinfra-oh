export const SYNC_REMINDER_INTERVAL_MS: number = 3 * 24 * 60 * 60 * 1000;

// DataManager 快照使用本地时间，不依赖运行环境对无时区字符串的解析。
export function syncSnapshotTimeMs(value: string): number {
  let match = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})$/.exec(value);
  if (match === null) {
    return NaN;
  }
  let year = Number(match[1]);
  let month = Number(match[2]);
  let day = Number(match[3]);
  let hour = Number(match[4]);
  let minute = Number(match[5]);
  let second = Number(match[6]);
  let date = new Date(year, month - 1, day, hour, minute, second);
  if (date.getFullYear() !== year || date.getMonth() + 1 !== month || date.getDate() !== day ||
    date.getHours() !== hour || date.getMinutes() !== minute || date.getSeconds() !== second) {
    return NaN;
  }
  return date.getTime();
}

export function shouldOfferSyncReminder(lastSyncAt: string, hasNewRecords: boolean,
  nowMs: number = Date.now()): boolean {
  if (!hasNewRecords) {
    return false;
  }
  let lastSyncMs = syncSnapshotTimeMs(lastSyncAt);
  return Number.isFinite(lastSyncMs) && nowMs >= lastSyncMs &&
    nowMs - lastSyncMs >= SYNC_REMINDER_INTERVAL_MS;
}
