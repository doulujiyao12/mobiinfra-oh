import { DataManagerModelConfig, DataManagerProgress, DataManagerProgressCallback } from '../../datamanager/DataManagerTypes';
import { AppLogger } from '../AppLogger';
import { MailAnalysis, MailDecision, MailFailureInfo, mailAnalysisFailure } from './MailAnalysis';
import { MailCredentialStore, MAIL_CREDENTIAL_MISSING_MESSAGE } from './MailCredentialStore';
import { MailImapClient } from './MailImapClient';
import { MailStore } from './MailStore';
import { MailItem, MailSettings, MailSnapshot, emptyMailSnapshot, mailDay, MAIL_RETENTION_DAYS, validateMailSettings } from './MailTypes';

export class MailService {
  private static busy: boolean = false;
  static isBusy(): boolean { return MailService.busy; }

  private static checkpoint(store: MailStore, saved: MailSnapshot, settings: MailSettings): void {
    // Recheck after every awaited request, before writing or scheduling more work.
    // Storage/settings failures must not be mistaken for malformed model output.
    if (!store.settings().enabled || JSON.stringify(store.settings()) !== JSON.stringify(settings) ||
      store.accountKey() !== saved.accountKey || mailDay() !== saved.day) {
      throw new Error('邮箱设置或日期已变化，请重新同步');
    }
    let latest = store.current();
    saved.items.forEach((item: MailItem): void => {
      let current = latest.items.find((value: MailItem): boolean => value.id === item.id);
      if (current !== undefined) { item.completed = current.completed; }
    });
    store.save(saved);
  }

  private static incompleteMessage(saved: MailSnapshot, failure: MailFailureInfo | null): string {
    let completed = saved.items.filter((item: MailItem): boolean => item.analysisKey.length > 0).length;
    if (completed === saved.items.length) { return ''; }
    return '邮件已读取，但AI筛选未完成：' + (failure === null ? '部分邮件尚未筛选。' : failure.message) +
      ' 已完成' + completed + '/' + saved.items.length + '封，未筛选邮件仍可查看并重试。';
  }

  private static canRetryOutput(failure: MailFailureInfo): boolean {
    return ['empty_output', 'invalid_json', 'invalid_count', 'invalid_decision', 'output_truncated',
      'content_filtered', 'response_format'].indexOf(failure.code) >= 0;
  }

  private static async analyzePending(store: MailStore, saved: MailSnapshot, pending: MailItem[],
    settings: MailSettings, config: DataManagerModelConfig, model: string, startedAt: number,
    report: DataManagerProgressCallback): Promise<void> {
    let retry: MailItem[] = [];
    let lastFailure: MailFailureInfo | null = null;
    const deadline = startedAt + 300000;
    let processed = 0;
    let retryProcessed = 0;
    let stopped = false;
    saved.error = MailService.incompleteMessage(saved, null);
    MailService.checkpoint(store, saved, settings);
    let analyze = async (batch: MailItem[], retrying: boolean): Promise<boolean> => {
      if (Date.now() >= deadline) {
        lastFailure = { code: 'timeout', message: '邮件筛选超时，已完成结果已保存。' };
        return false;
      }
      const value: DataManagerProgress = { stage: retrying ? '重试未完成邮件' : 'AI筛选邮件',
        message: retrying ? '正在单独重试未完成邮件 ' + (retryProcessed + 1) + '/' + retry.length :
          '已检查 ' + processed + '/' + pending.length + ' 封，正在等待本批AI结果',
        current: retrying ? retryProcessed : processed, total: retrying ? retry.length : pending.length,
        percent: retrying ? 90 + 5 * retryProcessed / retry.length : 60 + 30 * processed / pending.length };
      report(value);
      let decisions: MailDecision[] = [];
      let failure: MailFailureInfo | null = null;
      let batchStarted = Date.now();
      try {
        decisions = await MailAnalysis.analyze(batch, settings, config, Math.max(1, Math.min(90000, deadline - Date.now())));
      } catch (e) { failure = mailAnalysisFailure(e as Error); }
      decisions.forEach((decision: MailDecision): void => {
        let item = batch.find((value: MailItem): boolean => value.id === decision.id);
        if (item === undefined) { return; }
        item.relevant = item.bodyError.length > 0 || decision.relevant;
        item.summary = decision.summary; item.reason = decision.reason;
        item.analysisKey = store.analysisKey(item, settings, model); item.analysisError = '';
      });
      let missing = batch.filter((item: MailItem): boolean => item.analysisKey.length === 0);
      if (missing.length > 0) {
        if (failure === null) { failure = { code: 'invalid_count', message: '模型未完整返回本批邮件的筛选结果。' }; }
        lastFailure = failure;
        const failureMessage = failure.message;
        missing.forEach((item: MailItem): void => { item.analysisError = failureMessage; });
        if (!retrying && MailService.canRetryOutput(failure)) {
          missing.forEach((item: MailItem): void => { retry.push(item); });
        }
        AppLogger.warn('Mail', 'MAIL_ANALYSIS_INCOMPLETE code=' + failure.code + ' count=' + batch.length +
          ' accepted=' + decisions.length + ' unresolved=' + missing.length + ' retry=' + retrying);
      }
      AppLogger.info('Mail', 'MAIL_ANALYSIS_BATCH count=' + batch.length + ' accepted=' + decisions.length +
        ' retry=' + retrying + ' elapsedMs=' + (Date.now() - batchStarted));
      saved.error = MailService.incompleteMessage(saved, lastFailure);
      MailService.checkpoint(store, saved, settings);
      return failure === null || MailService.canRetryOutput(failure);
    };
    // Finish the first pass before retrying: a bad early email cannot consume
    // the whole request budget before later batches have even been attempted.
    for (let index = 0; index < pending.length; index += 5) {
      if (!await analyze(pending.slice(index, index + 5), false)) { stopped = true; break; }
      processed = Math.min(pending.length, index + 5);
    }
    if (!stopped) {
      for (const item of retry) {
        if (!await analyze([item], true)) { break; }
        retryProcessed++;
      }
    }
    pending.forEach((item: MailItem): void => {
      if (!item.analysisKey && !item.analysisError && lastFailure !== null) { item.analysisError = lastFailure.message; }
    });
    saved.error = MailService.incompleteMessage(saved, lastFailure);
    MailService.checkpoint(store, saved, settings);
  }

