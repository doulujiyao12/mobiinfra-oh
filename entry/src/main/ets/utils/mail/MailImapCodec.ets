import { util } from '@kit.ArkTS';

// One code unit per byte: IMAP literal lengths are octets, not UTF-8 characters.
export function mailBinary(bytes: Uint8Array): string {
  let text = '';
  for (let index = 0; index < bytes.length; index++) { text += String.fromCharCode(bytes[index]); }
  return text;
}
export function mailBytes(text: string): Uint8Array {
  let bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index++) { bytes[index] = text.charCodeAt(index) & 255; }
  return bytes;
}

export class ImapFrames {
  private buffer: string = '';
  push(bytes: Uint8Array): string[] {
    this.buffer += mailBinary(bytes);
    if (this.buffer.length > 2 * 1024 * 1024) { throw new Error('邮件服务器响应超过安全上限'); }
    let frames: string[] = [];
    let cursor = 0;
    while (true) {
      let end = this.buffer.indexOf('\r\n', cursor);
      if (end < 0) { break; }
      let line = this.buffer.substring(cursor, end);
      let literal = /\{(\d+)\+?\}$/.exec(line);
      if (literal !== null) {
        let count = Number(literal[1]);
        if (count > 1024 * 1024) { throw new Error('邮件单段内容超过安全上限'); }
        if (this.buffer.length < end + 2 + count) { break; }
        cursor = end + 2 + count;
        continue;
      }
      frames.push(this.buffer.substring(0, end));
      this.buffer = this.buffer.substring(end + 2);
      cursor = 0;
    }
    return frames;
  }
}

export class ImapValue {
  text: string = '';
  list: boolean = false;
  children: ImapValue[] = [];
}

class ImapParser {
  private position: number = 0;
  private source: string;
  constructor(source: string) { this.source = source; }
  read(depth: number = 0): ImapValue {
    if (depth > 32) { throw new Error('邮件结构嵌套过深'); }
    while (this.source[this.position] === ' ') { this.position++; }
    let value = new ImapValue();
    let start = this.position;
    let ch = this.source[this.position++];
    if (ch === '(') {
      value.list = true;
      while (this.position < this.source.length) {
        while (this.source[this.position] === ' ') { this.position++; }
        if (this.source[this.position] === ')') { this.position++; return value; }
        value.children.push(this.read(depth + 1));
      }
      throw new Error('邮件结构不完整');
    }
    if (ch === '"') {
      while (this.position < this.source.length) {
        let next = this.source[this.position++];
        if (next === '"') { return value; }
        if (next === '\\') { next = this.source[this.position++]; }
        value.text += next;
      }
      throw new Error('邮件字符串不完整');
    }
    if (ch === '{') {
      let end = this.source.indexOf('}\r\n', start);
      if (end < 0) { throw new Error('邮件字节段无效'); }
      let length = Number(this.source.substring(start + 1, end).replace('+', ''));
      this.position = end + 3;
      if (!Number.isInteger(length) || length < 0 || this.position + length > this.source.length) {
        throw new Error('邮件字节段不完整');
      }
      value.text = this.source.substring(this.position, this.position + length);
      this.position += length;
      return value;
    }
    // FETCH section keys contain spaces inside brackets (HEADER.FIELDS (...)).
    let bracket = ch === '[' ? 1 : 0;
    while (this.position < this.source.length) {
      let next = this.source[this.position];
      if (next === '[') { bracket++; }
      if (next === ']') { bracket--; }
      if (bracket === 0 && (next === ' ' || next === ')')) { break; }
      this.position++;
    }
    value.text = this.source.substring(start, this.position);
    return value;
  }
}

export function imapFetch(frame: string): ImapValue | null {
  let start = frame.indexOf(' FETCH (');
  return start < 0 ? null : new ImapParser(frame.substring(start + 7)).read();
}
export function imapField(fetch: ImapValue, key: string): ImapValue {
  for (let index = 0; index + 1 < fetch.children.length; index += 2) {
    if (fetch.children[index].text.toUpperCase() === key.toUpperCase()) { return fetch.children[index + 1]; }
  }
  return new ImapValue();
}
export function imapBody(fetch: ImapValue): string {
  for (let index = 0; index + 1 < fetch.children.length; index += 2) {
    if (fetch.children[index].text.toUpperCase().startsWith('BODY[')) { return fetch.children[index + 1].text; }
  }
  return '';
}

export interface MailBodyPart { section: string; charset: string; encoding: string; html: boolean; size: number; }

function hasAttachment(value: ImapValue): boolean {
  if (!value.list) { return false; }
  if (value.children.length > 0 && /^(ATTACHMENT)$/i.test(value.children[0].text)) { return true; }
  for (let index = 0; index + 1 < value.children.length; index++) {
    if (/^(NAME|FILENAME)(?:\*\d*\*?)?$/i.test(value.children[index].text) && value.children[index + 1].text !== 'NIL') { return true; }
  }
  return value.children.some((child: ImapValue): boolean => hasAttachment(child));
}

