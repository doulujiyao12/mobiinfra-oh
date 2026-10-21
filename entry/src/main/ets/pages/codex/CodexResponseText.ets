import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

const MAX_RESPONSE_BYTES: number = 16 * 1024 * 1024;

// RCP versions may expose either the decoded body or the original gzip bytes.
// Inspect the actual bytes so an already decoded response is never inflated twice.
export async function codexResponseText(body: ArrayBuffer | undefined, text: string | null): Promise<string> {
  if ((body?.byteLength || 0) > MAX_RESPONSE_BYTES) { throw new Error('服务器响应过大'); }
  const bytes = body === undefined ? new Uint8Array(0) : new Uint8Array(body);
  if (bytes.length < 2 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) {
    if (text === null || text.trim().length === 0) { throw new Error('服务器未返回有效的文本响应，请稍后重试'); }
    return text;
  }
  if (bytes.length < 18) { throw new Error('服务器压缩响应不完整'); }
  const end = bytes.length;
  const size = (bytes[end - 4] | bytes[end - 3] << 8 | bytes[end - 2] << 16 | bytes[end - 1] << 24) >>> 0;
  if (!size || size > MAX_RESPONSE_BYTES) { throw new Error('服务器解压响应过大或无效'); }
  const zip = await zlib.createZip();
  const stream = await zip.getZStream();
  if (await zip.inflateInit2(stream, 31) !== zlib.ReturnStatus.OK) { throw new Error('无法初始化响应解压'); }
  try {
    const output = new ArrayBuffer(size + 1);
    stream.nextIn = body; stream.availableIn = bytes.length;
    stream.nextOut = output; stream.availableOut = output.byteLength;
    const status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
    const result = await zip.getZStream();
    if (status !== zlib.ReturnStatus.STREAM_END || result.totalOut !== size || result.availableIn !== 0) {
      throw new Error('服务器压缩响应损坏或不完整');
    }
    return new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(output, 0, size));
  } finally { await zip.inflateEnd(stream); }
}
