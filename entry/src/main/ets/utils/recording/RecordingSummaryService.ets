import { JSON as ArkJSON } from '@kit.ArkTS';
import { CloudModelClient, cloudPlannerApiKey } from '../CloudModelClient';
import { readChatCloudConfig } from '../ChatCloudConfig';
import { RecordingRecord, RecordingSummary, applyRecordingSummary } from './RecordingTypes';
import { LocalTextInference, LocalTextSession } from '../LocalTextInference';
import { localRecordingChunks, localSummarySnapshot, prepareLocalSummary, RECORDING_LOCAL_SUMMARY_SYSTEM } from './RecordingLocalSummary';
import { RECORDING_SUMMARY_SYSTEM, recordingTranscript, parseRecordingSummary, summaryTextChunks } from './RecordingSummaryText';
import { limitLocalRecordingSummaryItems } from './RecordingSummaryLists';

export interface RecordingSummaryOptions {
  source?: string;
  restart?: boolean;
  onCheckpoint?: (completed: number, total: number) => void;
}

export class RecordingSummaryService {
  private client: CloudModelClient = new CloudModelClient();
  private epoch: number = 0;
  private local: LocalTextSession | null = null;
  cancel(): void { this.epoch++; this.client.cancelActiveRequests(); this.local?.cancel(); }
  async generate(record: RecordingRecord, progress: (text: string) => void,
    options: RecordingSummaryOptions = {}): Promise<RecordingSummary> {
    let epoch = ++this.epoch;
    if (options.source === 'local') { return this.generateLocal(record, progress, options, epoch); }
    let config = readChatCloudConfig();
    if (!config.plannerBaseUrl.trim()) { throw new Error('请先在「我的 → 模型配置」中配置 Planner'); }
    let transcript = recordingTranscript(record);
    if (!transcript.trim()) { throw new Error('转写中没有文字，暂时无法生成摘要'); }
    let parts = summaryTextChunks(transcript); let round = 0;
    while (true) {
      let summaries: RecordingSummary[] = [];
      for (let index = 0; index < parts.length; index++) {
        if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
        progress((round === 0 ? '整理录音' : '合并摘要') + ' · ' + (index + 1) + ' / ' + parts.length);
        let response = await this.client.chatCompletion({ baseUrl: config.plannerBaseUrl,
          apiKey: cloudPlannerApiKey(config), model: config.plannerModel,
          messages: [{ role: 'system', content: RECORDING_SUMMARY_SYSTEM },
            { role: 'user', content: (round === 0 ? '录音转写资料：\n' : '按时间顺序的阶段摘要资料：\n') + parts[index] }],
          temperature: 0.2, maxTokens: 2200, readTimeout: 120000, logResponseContent: false,
          chatTemplateKwargs: { enable_thinking: false } });
        if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
        if (response.finishReason === 'length') { throw new Error('摘要输出超长，请缩短片段后重试'); }
        summaries.push(parseRecordingSummary(response.content, config.plannerModel));
      }
      if (summaries.length === 1) { summaries[0].source = 'cloud'; return summaries[0]; }
      // Group at most three bounded summaries per request so each round shrinks.
      parts = [];
      for (let index = 0; index < summaries.length; index += 3) {
        parts.push(ArkJSON.stringify(summaries.slice(index, index + 3)));
      }
      round++;
    }
  }
  private async generateLocal(record: RecordingRecord, progress: (text: string) => void,
    options: RecordingSummaryOptions, epoch: number): Promise<RecordingSummary> {
    if (!recordingTranscript(record).trim()) { throw new Error('转写中没有文字，暂时无法生成摘要'); }
    progress('正在准备本地摘要模型');
    let session = await LocalTextInference.acquire(); this.local = session;
    try {
      if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
      let draft = prepareLocalSummary(record, session.model.identity, options.restart === true);
      let parts = localRecordingChunks(record, draft.input); record.localSummaryDraft = draft;
      options.onCheckpoint?.(draft.sections.length, parts.length);
      for (let index = draft.sections.length; index < parts.length; index++) {
        if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
        let label = '本地摘要 ' + (index + 1) + '/' + parts.length; let chars = 0; let lastUpdate = 0;
        let pending = draft.pendingResponse;
        let summary: RecordingSummary | undefined = undefined;
        if (pending?.index === index && !pending.truncated) {
          try { summary = parseRecordingSummary(pending.content, session.model.name); } catch (e) { }
        }
        for (let attempt = 0; summary === undefined && attempt < 2; attempt++) {
          if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
          let compact = attempt > 0 || pending?.index === index;
          let retry = compact ? '\n这次必须更简短：概述最多80字，每个列表最多2条，每条最多24字。只输出完整JSON，所有列表元素都用字符串。' : '';
          chars = 0; lastUpdate = 0;
          progress(label + (compact ? ' · 正在重试简短格式' : ' · 等待输出'));
          const content = await session.generate(RECORDING_LOCAL_SUMMARY_SYSTEM + retry +
            '\n\n录音转写资料：\n' + parts[index].text, (token: string): void => {
              chars += token.length;
              if (epoch === this.epoch && Date.now() - lastUpdate > 300) {
                lastUpdate = Date.now(); progress(label + ' · 已生成 ' + chars + ' 字');
              }
            });
          if (epoch !== this.epoch) { throw new Error('摘要已停止'); }
          try { summary = parseRecordingSummary(content, session.model.name); }
          catch (e) {
            draft.pendingResponse = { index: index, content: content.substring(0, 32768), truncated: content.length > 32768 };
            options.onCheckpoint?.(draft.sections.length, parts.length);
            if (attempt === 1) { throw new Error((e as Error).message); }
          }
        }
        if (summary === undefined) { throw new Error('本段摘要尚未生成，请重试'); }
        limitLocalRecordingSummaryItems(summary);
        draft.pendingResponse = undefined;
        draft.sections.push({ index: index, start: parts[index].start, end: parts[index].end, summary: summary });
        applyRecordingSummary(record, localSummarySnapshot(draft, session.model.name));
        options.onCheckpoint?.(draft.sections.length, parts.length);
        progress('已保存本地摘要 ' + draft.sections.length + '/' + parts.length);
      }
      return localSummarySnapshot(draft, session.model.name);
    } finally { session.close(); if (this.local === session) { this.local = null; } }
  }
}
