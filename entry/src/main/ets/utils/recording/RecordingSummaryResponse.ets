import { parseModelJsonObject } from '../../datamanager/ModelJsonResponse';
import { JsonMap } from '../../datamanager/DataManagerTypes';
import { AppLogger } from '../AppLogger';
import { RecordingSummary } from './RecordingTypes';
import { recordingSummaryContentTitle } from './RecordingSummaryTitle';
import { uniqueRecordingSummaryItems } from './RecordingSummaryLists';
import { JSON as ArkJSON } from '@kit.ArkTS';

function textField(value: JsonMap, names: string[]): string {
  for (let name of names) {
    let text = value[name];
    if (typeof text === 'string' && text.trim()) { return text.trim(); }
  }
  return '';
}

function listField(value: JsonMap, names: string[]): string[] {
  for (let name of names) {
    let field = value[name];
    if (field === undefined || field === null || field === '') { continue; }
    let items: string[] = [];
    if (typeof field === 'string') {
      if (/^(?:无|暂无|没有|不适用|none|null|n\/a)[。.]?$/i.test(field.trim())) { return []; }
      items = field.split(/\r?\n/);
    } else if (Array.isArray(field)) {
      for (let item of field as Object[]) {
        if (typeof item === 'string') { items.push(item); }
        else if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
          let entry = item as JsonMap; let texts: string[] = [];
          if (Object.keys(entry).some((key: string): boolean =>
            ['text', 'content', 'description'].indexOf(key) < 0)) {
            throw new Error('摘要列表包含额外结构化信息，请重试');
          }
          for (let key of ['text', 'content', 'description']) {
            let text = entry[key];
            if (typeof text === 'string' && text.trim() && texts.indexOf(text.trim()) < 0) { texts.push(text.trim()); }
          }
          if (texts.length !== 1) { throw new Error('摘要列表包含无法识别的内容，请重试'); }
          items.push(texts[0]);
        } else { throw new Error('摘要列表包含无法识别的内容，请重试'); }
      }
    } else { throw new Error('摘要列表格式无效，请重试'); }
    return uniqueRecordingSummaryItems(items);
  }
  return [];
}

// Syntax recovery is shared with other model responses. Domain validation stays
// here: only actual summary text is accepted, never a fabricated completion of
// truncated JSON, concatenated answers, or prose substituted for an overview.
export function parseRecordingSummaryResponse(raw: string, model: string): RecordingSummary {
  try {
    let text = raw;
    // Some small models return one JSON-encoded string containing the object.
    // Decode once only; do not search arbitrary nested responses for an answer.
    try {
      let decoded = ArkJSON.parse(raw.trim()) as string;
      if (typeof decoded === 'string') { text = decoded; }
    } catch (e) { }
    let value = parseModelJsonObject(text, { repairMissingCommas: true });
    // A single named result wrapper has an unambiguous meaning. Do not choose
    // among several generated answers or reinterpret arbitrary nested objects.
    if (!textField(value, ['overview', 'summary', '摘要', '概述'])) {
      for (let name of ['summary', 'result', 'data']) {
        let nested = value[name];
        if (nested !== null && typeof nested === 'object' && !Array.isArray(nested)) {
          value = nested as JsonMap; break;
        }
      }
    }
    let overview = textField(value, ['overview', 'summary', '摘要', '概述']);
    if (!overview) { throw new Error('模型没有返回有效的摘要正文'); }
    let title = recordingSummaryContentTitle(textField(value, ['title', '标题']), overview);
    return { title: title.substring(0, 80), overview: overview.substring(0, 4000),
      keyPoints: listField(value, ['keyPoints', 'key_points', '要点']),
      decisions: listField(value, ['decisions', '结论']),
      actionItems: listField(value, ['actionItems', 'action_items', '待办事项', '待办']),
      openQuestions: listField(value, ['openQuestions', 'open_questions', '待确认事项', '待确认']),
      model: model, generatedAt: new Date().toISOString() };
  } catch (e) {
    const reason = (e as Error).message || String(e);
    AppLogger.warn('RecordingSummary', 'response rejected chars=' + raw.length + ' reason=' + reason);
    // AppLogger records nothing while Debug is off. Bounded pieces keep long
    // responses readable in hilog without logging audio, keys, or voiceprints.
    for (let offset = 0; offset < Math.min(raw.length, 32768); offset += 600) {
      AppLogger.debug('RecordingSummary', 'response[' + offset + ']=' + raw.substring(offset, offset + 600));
    }
    throw new Error('模型摘要格式不完整或无法解析，请重试。');
  }
}
