import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { stringifyJsonCompat } from '../JsonCompat';
import {
  WechatAutoSummaryConversation,
  WechatAutoSummaryMessage,
  WechatAutoSummaryResponse
} from './WechatAutoSummaryTypes';

const WORKFLOWS_DIR: string = 'workflows';
const WECHAT_COLLECTION_DIR: string = 'wechat-collection';
const RUNS_DIR: string = 'runs';
const DAILY_LOG_DIR: string = 'daily-log';
const WECHAT_AUTO_SUMMARY_DAILY_PREFIX: string = 'com.tencent.mm__wechat_auto_summary__';

type WechatNullableText = string | number | boolean | null | undefined;

interface WechatAutoSummaryDailyMetadata {
  task_scene_id: number;
  source_app: string;
  collector: string;
  run_id: string;
  mode: string;
  days: number;
}

interface WechatAutoSummaryDailyMetadataEnvelope {
  workflow_metadata: WechatAutoSummaryDailyMetadata;
  latest_entry_index: number;
}

export function wechatAutoSummaryRunDir(filesDir: string, runId: string): string {
  let storage = new DataManagerStorage();
  return storage.join(filesDir, WORKFLOWS_DIR, WECHAT_COLLECTION_DIR, RUNS_DIR, runId);
}

export function renderWechatAutoSummaryDailyLog(runId: string, mode: string, days: number,
  entries: string[]): string {
  let numberedBlocks: string[] = [];
  for (let i = 0; i < entries.length; i++) {
    let block = wechatDailyLogEntryBlock(entries[i]);
    if (block.length > 0) {
      // DataManager 通过编号条目切分 daily-log；微信联系人块需要保持同一条编号记录内。
      numberedBlocks.push((numberedBlocks.length + 1).toString() + '. ' + block);
    }
  }
  let metadata: WechatAutoSummaryDailyMetadata = {
    task_scene_id: 3,
    source_app: 'wechat',
    collector: 'wechat_auto_summary',
    run_id: runId,
    mode: mode,
    days: days
  };
  let envelope: WechatAutoSummaryDailyMetadataEnvelope = {
    workflow_metadata: metadata,
    latest_entry_index: numberedBlocks.length
  };
  let lines: string[] = [
    '<!-- DAILY_LOG_METADATA',
    stringifyJsonCompat(envelope as Object, 2),
    '-->',
    ''
  ];
  for (let block of numberedBlocks) {
    lines.push(block);
    lines.push('');
  }
  return lines.join('\n');
}

function wechatConversationTitle(conversation: WechatAutoSummaryConversation): string {
  let title = wechatSafeText(conversation.title).trim();
  return title.length > 0 ? title : '未命名会话';
}

function wechatMessageLine(message: WechatAutoSummaryMessage, fallbackSender: string): string {
  let text = wechatSafeText(message.text).trim();
  if (text.length === 0) {
    return '';
  }
  if (message.kind === 'time') {
    return '[' + text + ']';
  }
  let senderText = wechatSafeText(message.sender).trim();
  let sender = senderText.length > 0 ? senderText : fallbackSender;
  return sender + ': ' + text;
}

// UI dump 解析出的服务端 JSON 允许 sender/title/text 为 null；统一规整后再进入 Markdown/daily-log 渲染。
function wechatSafeText(value: WechatNullableText): string {
  if (value === null || value === undefined) {
    return '';
  }
  return String(value);
}

function wechatMessageLines(conversation: WechatAutoSummaryConversation): string[] {
  let title = wechatConversationTitle(conversation);
  let lines: string[] = [];
  for (let message of conversation.messages) {
    let line = wechatMessageLine(message, title);
    if (line.length > 0) {
      lines.push(line);
    }
  }
  return lines;
}

function wechatTimeRangeLine(conversation: WechatAutoSummaryConversation): string {
  if (conversation.time_range === undefined) {
    return '';
  }
  let start = wechatSafeText(conversation.time_range.start).trim();
  let end = wechatSafeText(conversation.time_range.end).trim();
  if (start.length > 0 && end.length > 0) {
    return start + ' 至 ' + end;
  }
  if (start.length > 0) {
    return start;
  }
  return end;
}

function wechatCollectionScopeLine(conversation: WechatAutoSummaryConversation, days: number): string {
  if (conversation.collection_stop_reason !== undefined) {
    return '请求最近 ' + days + ' 天；' + conversation.collection_stop_reason +
      (conversation.coverage_complete === true ? '' : '；仅包含实际读取到的消息，不能保证覆盖整个时间范围');
  }
  let historyMode = wechatSafeText(conversation.history_mode).trim();
  let timeMode = conversation.time_range !== undefined ? wechatSafeText(conversation.time_range.mode).trim() : '';
  if (historyMode === 'visible_page_only' || timeMode === 'visible_page_only') {
    return '请求最近 ' + days.toString() + ' 天，未展开历史';
  }
  return '';
}

