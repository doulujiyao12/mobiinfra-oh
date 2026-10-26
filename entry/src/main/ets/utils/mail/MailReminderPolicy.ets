import { HomeRecommendationViewModel } from '../../datamanager/DataManagerTypes';
import { MailItem, MailSnapshot, mailDayBounds, MAIL_RETENTION_DAYS } from './MailTypes';

export const MAIL_REMINDER_OVERVIEW_ID: string = 'mail:overview';

export function visibleMail(items: MailItem[], all: boolean, completed: boolean): MailItem[] {
  return items.filter((item: MailItem): boolean => (all || item.relevant || !item.analysisKey) &&
    (completed || !item.completed)).sort((a: MailItem, b: MailItem): number => b.receivedAt - a.receivedAt);
}

export function todayMail(items: MailItem[], now: number = Date.now()): MailItem[] {
  let bounds = mailDayBounds(now);
  return items.filter((item: MailItem): boolean => item.receivedAt >= bounds[0] && item.receivedAt < bounds[1]);
}

export function mailForDay(items: MailItem[], daysAgo: number, now: number = Date.now()): MailItem[] {
  if (!Number.isInteger(daysAgo) || daysAgo < 0 || daysAgo >= MAIL_RETENTION_DAYS) { return []; }
  let date = new Date(now);
  date.setDate(date.getDate() - daysAgo);
  return todayMail(items, date.getTime());
}

export function mailOverview(snapshot: MailSnapshot): HomeRecommendationViewModel {
  let today = todayMail(snapshot.items);
  let relevant = today.filter((item: MailItem): boolean => item.relevant && !item.completed).length;
  let pending = today.filter((item: MailItem): boolean => !item.analysisKey && !item.completed).length;
  let title = relevant > 0 ? '今天有' + relevant + '封值得关注的邮件' :
    pending > 0 ? '今天有' + pending + '封邮件待判断' : '今日邮件';
  let desc = snapshot.error ? '更新未完成 · 点击查看或重试' : !snapshot.syncedAt ? '点击同步，看看今天有什么新消息' :
    '今日已读取' + today.length + '封' + (snapshot.partial ? '（部分）' : '') + ' · 查看近三天';
  return { id: MAIL_REMINDER_OVERVIEW_ID, domain: 'work', tag: '邮件', title: title, desc: desc,
    meta: '', color: '#6372D8', imageRefs: [], thumbnailUri: '', sourceEventIds: [], detail: '', agentTask: '', completed: false };
}
