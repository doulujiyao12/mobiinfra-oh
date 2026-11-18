// Daily-log entry IDs are persisted source identities, not display positions.
// Keep the same entry boundaries for allocation, parsing and legacy repair.
export interface DailyLogEntryBlock {
  index: number;
  text: string;
  numberStart: number;
  numberEnd: number;
}

export function dailyLogEntryBlocks(body: string): DailyLogEntryBlock[] {
  let entries: DailyLogEntryBlock[] = [];
  let pattern = /(?:^|\n\s*\n)(\d+)\.\s+([\s\S]*?)(?=\n\s*\n\d+\.\s+|$)/g;
  let match: RegExpExecArray | null = pattern.exec(body);
  while (match !== null) {
    let index = Number(match[1]);
    if (!Number.isSafeInteger(index)) { throw new Error('采集日志条目编号超出范围'); }
    let start = match.index + match[0].indexOf(match[1] + '.');
    entries.push({ index: index, text: match[2].trim(), numberStart: start, numberEnd: start + match[1].length });
    match = pattern.exec(body);
  }
  return entries;
}

export function dailyLogMaxEntryId(body: string, highWater: number = 0, batchIds: Record<string, string> = {}): number {
  let maximum = Number.isSafeInteger(highWater) && highWater > 0 ? highWater : 0;
  for (let entry of dailyLogEntryBlocks(body)) { maximum = Math.max(maximum, entry.index); }
  for (let key of Object.keys(batchIds)) {
    if (/^[1-9]\d*$/.test(key) && Number.isSafeInteger(Number(key))) { maximum = Math.max(maximum, Number(key)); }
  }
  if (maximum >= Number.MAX_SAFE_INTEGER) { throw new Error('采集日志条目编号超出范围'); }
  return maximum;
}

export function duplicateDailyLogEntryIds(entries: DailyLogEntryBlock[]): number[] {
  let seen = new Set<number>();
  let duplicates = new Set<number>();
  for (let entry of entries) {
    if (seen.has(entry.index)) { duplicates.add(entry.index); }
    seen.add(entry.index);
  }
  return Array.from(duplicates);
}