  static async canAutoRefresh(filesDir: string): Promise<boolean> {
    let store = new MailStore(filesDir);
    let settings = store.settings();
    if (!settings.enabled) { return false; }
    try {
      validateMailSettings(settings);
      return (await MailCredentialStore.load(store.accountKey(settings))).length > 0;
    } catch (e) { return false; }
  }

  static async refresh(filesDir: string, config: DataManagerModelConfig,
    progress: (message: string) => void = (_message: string): void => {}, workProgress?: DataManagerProgressCallback): Promise<void> {
    if (MailService.busy) { throw new Error('邮箱正在同步，请稍候'); }
    let store = new MailStore(filesDir);
    let settings = store.settings();
    if (!settings.enabled) { return; }
    let startedAt = Date.now();
    let accountKey = store.accountKey(settings);
    let old = store.current(startedAt);
    let saved: MailSnapshot = emptyMailSnapshot();
    MailService.busy = true;
    let report: DataManagerProgressCallback = (value: DataManagerProgress): void => {
      progress(value.message);
      if (workProgress) { workProgress(value); }
    };
    try {
      report({ stage: '连接邮箱', message: '正在连接邮箱，读取近三天邮件', current: 0, total: 0, percent: 2 });
      let secret = await MailCredentialStore.load(accountKey);
      if (!secret) { throw new Error(MAIL_CREDENTIAL_MISSING_MESSAGE); }
      let result = await new MailImapClient().readToday(settings, secret, accountKey, old, startedAt, MAIL_RETENTION_DAYS, report);
      AppLogger.info('Mail', 'MAIL_READ_DONE count=' + result.items.length + ' elapsedMs=' + (Date.now() - startedAt));
      saved = { day: mailDay(startedAt), accountKey: accountKey, uidValidity: result.uidValidity,
        syncedAt: new Date().toISOString(), items: result.items, partial: result.partial, error: '', notice: '', stale: false };
      let model = config.baseUrl + ':' + (config.model || '');
      // Changing guidance or model invalidates decisions; unchanged UIDs do not pay for another analysis.
      let pending = saved.items.filter((item: MailItem): boolean => item.analysisKey !== store.analysisKey(item, settings, model));
      pending.forEach((item: MailItem): void => {
        item.analysisKey = ''; item.analysisError = ''; item.relevant = false; item.summary = ''; item.reason = '';
      });
      if (settings.aiAllowed) {
        await MailService.analyzePending(store, saved, pending, settings, config, model, startedAt, report);
      } else { saved.notice = '未开启AI筛选，近三天邮件仅在本机展示。'; }
      let longAnalysis = saved.items.some((item: MailItem): boolean => item.body.length > 12000);
      if (saved.partial || longAnalysis) {
        saved.notice += ' 本次有读取上限、长正文截取或无法解析的邮件，详情中已标明，请结合邮箱核对。';
      }
      MailService.checkpoint(store, saved, settings);
      progress(saved.error || '已读取近三天' + saved.items.length + '封邮件');
      if (saved.error) { throw new Error(saved.error); }
      let completed: DataManagerProgress = { stage: settings.aiAllowed ? '邮件读取与分析完成' : '邮件读取完成',
        message: '已保存近三天邮件结果',
        current: saved.items.length, total: saved.items.length, percent: 100 };
      report(completed);
    } catch (e) {
      let message = (e as Error).message;
      if (saved.syncedAt.length === 0 && store.settings().enabled && store.accountKey() === accountKey) {
        old.day = mailDay(startedAt); old.accountKey = accountKey;
        old.error = message;
        old.stale = true;
        store.save(old);
      }
      throw new Error(message);
    } finally { MailService.busy = false; }
  }
}
