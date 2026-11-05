// Phone-side contract matching bridge/codex/server.mjs. Count encoded JSON:
// Chinese text is usually three UTF-8 bytes and escaped text can be larger.
export const CODEX_JSON_REQUEST_BYTES: number = 64000;
export const CODEX_UPLOAD_REQUEST_BYTES: number = 12 * 1024 * 1024;
export const CODEX_UPLOAD_ROUTE: string = '/v1/uploads';

export function codexUtf8Bytes(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index++) {
    let code = text.charCodeAt(index);
    if (code < 128) { bytes++; }
    else if (code < 2048) { bytes += 2; }
    else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length &&
      text.charCodeAt(index + 1) >= 0xDC00 && text.charCodeAt(index + 1) <= 0xDFFF) { bytes += 4; index++; }
    else { bytes += 3; }
  }
  return bytes;
}

export function codexUtf8Excerpt(text: string, limit: number): string {
  let bytes = 0;
  let end = 0;
  while (end < text.length) {
    let code = text.charCodeAt(end);
    let pair = code >= 0xD800 && code <= 0xDBFF && end + 1 < text.length &&
      text.charCodeAt(end + 1) >= 0xDC00 && text.charCodeAt(end + 1) <= 0xDFFF;
    let width = pair ? 4 : code < 128 ? 1 : code < 2048 ? 2 : 3;
    if (bytes + width > limit) { break; }
    bytes += width; end += pair ? 2 : 1;
  }
  return text.slice(0, end);
}

export function checkCodexJsonBudget(route: string, encoded: string): void {
  let maximum = route === CODEX_UPLOAD_ROUTE ? CODEX_UPLOAD_REQUEST_BYTES : CODEX_JSON_REQUEST_BYTES;
  if (codexUtf8Bytes(encoded) > maximum) {
    throw new Error(route === CODEX_UPLOAD_ROUTE ? '图片请求过大，请压缩图片后重试' : 'Codex 请求内容过多，请精简相关资料后重试；本次未发送');
  }
}
