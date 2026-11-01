import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../AppLogger';
import { AppRequests } from '../AppRequests';
import { MAIL_CREDENTIAL_MISSING_MESSAGE } from './MailCredentialStore';
import { DataManagerProgress, DataManagerProgressCallback } from '../../datamanager/DataManagerTypes';
import { MailSettings, MailItem, MailSnapshot, MailReadResult, mailDay, mailDayBounds, validateMailSettings, MAIL_RETENTION_DAYS } from './MailTypes';
import { ImapFrames, imapFetch, imapField, imapBody, mailBodyPart, mailQuoted, mailDecode, mailHeader,
  mailPlainHtml, mailInternalDate, mailSearchDate } from './MailImapCodec';

const BODY_LIMIT: number = 65536;

export class MailImapClient {
  private connection: socket.TLSSocket = socket.constructTLSSocketInstance();
  private frames: ImapFrames = new ImapFrames();
  private queue: string[] = [];
  private failure: string = '';
  private wake: (() => void) | null = null;
  private sequence: number = 0;
  private deadline: number = Date.now() + 180000;
  private closed: boolean = false;
  private unregister: (() => void) | null = null;

  private fail(message: string): void {
    this.failure = message;
    if (this.wake !== null) { this.wake(); }
  }
  private async next(): Promise<string> {
    while (this.queue.length === 0) {
      if (this.failure) { throw new Error(this.failure); }
      let remaining = Math.min(20000, this.deadline - Date.now());
      if (remaining <= 0) { throw new Error('邮箱读取超时，请缩小读取上限后重试'); }
      await new Promise<void>((resolve): void => {
        let timer = setTimeout((): void => { this.fail('邮箱服务器响应超时，请检查网络和收信配置'); }, remaining);
        this.wake = (): void => { clearTimeout(timer); this.wake = null; resolve(); };
      });
    }
    return this.queue.shift() || '';
  }
  private async command(command: string, stage: string): Promise<string[]> {
    if (this.failure || Date.now() >= this.deadline) { throw new Error(this.failure || '邮箱读取超时'); }
    let tag = 'M' + (++this.sequence);
    let sendTimer: number = -1;
    try {
      // Never log the command: LOGIN includes the account authorization code.
      await new Promise<void>((resolve, reject): void => {
        sendTimer = setTimeout((): void => {
          this.fail('邮箱发送请求超时'); this.close(); reject(new Error('邮箱发送请求超时'));
        }, Math.min(20000, this.deadline - Date.now()));
        this.connection.send(new util.TextEncoder().encodeInto(tag + ' ' + command + '\r\n').buffer as ArrayBuffer)
          .then((): void => { resolve(); }).catch((): void => { reject(new Error('邮箱连接已断开')); });
      });
    } catch (e) { throw new Error('邮箱连接已断开，请重试'); }
    finally { clearTimeout(sendTimer); }
    let result: string[] = [];
    let bytes = 0;
    while (true) {
      let frame = await this.next();
      bytes += frame.length;
      if (bytes > 2 * 1024 * 1024) { throw new Error('邮件响应过大，请缩小读取上限'); }
      if (frame.startsWith(tag + ' ')) {
        if (!frame.startsWith(tag + ' OK')) {
          if (stage === '认证') { AppLogger.warn('Mail', 'MAIL_IMAP_AUTH status=rejected'); }
          throw new Error(stage === '认证' ? 'MAIL_AUTH_REJECTED: 邮箱认证失败，服务器拒绝了当前授权码；请核对授权码是否有效、是否开启IMAP。Outlook等OAuth邮箱暂不支持普通密码登录' :
            stage + '失败：服务器拒绝请求，请确认已开启IMAP服务');
        }
        return result;
      }
      if (frame.startsWith('* BYE')) { throw new Error('邮箱服务器关闭了连接，请稍后重试'); }
      result.push(frame);
    }
  }
  private async open(settings: MailSettings): Promise<void> {
    this.unregister = AppRequests.registerExternalRequest((): void => { this.close(); });
    let timer = setTimeout((): void => { this.fail('邮箱TLS连接超时'); this.close(); }, 20000);
    try {
      // NetworkKit initializes the native TLS socket on bind. Subscribe only
      // after it succeeds; the OS chooses the interface and an ephemeral port.
      await this.connection.bind({ address: '0.0.0.0', family: 1, port: 0 });
      if (this.closed) { throw new Error('邮箱连接已取消'); }
      this.connection.on('message', (message: socket.SocketMessageInfo): void => {
        try {
          this.queue = this.queue.concat(this.frames.push(new Uint8Array(message.message)));
          if (this.queue.length > 2000) { this.fail('邮件响应数量超过上限'); }
        } catch (e) { this.fail((e as Error).message); }
        if (this.wake !== null) { this.wake(); }
      });
      this.connection.on('close', (): void => { this.fail('邮箱连接已关闭，请重试'); });
      this.connection.on('error', (): void => { this.fail('邮箱网络或TLS连接异常，请检查网络、服务器域名及证书'); });
      await this.connection.connect({ address: { address: settings.host, port: settings.port, family: 1 },
        secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
        skipRemoteValidation: false, timeout: 20000 });
      if (this.closed || this.failure) { throw new Error(this.failure || '邮箱连接已取消'); }
      let greeting = await this.next();
      if (!greeting.startsWith('* OK')) { throw new Error('目标不是可用的IMAP加密收信服务'); }
    } catch (e) { throw new Error('邮箱加密连接失败，请检查网络、域名和TLS端口（通常993），不支持明文143端口'); }
    finally { clearTimeout(timer); }
  }
  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    if (this.unregister !== null) { this.unregister(); this.unregister = null; }
    this.fail('邮箱连接已结束');
    this.connection.close().catch((): void => {});
  }

  async readToday(settings: MailSettings, secret: string, accountKey: string, cached: MailSnapshot,
    now: number = Date.now(), days: number = 1, progress?: DataManagerProgressCallback): Promise<MailReadResult> {
    if (!Number.isInteger(days) || days < 1 || days > MAIL_RETENTION_DAYS) { throw new Error('邮件读取范围无效'); }
    let bounds = mailDayBounds(now, days);
    AppLogger.info('Mail', 'read begin days=' + days + ' limit=' + settings.maxMessages);
    let report = (stage: string, message: string, current: number, total: number, percent: number): void => {
      if (progress) {
        let value: DataManagerProgress = { stage: stage, message: message, current: current, total: total, percent: percent };
        progress(value);
      }
    };
    try {
      validateMailSettings(settings);
      if (!secret || /[\x00-\x1f\x7f]/.test(secret)) { throw new Error(MAIL_CREDENTIAL_MISSING_MESSAGE); }
      report('连接邮箱', '正在建立加密连接，请稍候', 0, 0, 2);
      await this.open(settings);
      await this.command('LOGIN ' + mailQuoted(settings.username) + ' ' + mailQuoted(secret), '认证');
      AppLogger.info('Mail', 'MAIL_IMAP_AUTH status=accepted');
      report('查询邮件', '连接成功，正在查询近 ' + days + ' 天的收件箱', 0, 0, 10);
      let capabilities = (await this.command('CAPABILITY', '查询能力')).join(' ');
      if (/(?:^|\s)ID(?:\s|$)/i.test(capabilities)) {
        // NetEase requires a client ID. It contains no personal/device identifiers.
        await this.command('ID ("name" "ClawMate" "version" "1.0")', '声明邮件客户端');
      }
      let selected = await this.command('EXAMINE "INBOX"', '只读打开收件箱');
      let validity = /\[UIDVALIDITY (\d+)\]/.exec(selected.join(' '));
      if (validity === null) { throw new Error('邮箱未提供UIDVALIDITY，无法安全复用邮件缓存'); }
      let uidValidity = validity[1];
      // IMAP dates have no timezone; widen search then filter INTERNALDATE using local midnight.
      let search = await this.command('UID SEARCH SINCE ' + mailSearchDate(now, -days) + ' BEFORE ' + mailSearchDate(now, 2), '查询近期邮件');
      let all: number[] = [];
      let seenUids: Set<number> = new Set();
      let searchSeen = false;
      search.forEach((line: string): void => {
        if (line.startsWith('* SEARCH')) {
          searchSeen = true;
          line.substring(8).trim().split(/\s+/).forEach((value: string): void => {
            let uid = Number(value);
            if (/^\d+$/.test(value) && Number.isInteger(uid) && uid > 0 && uid <= 4294967295 && !seenUids.has(uid)) {
              all.push(uid); seenUids.add(uid);
            }
          });
        }
      });
      if (!searchSeen) { throw new Error('邮箱未返回支持的邮件搜索结果，未覆盖已有缓存'); }
      all = all.sort((a: number, b: number): number => b - a);
      let partial = all.length > 500;
      let candidates = all.slice(0, 500);
      let items: MailItem[] = [];
      let metadata: string[] = [];
      let fetched: number[] = [];
      for (let offset = 0; offset < candidates.length; offset += 25) {
        let uids = candidates.slice(offset, offset + 25);
        let responses = await this.command('UID FETCH ' + uids.join(',') +
          ' (UID INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])', '读取邮件标题');
        metadata = metadata.concat(responses);
        let completed = Math.min(offset + 25, candidates.length);
        report('读取邮件标题', '已检查 ' + completed + '/' + candidates.length + ' 封邮件标题',
          completed, candidates.length, 12 + 18 * completed / candidates.length);
      }
      metadata = metadata.filter((response: string): boolean => imapFetch(response) !== null);
      metadata.sort((a: string, b: string): number => {
        let left = imapFetch(a); let right = imapFetch(b);
        return (right === null ? 0 : mailInternalDate(imapField(right, 'INTERNALDATE').text)) -
          (left === null ? 0 : mailInternalDate(imapField(left, 'INTERNALDATE').text));
      });
      let checked = 0;
      for (let response of metadata) {
          report('读取邮件正文', '正在检查第 ' + (checked + 1) + '/' + metadata.length + ' 封邮件，已读取 ' + items.length + ' 封',
            checked, metadata.length, 30 + 30 * checked / Math.max(1, metadata.length));
          checked++;
          let fetch = imapFetch(response);
          if (fetch === null) { continue; }
          let uid = Number(imapField(fetch, 'UID').text);
          if (candidates.indexOf(uid) < 0) { continue; }
          fetched.push(uid);
          if (items.some((item: MailItem): boolean => item.uid === uid)) { continue; }
          let received = mailInternalDate(imapField(fetch, 'INTERNALDATE').text);
          if (!Number.isFinite(received)) { partial = true; continue; }
          if (received < bounds[0] || received >= bounds[1]) { continue; }
          if (items.filter((item: MailItem): boolean => mailDay(item.receivedAt) === mailDay(received)).length >= settings.maxMessages) {
            partial = true; continue;
          }
          let id = 'mail:' + accountKey + ':' + uidValidity + ':' + uid;
          let old = cached.accountKey === accountKey && cached.uidValidity === uidValidity ?
            cached.items.find((value: MailItem): boolean => value.id === id && !value.bodyError) : undefined;
          if (old !== undefined) { if (old.truncated) { partial = true; } items.push(old); continue; }
          let header = imapBody(fetch);
          let item: MailItem = { id: id, uid: uid, receivedAt: received, subject: '(无主题)', from: '', body: '',
            truncated: false, bodyError: '', relevant: false, reason: '', summary: '', analysisKey: '', completed: false };
          try {
            item.subject = mailHeader(header, 'Subject') || '(无主题)';
            item.from = mailHeader(header, 'From');
            let part = mailBodyPart(imapField(fetch, 'BODYSTRUCTURE'));
            if (part === null) { item.bodyError = '没有可读取的文本正文（可能仅包含附件或加密内容）'; }
            else {
              let bodyResponse = await this.command('UID FETCH ' + uid + ' (UID BODY.PEEK[' + part.section + ']<0.' + BODY_LIMIT + '>)', '读取邮件正文');
              let found = false;
              for (let line of bodyResponse) {
                let bodyFetch = imapFetch(line);
                if (bodyFetch !== null && Number(imapField(bodyFetch, 'UID').text) === uid) {
                  let text = mailDecode(imapBody(bodyFetch), part.encoding, part.charset);
                  item.body = (part.html ? mailPlainHtml(text) : text).replace(/\x00/g, '').slice(0, 32000);
                  item.truncated = part.size > BODY_LIMIT || text.length > 32000;
                  found = true; break;
                }
              }
              if (!found) { item.bodyError = '读取期间邮件已移动或被删除，正文未获取'; }
            }
          } catch (e) {
            // Protocol/network failures abort to preserve a coherent previous snapshot.
            if (this.failure || Date.now() >= this.deadline) { throw new Error('邮件读取中断，请重试'); }
            item.bodyError = '正文读取失败或字符集不支持，请在邮箱中查看原信';
          }
          if (item.bodyError || item.truncated) { partial = true; }
          items.push(item);
      }
      if (candidates.some((uid: number): boolean => fetched.indexOf(uid) < 0)) { partial = true; }
      items.sort((a: MailItem, b: MailItem): number => b.receivedAt - a.receivedAt);
      report('邮件读取完成', '已读取 ' + items.length + ' 封近 ' + days + ' 天邮件', items.length, items.length, 60);
      AppLogger.info('Mail', 'read finished count=' + items.length + ' partial=' + partial);
      return { uidValidity: uidValidity, items: items, partial: partial };
    } finally { this.close(); }
  }
}
