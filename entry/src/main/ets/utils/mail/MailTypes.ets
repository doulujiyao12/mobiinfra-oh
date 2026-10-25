export interface MailSettings {
  enabled: boolean;
  host: string;
  port: number;
  username: string;
  interested: string;
  ignored: string;
  aiAllowed: boolean;
  maxMessages: number;
}

export interface MailItem {
  id: string;
  uid: number;
  receivedAt: number;
  subject: string;
  from: string;
  body: string;
  truncated: boolean;
  bodyError: string;
  relevant: boolean;
  reason: string;
  summary: string;
  analysisKey: string;
  completed: boolean;
}

export interface MailSnapshot {
  day: string;
  accountKey: string;
  uidValidity: string;
  syncedAt: string;
  items: MailItem[];
  partial: boolean;
  error: string;
  notice: string;
  stale: boolean;
}

export interface MailReadResult {
  uidValidity: string;
  items: MailItem[];
  partial: boolean;
}

export interface MailProvider {
  label: string;
  host: string;
}

export const MAIL_PROVIDERS: MailProvider[] = [
  { label: 'QQ / Foxmail', host: 'imap.qq.com' },
  { label: '163邮箱', host: 'imap.163.com' },
  { label: '126邮箱', host: 'imap.126.com' },
  { label: '腾讯企业邮', host: 'imap.exmail.qq.com' },
  { label: '自定义 IMAP', host: '' }
];

export function defaultMailSettings(): MailSettings {
  return { enabled: false, host: 'imap.qq.com', port: 993, username: '', interested: '', ignored: '',
    aiAllowed: false, maxMessages: 50 };
}

export function emptyMailSnapshot(): MailSnapshot {
  return { day: '', accountKey: '', uidValidity: '', syncedAt: '', items: [], partial: false, error: '', notice: '', stale: false };
}

export function mailDay(now: number = Date.now()): string {
  let date = new Date(now);
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}

export function mailDayBounds(now: number): number[] {
  let date = new Date(now);
  let start = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  let end = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1).getTime();
  return [start, end];
}

export function validateMailSettings(settings: MailSettings): void {
  if (!/^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(settings.host) ||
    settings.host.indexOf('.') < 0 || settings.host.indexOf('..') >= 0) {
    throw new Error('请填写有效的 IMAP 服务器域名');
  }
  if (!Number.isInteger(settings.port) || settings.port < 1 || settings.port > 65535) {
    throw new Error('端口需为1至65535之间的整数（加密收信通常使用993）');
  }
  if (settings.username.length === 0 || settings.username.length > 254 || /[\x00-\x1f\x7f]/.test(settings.username)) {
    throw new Error('请填写完整的邮箱账号');
  }
  if (settings.interested.length > 1000 || settings.ignored.length > 1000) { throw new Error('关注偏好最多各1000字'); }
  if ([20, 50, 100].indexOf(settings.maxMessages) < 0) { throw new Error('请选择20、50或100封的读取上限'); }
}