function wechatDailyLogEntryBlock(entry: string): string {
  let text = entry.trim();
  if (text.length === 0) {
    return '';
  }
  if (text.indexOf('## ') === 0) {
    return text;
  }
  let rawLines = text.split('\n');
  let lines: string[] = [];
  if (rawLines.length > 0) {
    lines.push('## ' + rawLines[0].trim());
  }
  let inExcerpt = false;
  for (let i = 1; i < rawLines.length; i++) {
    let line = rawLines[i].trim();
    if (line === '完整消息摘录：' || line === '完整消息摘录') {
      lines.push('');
      lines.push('### 完整消息摘录');
      lines.push('');
      inExcerpt = true;
      continue;
    }
    if (line.length === 0) {
      if (lines.length > 0 && lines[lines.length - 1].length !== 0) {
        lines.push('');
      }
      continue;
    }
    if (!inExcerpt && line.indexOf('- ') !== 0) {
      lines.push('- ' + line);
    } else {
      lines.push(line);
    }
  }
  return lines.join('\n').trim();
}

export function wechatAutoSummaryDailyEntries(response: WechatAutoSummaryResponse): string[] {
  if (response.daily_log_entries !== undefined && response.daily_log_entries.length > 0) {
    return response.daily_log_entries;
  }
  if (response.conversations === undefined || response.conversations.length === 0) {
    return [];
  }

  let days = response.days !== undefined ? response.days : 7;
  let entries: string[] = [];
  for (let conversation of response.conversations) {
    let title = wechatConversationTitle(conversation);
    let messageLines = wechatMessageLines(conversation);
    let lines: string[] = [
      '## 微信联系人「' + title + '」最近 ' + days.toString() + ' 天消息采集',
      '',
      '- 联系人：' + title,
      '- 会话标题：' + title
    ];
    let scopeLine = wechatCollectionScopeLine(conversation, days);
    if (scopeLine.length > 0) {
      lines.push('- 采集范围：' + scopeLine);
    }
    let timeRangeLine = wechatTimeRangeLine(conversation);
    if (timeRangeLine.length > 0) {
      lines.push('- 时间范围：' + timeRangeLine);
    }
    lines.push('- 消息数：' + messageLines.length.toString());
    lines.push('');
    lines.push('### 完整消息摘录');
    lines.push('');
    if (messageLines.length > 0) {
      lines = lines.concat(messageLines);
    } else {
      lines.push('（无消息）');
    }
    entries.push(lines.join('\n').trim());
  }
  return entries;
}

export function renderWechatAutoSummaryMarkdown(response: WechatAutoSummaryResponse): string {
  let runId = response.run_id !== undefined ? response.run_id : '';
  let lines: string[] = [
    '# 微信消息采集',
    '',
    '- Run ID: ' + runId,
    '- Mode: ' + (response.mode !== undefined ? response.mode : ''),
    '- Days: ' + (response.days !== undefined ? response.days.toString() : ''),
    '- Contacts: ' + (response.contacts_collected !== undefined ? response.contacts_collected.toString() : ''),
    ''
  ];
  if (response.conversations !== undefined) {
    for (let conversation of response.conversations) {
      let title = wechatConversationTitle(conversation);
      lines.push('## ' + title);
      lines.push('');
      let messageLines = wechatMessageLines(conversation);
      if (messageLines.length === 0) {
        lines.push('（无消息）');
      } else {
        for (let line of messageLines) {
          lines.push('- ' + line);
        }
      }
      lines.push('');
    }
  }
  return lines.join('\n').trim() + '\n';
}

export class WechatAutoSummaryStorage {
  private filesDir: string;
  private storage: DataManagerStorage;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
    this.storage = new DataManagerStorage();
  }

  // 原始采集产物按 runId 聚合，便于后续回看同一次微信采集的 dump、截图索引和服务端摘要。
  writeRawArtifact(runId: string, name: string, content: string): string {
    let path = this.storage.join(wechatAutoSummaryRunDir(this.filesDir, runId), name);
    this.storage.writeTextAtomic(path, content);
    return path;
  }

  // daily-log 使用 DataManager 既有目录结构，写入后可被后续归档和索引流程统一消费。
  writeDailyLog(runId: string, mode: string, days: number, dateKey: string, entries: string[]): string {
    let fileName = WECHAT_AUTO_SUMMARY_DAILY_PREFIX + runId + '.md';
    let path = this.storage.join(this.filesDir, WORKFLOWS_DIR, DAILY_LOG_DIR, dateKey, fileName);
    this.storage.writeTextAtomic(path, renderWechatAutoSummaryDailyLog(runId, mode, days, entries));
    return path;
  }
}