export function mailBodyPart(structure: ImapValue, prefix: string = ''): MailBodyPart | null {
  let items = structure.children;
  if (items.length === 0) { return null; }
  if (items[0].list) {
    let end = 0;
    while (end < items.length && items[end].list) { end++; }
    // A multipart attachment can contain ordinary text children: skip that
    // entire container without excluding unrelated attachments in the message.
    if (items.slice(end + 1).some((value: ImapValue): boolean => hasAttachment(value))) { return null; }
    let best: MailBodyPart | null = null;
    for (let index = 0; index < items.length && items[index].list; index++) {
      let part = mailBodyPart(items[index], prefix ? prefix + '.' + (index + 1) : String(index + 1));
      if (part !== null && (best === null || (!part.html && best.html))) { best = part; }
    }
    return best;
  }
  if (items.length < 7 || items[0].text.toUpperCase() !== 'TEXT' ||
    !/^(PLAIN|HTML)$/i.test(items[1].text) || hasAttachment(structure)) { return null; }
  let charset = 'us-ascii';
  let params = items[2].children;
  for (let index = 0; index + 1 < params.length; index += 2) {
    if (params[index].text.toUpperCase() === 'CHARSET') { charset = params[index + 1].text; }
  }
  return { section: prefix || '1', charset: charset, encoding: items[5].text,
    html: items[1].text.toUpperCase() === 'HTML', size: Number(items[6].text) };
}

export function mailQuoted(value: string): string {
  if (/[\x00-\x1f\x7f]/.test(value)) { throw new Error('邮箱配置包含无效控制字符'); }
  return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

export function mailDecode(raw: string, encoding: string, charset: string): string {
  let bytes = mailBytes(raw);
  if (encoding.toUpperCase() === 'BASE64') {
    let base64 = raw.replace(/\s/g, '');
    // A partial fetch can end between base64 quartets.
    base64 = base64.substring(0, base64.length - base64.length % 4);
    bytes = new util.Base64Helper().decodeSync(base64);
  } else if (encoding.toUpperCase() === 'QUOTED-PRINTABLE') {
    bytes = mailBytes(raw.replace(/=\r?\n/g, '').replace(/=([0-9a-f]{2})/gi,
      (_match: string, hex: string): string => String.fromCharCode(parseInt(hex, 16))));
  }
  let name = charset.toLowerCase().replace(/^"|"$/g, '');
  if (name === 'gb2312' || name === 'gbk' || name === 'x-gbk') { name = 'gb18030'; }
  try { return new util.TextDecoder(name).decodeToString(bytes); }
  catch (e) { throw new Error('暂不支持邮件字符集：' + name.replace(/[^a-z0-9_-]/gi, '').slice(0, 30)); }
}

export function mailHeader(raw: string, name: string): string {
  let lines = raw.replace(/\r?\n[ \t]+/g, ' ').split(/\r?\n/);
  let line = lines.find((value: string): boolean => value.toLowerCase().startsWith(name.toLowerCase() + ':')) || '';
  let value = line.substring(line.indexOf(':') + 1).trim();
  if (/[\x80-\xff]/.test(value)) { value = mailDecode(value, '8BIT', 'utf-8'); }
  value = value.replace(/(\?=)\s+(=\?)/g, '$1$2');
  return value.replace(/=\?([^?]+)\?([bq])\?([^?]*)\?=/gi,
    (_match: string, charset: string, encoding: string, content: string): string =>
      mailDecode(encoding.toUpperCase() === 'Q' ? content.replace(/_/g, ' ') : content,
        encoding.toUpperCase() === 'Q' ? 'QUOTED-PRINTABLE' : 'BASE64', charset)).slice(0, 1000);
}

export function mailPlainHtml(html: string): string {
  return html.replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style|head)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, '')
    .replace(/<(br|\/p|\/div|\/tr|\/li|\/h[1-6])\b[^>]*>/gi, '\n').replace(/<[^>]*>/g, '')
    .replace(/&#(x[0-9a-f]+|\d+);/gi, (_match: string, code: string): string => {
      let point = code[0].toLowerCase() === 'x' ? parseInt(code.substring(1), 16) : Number(code);
      return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : '';
    }).replace(/&nbsp;/gi, ' ').replace(/&lt;/gi, '<').replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'").replace(/&amp;/gi, '&')
    .replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*\n/g, '\n\n').trim();
}

export function mailInternalDate(value: string): number {
  let match = /^(\d{1,2})-([a-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$/i.exec(value.trim());
  if (match === null) { return NaN; }
  let month = ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'].indexOf(match[2].toLowerCase());
  if (month < 0) { return NaN; }
  let offset = (Number(match[8]) * 60 + Number(match[9])) * (match[7] === '+' ? 1 : -1);
  return Date.UTC(Number(match[3]), month, Number(match[1]), Number(match[4]), Number(match[5]), Number(match[6])) - offset * 60000;
}

export function mailSearchDate(now: number, days: number): string {
  let date = new Date(now);
  date.setDate(date.getDate() + days);
  return date.getDate() + '-' + ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][date.getMonth()] + '-' + date.getFullYear();
}
