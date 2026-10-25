import { HomeRecommendationViewModel } from '../../datamanager/DataManagerTypes';
import { MailItem, MailSnapshot } from './MailTypes';

export const MAIL_REMINDER_OVERVIEW_ID: string = 'mail:overview';

export function visibleMail(items: MailItem[], all: boolean, completed: boolean): MailItem[] {
  return items.filter((item: MailItem): boolean => (all || item.relevant || !item.analysisKey) &&
    (completed || !item.completed)).sort((a: MailItem, b: MailItem): number => b.receivedAt - a.receivedAt);
}

export function mailOverview(snapshot: MailSnapshot): HomeRecommendationViewModel {
  let relevant = snapshot.items.filter((item: MailItem): boolean => item.relevant && !item.completed).length;
  let pending = snapshot.items.filter((item: MailItem): boolean => !item.analysisKey && !item.completed).length;
  let title = relevant > 0 ? '今天有' + relevant + '封值得关注的邮件' :
    pending > 0 ? '今天有' + pending + '封邮件待判断' : '今日邮件';
  let desc = snapshot.error ? '更新未完成 · 点击查看或重试' : !snapshot.syncedAt ? '点击同步，看看今天有什么新消息' :
    '已读取' + snapshot.items.length + '封' + (snapshot.partial ? '（部分）' : '') + ' · 点击查看';
  return { id: MAIL_REMINDER_OVERVIEW_ID, domain: 'work', tag: '邮件', title: title, desc: desc,
    meta: '', color: '#6372D8', imageRefs: [], thumbnailUri: '', sourceEventIds: [], detail: '', agentTask: '', completed: false };
}
