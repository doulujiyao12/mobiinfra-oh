import { DataManagerModelConfig } from '../../datamanager/DataManagerTypes';
import { AppLogger } from '../AppLogger';
import { PrivacyConsent } from '../PrivacyConsent';
import { MailAnalysis, MailDecision, mailAnalysisFailure } from './MailAnalysis';
import { MailCredentialStore } from './MailCredentialStore';
import { MailImapClient } from './MailImapClient';
import { MailStore } from './MailStore';
import { MailItem, MailSnapshot, emptyMailSnapshot, mailDay } from './MailTypes';

export class MailService {
  private static busy: boolean = false;
  static isBusy(): boolean { return MailService.busy; }

  static async refresh(filesDir: string, config: DataManagerModelConfig,
    progress: (message: string) => void = (_message: string): void => {}): Promise<void> {
    if (MailService.busy) { throw new Error('邮箱正在同步，请稍候'); }
    let store = new MailStore(filesDir);
    let settings = store.settings();
    if (!settings.enabled) { return; }
    PrivacyConsent.requireAccepted();
    let startedAt = Date.now();
    let accountKey = store.accountKey(settings);
    let old = store.current(startedAt);
    let saved: MailSnapshot = emptyMailSnapshot();
    MailService.busy = true;
    try {
      progress('读取今天的收件箱…');
      let secret = await MailCredentialStore.load(accountKey);
      let result = await new MailImapClient().readToday(settings, secret, accountKey, old, startedAt);
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
          progress('筛选今日邮件 ' + Math.min(index + 5, pending.length) + '/' + pending.length + '…');
          try {
            if (Date.now() - startedAt > 300000) { throw new Error('邮件筛选超时'); }
            let batch = pending.slice(index, index + 5);
            let decisions = await MailAnalysis.analyze(batch, settings, config);
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
      } else { saved.notice = '未开启AI筛选，今日邮件仅在本机展示。'; }
      let longAnalysis = saved.items.some((item: MailItem): boolean => item.body.length > 12000);
      if (saved.partial || longAnalysis) {
        saved.notice += ' 本次有读取上限、长正文截取或无法解析的邮件，详情中已标明，请结合邮箱核对。';
      }
      // The user may disable/change the mailbox while awaiting a model/network response.
      PrivacyConsent.requireAccepted();
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
      progress(saved.error || '已读取今日' + saved.items.length + '封邮件');
      if (saved.error) { throw new Error(saved.error); }
    } catch (e) {
      let message = (e as Error).message;
      if (PrivacyConsent.isAccepted() && saved.syncedAt.length === 0 && store.settings().enabled && store.accountKey() === accountKey) {
        old.day = mailDay(startedAt); old.accountKey = accountKey;
        old.error = message;
        old.stale = true;
        store.save(old);
      }
      throw new Error(message);
    } finally { MailService.busy = false; }
  }
}
