import { DataManagerModelConfig, DataManagerProgress, DataManagerProgressCallback } from '../../datamanager/DataManagerTypes';
import { AppLogger } from '../AppLogger';
import { MailAnalysis, MailDecision, mailAnalysisFailure } from './MailAnalysis';
import { MailCredentialStore, MAIL_CREDENTIAL_MISSING_MESSAGE } from './MailCredentialStore';
import { MailImapClient } from './MailImapClient';
import { MailStore } from './MailStore';
import { MailItem, MailSnapshot, emptyMailSnapshot, mailDay, MAIL_RETENTION_DAYS, validateMailSettings } from './MailTypes';

export class MailService {
  private static busy: boolean = false;
  static isBusy(): boolean { return MailService.busy; }

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
        item.analysisKey = ''; item.relevant = false; item.summary = ''; item.reason = '';
      });
      if (settings.aiAllowed) {
        for (let index = 0; index < pending.length; index += 5) {
          let value: DataManagerProgress = { stage: 'AI筛选邮件',
            message: '已筛选 ' + index + '/' + pending.length + ' 封，正在等待本批AI结果',
            current: index, total: pending.length, percent: 60 + 35 * index / pending.length };
          report(value);
          try {
            if (Date.now() - startedAt > 300000) { throw new Error('邮件筛选超时'); }
            let batch = pending.slice(index, index + 5);
            let batchStarted = Date.now();
            let decisions = await MailAnalysis.analyze(batch, settings, config);
            AppLogger.info('Mail', 'MAIL_ANALYSIS_BATCH count=' + batch.length + ' elapsedMs=' + (Date.now() - batchStarted));
            decisions.forEach((decision: MailDecision): void => {
              let item = batch.find((value: MailItem): boolean => value.id === decision.id);
              if (item === undefined) { return; }
              item.relevant = item.bodyError.length > 0 || decision.relevant;
              // The parser already bounds these fields. Keep the full validated
              // result so the mail detail can display the complete AI summary.
              item.summary = decision.summary;
              item.reason = decision.reason;
              item.analysisKey = store.analysisKey(item, settings, model);
            });
          } catch (e) {
            let failure = mailAnalysisFailure(e as Error);
            let completed = saved.items.filter((item: MailItem): boolean => item.analysisKey.length > 0).length;
            saved.error = '邮件已读取，但AI筛选未完成：' + failure.message + ' 已完成' + completed + '/' +
              saved.items.length + '封，未筛选邮件仍可查看并重试。';
            AppLogger.warn('Mail', 'analysis failed code=' + failure.code + ' batch_offset=' + index +
              ' completed=' + completed + ' total=' + saved.items.length + '; content and response omitted');
            break;
          }
        }
      } else { saved.notice = '未开启AI筛选，近三天邮件仅在本机展示。'; }
      let longAnalysis = saved.items.some((item: MailItem): boolean => item.body.length > 12000);
      if (saved.partial || longAnalysis) {
        saved.notice += ' 本次有读取上限、长正文截取或无法解析的邮件，详情中已标明，请结合邮箱核对。';
      }
      // The user may disable/change the mailbox while awaiting a model/network response.
      if (!store.settings().enabled || JSON.stringify(store.settings()) !== JSON.stringify(settings) ||
        store.accountKey() !== accountKey || mailDay() !== saved.day) {
        throw new Error('邮箱设置或日期已变化，请重新同步');
      }
      let latest = store.current();
      saved.items.forEach((item: MailItem): void => {
        let current = latest.items.find((value: MailItem): boolean => value.id === item.id);
        if (current !== undefined) { item.completed = current.completed; }
      });
      store.save(saved);
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
