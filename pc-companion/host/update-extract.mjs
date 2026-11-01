import { createReadStream } from 'node:fs';
import { mkdir, open } from 'node:fs/promises';
import { createGunzip } from 'node:zlib';
import path from 'node:path';

function safeName(name) {
  if (!name || name.length > 2048 || name.startsWith('/') || /[\\:\x00-\x1f]/.test(name) ||
      name.split('/').some(part => part === '..' || part === '.')) throw new Error('更新包包含不安全的文件路径');
  return name;
}
function octal(buffer) {
  const value = buffer.toString('ascii').replace(/\0.*$/, '').trim();
  if (!/^[0-7]+$/.test(value)) throw new Error('更新包 TAR 数值无效');
  const result = parseInt(value, 8);
  if (!Number.isSafeInteger(result) || result < 0) throw new Error('更新包 TAR 数值过大');
  return result;
}
function paxPath(buffer) {
  let position = 0; let name;
  while (position < buffer.length) {
    const space = buffer.indexOf(32, position);
    if (space < 0) throw new Error('更新包扩展头无效');
    const lengthText = buffer.subarray(position, space).toString('ascii');
    if (!/^\d{1,6}$/.test(lengthText)) throw new Error('更新包扩展头长度无效');
    const length = Number(lengthText);
    if (length <= space - position + 1 || position + length > buffer.length || buffer[position + length - 1] !== 10) throw new Error('更新包扩展头截断');
    const record = buffer.subarray(space + 1, position + length - 1).toString('utf8');
    if (record.startsWith('path=')) name = safeName(record.slice(5));
    else if (!/^(mtime|atime|ctime)=/.test(record)) throw new Error('更新包包含不支持的扩展头');
    position += length;
  }
  return name;
}

// Extract only files/directories, directly from a bounded TAR stream into a new
// private staging directory. Never invoke a shell or follow archived links.
export async function extractUpdate(archive, destination, kind) {
  const source = createReadStream(archive); const stream = createGunzip();
  source.on('error', error => stream.destroy(error)); source.pipe(stream);
  const iterator = stream[Symbol.asyncIterator](); let buffered = Buffer.alloc(0); let finished = false;
  async function take(length) {
    while (buffered.length < length && !finished) {
      const next = await iterator.next(); finished = next.done;
      if (!finished) buffered = Buffer.concat([buffered, next.value]);
    }
    if (buffered.length < length) throw new Error('更新包内容不完整');
    const result = buffered.subarray(0, length); buffered = buffered.subarray(length); return result;
  }
  let entries = 0; let bytes = 0; let nextName; const files = new Set(); let ended = false;
  try {
    while (++entries <= 20000) {
      const header = await take(512);
      if (header.every(byte => byte === 0)) { ended = true; break; }
      const checksum = octal(header.subarray(148, 156)); let sum = 0;
      for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : header[i];
      if (sum !== checksum) throw new Error('更新包 TAR 头校验失败');
      const text = (start, end) => header.subarray(start, end).toString('utf8').replace(/\0.*$/, '');
      const size = octal(header.subarray(124, 136)); const mode = octal(header.subarray(100, 108)); const type = String.fromCharCode(header[156] || 48);
      bytes += size; if (size > 1024 ** 3 || bytes > 2 * 1024 ** 3) throw new Error('更新包解压大小超过限制');
      if (type === 'x' || type === 'L') {
        if (size > 65536 || nextName !== undefined) throw new Error('更新包扩展头过大或重复');
        const content = await take(size); nextName = type === 'x' ? paxPath(content) : safeName(content.toString('utf8').replace(/\0.*$/, '').replace(/\n$/, ''));
        await take((512 - size % 512) % 512); continue;
      }
      if (!['0', '5'].includes(type)) throw new Error('更新包包含链接或不支持的文件类型');
      let name = safeName(nextName || [text(345, 500), text(0, 100)].filter(Boolean).join('/')); nextName = undefined;
      if (kind === 'desktop') {
        if (!name.startsWith('ClawMate-Codex/')) throw new Error('更新包的应用根目录不匹配');
        name = name.slice('ClawMate-Codex/'.length);
      }
      name = name.replace(/\/$/, '');
      if (!name && type === '5') continue;
      safeName(name);
      if (name.split('/').length > 32) throw new Error('更新包目录过深');
      const filename = path.join(destination, ...name.split('/')); const relative = path.relative(destination, filename);
      if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('更新包路径越界');
      if (type === '5') {
        if (size !== 0) throw new Error('更新包目录内容无效');
        await mkdir(filename, { recursive: true, mode: 0o755 });
      } else {
        if (files.has(name)) throw new Error('更新包包含重复文件'); files.add(name);
        await mkdir(path.dirname(filename), { recursive: true, mode: 0o755 });
        const file = await open(filename, 'wx', mode & 0o111 ? 0o755 : 0o644);
        try {
          let left = size;
          while (left) { const block = await take(Math.min(left, 65536)); let offset = 0;
            while (offset < block.length) { const result = await file.write(block, offset); offset += result.bytesWritten; }
            left -= block.length;
          }
        } finally { await file.close(); }
      }
      await take((512 - size % 512) % 512);
    }
    if (!ended || nextName !== undefined) throw new Error('更新包缺少结束记录');
    // Consume the remaining compressed stream so decompression errors propagate.
    if (buffered.some(byte => byte !== 0)) throw new Error('更新包尾部包含意外内容');
    for await (const chunk of { [Symbol.asyncIterator]: () => iterator }) if (chunk.some(byte => byte !== 0)) throw new Error('更新包尾部包含意外内容');
    return files.size;
  } finally { source.destroy(); stream.destroy(); }
}
