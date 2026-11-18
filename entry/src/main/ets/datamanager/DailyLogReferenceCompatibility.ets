import { dailyLogEntryBlocks, DailyLogEntryBlock, dailyLogMaxEntryId, duplicateDailyLogEntryIds } from '../utils/DailyLogEntryIdentity';
import { parseJsonCompat, stringifyJsonCompat } from '../utils/JsonCompat';
import { DataManagerStorage } from './DataManagerStorage';
import { DataManagerPaths } from './DataManagerPaths';
import { DAILY_LOG_METADATA_PATTERN, parseDailyLogDocument } from './DataManagerUtils';
import { ConsolidatedState, createStringMap, JsonMap, StringMap } from './DataManagerTypes';

// Read-only compatibility for logs already renumbered by the withdrawn repair.
// Never rewrite logs, change stored references, or start a history migration.
// Only use a verified pre-repair backup while the saved facts still use its IDs.
export function compatibleDailyLogText(content: string, path: string, paths: DataManagerPaths, storage: DataManagerStorage): string {
  let backupDir = storage.join(paths.consolidationRoot, 'source-repair-backups');
  if (!storage.exists(backupDir)) { return content; }
  let relative = storage.relativePath(paths.dailyLogRoot, path).replace(/\\/g, '/');
  if (!/^\d{4}-\d{2}-\d{2}\/[^/]+\.md$/.test(relative)) { return content; }
  let state = storage.readJson<ConsolidatedState | null>(paths.outputStatePath(relative.substring(0, 7), storage.basename(path)), null);
  if (!state || !state.metadata || !Array.isArray(state.records)) { return content; }
  let processedHashes: StringMap = state.metadata.processed_entry_hashes || createStringMap();
  let refs = new Set<string>(Object.keys(processedHashes));
  for (let record of state.records) { for (let ref of record.source_refs || []) { refs.add(ref); } }
  let document = parseDailyLogDocument(content);
  let current = dailyLogEntryBlocks(document.body);
  let currentRefs = new Set<string>(current.map((entry: DailyLogEntryBlock): string => relative + '#' + entry.index));
  if (!Array.from(refs).some((ref: string): boolean => ref.startsWith(relative + '#') && !currentRefs.has(ref))) { return content; }
  let compatible: string | null = null;
  for (let name of storage.listDir(backupDir)) {
    if (!/^[a-f0-9]{64}\.md$/.test(name)) { continue; }
    let original = storage.readText(storage.join(backupDir, name), '');
    if (!original || name !== storage.sha256Text(path + '\n' + original) + '.md') { continue; }
    let projected = projectPreviousIds(original, content, relative, refs);
    if (projected === null) { continue; }
    if (compatible !== null && compatible !== projected) { return content; }
    compatible = projected;
  }
  return compatible === null ? content : compatible;
}

function projectPreviousIds(original: string, content: string, relative: string, refs: Set<string>): string | null {
  let before = parseDailyLogDocument(original);
  let after = parseDailyLogDocument(content);
  let oldEntries = dailyLogEntryBlocks(before.body);
  let newEntries = dailyLogEntryBlocks(after.body);
  let duplicateIds = duplicateDailyLogEntryIds(oldEntries);
  if (duplicateIds.length === 0 || newEntries.length < oldEntries.length ||
    stringifyJsonCompat(before.workflow_metadata) !== stringifyJsonCompat(after.workflow_metadata)) { return null; }
  let originalBatches: StringMap = before.entry_batch_ids || createStringMap();
  let currentBatches: StringMap = after.entry_batch_ids || createStringMap();
  let highWater = dailyLogMaxEntryId(before.body, before.latest_entry_index, originalBatches);
  let usedOldRef = false;
  for (let i = 0; i < oldEntries.length; i++) {
    let oldId = oldEntries[i].index;
    let renumbered = duplicateIds.indexOf(oldId) >= 0;
    let expectedId = renumbered ? ++highWater : oldId;
    if (newEntries[i].index !== expectedId || oldEntries[i].text !== newEntries[i].text) { return null; }
    if (renumbered) {
      if (refs.has(relative + '#' + expectedId)) { return null; } // Already analysed under new IDs.
      if (refs.has(relative + '#' + oldId)) { usedOldRef = true; }
    } else if (originalBatches[String(oldId)] !== currentBatches[String(oldId)]) { return null; }
  }
  if (!usedOldRef || newEntries.slice(oldEntries.length).some((entry: DailyLogEntryBlock): boolean => entry.index <= highWater)) { return null; }
  let suffixStart = newEntries.length > oldEntries.length ? newEntries[oldEntries.length].numberStart : after.body.length;
  let prefix = after.body.substring(0, suffixStart);
  for (let i = oldEntries.length - 1; i >= 0; i--) {
    prefix = prefix.substring(0, newEntries[i].numberStart) + String(oldEntries[i].index) + prefix.substring(newEntries[i].numberEnd);
  }
  if (prefix.trim() !== before.body.trim()) { return null; }
  if (newEntries.length === oldEntries.length) { return original; }
  let header = DAILY_LOG_METADATA_PATTERN.exec(content);
  if (!header) { return null; }
  let metadata: JsonMap;
  try { metadata = parseJsonCompat<JsonMap>(header[1]); } catch (e) { return null; }
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) { return null; }
  let batches: StringMap = createStringMap();
  for (let key of Object.keys(currentBatches)) { batches[key] = currentBatches[key]; }
  for (let key of Object.keys(originalBatches)) { batches[key] = originalBatches[key]; }
  metadata['entry_batch_ids'] = batches;
  return '<!-- DAILY_LOG_METADATA\n' + stringifyJsonCompat(metadata, 2) + '\n-->\n\n' +
    before.body.trimEnd() + '\n\n' + after.body.substring(suffixStart);
}
