import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, renameSync, realpathSync, lstatSync,
  openSync, closeSync, fstatSync, readSync, writeSync, unlinkSync, constants } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const MAX_ARTIFACT_BYTES = 128 * 1024 * 1024;
export const ARTIFACT_CHUNK_BYTES = 1024 * 1024;
const MAX_SESSION_BYTES = 512 * 1024 * 1024;
const MAX_STORE_BYTES = 2 * 1024 * 1024 * 1024;
const TYPES = { '.pdf': 'application/pdf', '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.ppt': 'application/vnd.ms-powerpoint', '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.doc': 'application/msword', '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.xls': 'application/vnd.ms-excel', '.csv': 'text/csv', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.gif': 'image/gif', '.bmp': 'image/bmp', '.tif': 'image/tiff', '.tiff': 'image/tiff',
  '.svg': 'image/svg+xml', '.txt': 'text/plain', '.md': 'text/markdown', '.json': 'application/json',
  '.zip': 'application/zip', '.odt': 'application/vnd.oasis.opendocument.text',
  '.ods': 'application/vnd.oasis.opendocument.spreadsheet', '.odp': 'application/vnd.oasis.opendocument.presentation',
  '.rtf': 'application/rtf', '.html': 'text/html' };

export const DELIVERY_INSTRUCTIONS = '文件交付约定：如本轮生成最终交付给用户的 PPT、PDF、Word、Excel、图片等文件，' +
  '请把成品保存在当前项目工作目录内（推荐 outputs/），并在最终答复中逐个给出标准 Markdown 链接 [文件名](文件绝对路径)。' +
  '只链接最终成品，不链接临时截图、中间文件、依赖、凭据或目录。没有交付文件时无需给文件链接。';

// Parse link destinations, including escaped/nested parentheses. Never scan disk for outputs.
export function finalFileLinks(markdown) {
  const value = String(markdown || '').slice(0, 128000).replace(/^(```|~~~)[\s\S]*?^\1[^\n]*$/gm, '');
  const links = [];
  for (let i = 0; i < value.length && links.length < 64; i++) {
    if (value[i] !== ']' || value[i + 1] !== '(') continue;
    let start = i + 2; while (/\s/.test(value[start] || '') && start < value.length) start++;
    let end = start; let depth = 1;
    if (value[start] === '<') {
      start++; end = value.indexOf('>', start); if (end < 0) continue;
      if (!/^\s*\)/.test(value.slice(end + 1, end + 20))) continue;
    } else {
      for (; end < value.length && depth; end++) {
        if (value[end] === '\\' && /[()\\]/.test(value[end + 1] || '')) { end++; continue; }
        if (value[end] === '(') depth++;
        if (value[end] === ')') depth--;
      }
      if (depth) continue;
      end--;
    }
    let target = value.slice(start, end).trim().replace(/\\([()\\])/g, '$1');
    // An optional Markdown link title is not part of the filename.
    target = target.replace(/\s+"[^"\n]*"$/, '');
    if (target && target.length <= 4096 && !/[\x00-\x1f]/.test(target)) links.push(target);
    i = end;
  }
  return links;
}

const contained = (root, file) => { const relative = path.relative(root, file);
  return relative && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative); };
const samePath = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
const descriptor = record => ({ id: record.id, turnId: record.turnId, name: record.name, size: record.size,
  mimeType: record.mimeType, sha256: record.sha256, createdAt: record.createdAt });

export class ArtifactStore {
  constructor(stateDir) {
    this.directory = path.join(stateDir, 'artifacts'); mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.indexFile = path.join(this.directory, 'index.json'); this.records = new Map();
    try { for (const record of JSON.parse(readFileSync(this.indexFile, 'utf8'))) this.records.set(record.id, record); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  save() {
    const temporary = this.indexFile + '.tmp';
    writeFileSync(temporary, JSON.stringify([...this.records.values()]), { mode: 0o600 }); renameSync(temporary, this.indexFile);
  }
  publish(task, finalText) {
    const output = []; const warnings = []; const seen = new Set();
    for (const link of finalFileLinks(finalText)) {
      if (output.length >= 24) { warnings.push('每轮最多接收 24 个交付文件'); break; }
      let source;
      try {
        if (/^file:/i.test(link)) source = fileURLToPath(link);
        else if (/^[a-z][a-z0-9+.-]*:/i.test(link) && !/^[a-z]:[\\/]/i.test(link)) continue;
        else source = decodeURIComponent(link);
        source = path.resolve(task.cwd, source);
        if (!contained(task.cwd, source) || !samePath(source, realpathSync(source))) continue;
        const relative = path.relative(task.cwd, source);
        if (relative.split(path.sep).some(part => /^(?:\.|node_modules$|__pycache__$|tmp$|temp$)/i.test(part))) continue;
        const name = path.basename(source); const mimeType = TYPES[path.extname(name).toLowerCase()];
        if (!mimeType || name.length > 180 || /[\x00-\x1f:]/.test(name)) continue;
        const key = process.platform === 'win32' ? source.toLowerCase() : source;
        if (seen.has(key)) continue; seen.add(key);
        const stat = lstatSync(source);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) continue;
        if (stat.size <= 0 || stat.size > MAX_ARTIFACT_BYTES) { warnings.push(name + '：文件需大于 0 且不超过 128 MiB'); continue; }
        const records = [...this.records.values()];
        if (records.length >= 2048 || records.filter(r => r.taskId === task.id).length >= 128 ||
          records.filter(r => r.taskId === task.id).reduce((n, r) => n + r.size, 0) + stat.size > MAX_SESSION_BYTES ||
          records.reduce((n, r) => n + r.size, 0) + stat.size > MAX_STORE_BYTES) {
          warnings.push(name + '：电脑端交付文件存储额度已满'); continue;
        }
        const id = randomUUID(); const temporary = path.join(this.directory, id + '.part');
        const destination = path.join(this.directory, id + '.bin');
        let input; let file;
        try {
          input = openSync(source, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
          const opened = fstatSync(input);
          if (!opened.isFile() || opened.ino !== stat.ino || opened.dev !== stat.dev || opened.size !== stat.size || opened.nlink !== 1) throw new Error('Source changed');
          file = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
          const hash = createHash('sha256'); const buffer = Buffer.alloc(ARTIFACT_CHUNK_BYTES); let offset = 0;
          while (offset < stat.size) {
            const count = readSync(input, buffer, 0, Math.min(buffer.length, stat.size - offset), offset);
            if (!count) throw new Error('Source changed');
            hash.update(buffer.subarray(0, count));
            let written = 0; while (written < count) written += writeSync(file, buffer, written, count - written);
            offset += count;
          }
          const after = fstatSync(input);
          if (after.size !== stat.size || after.mtimeMs !== opened.mtimeMs || !samePath(source, realpathSync(source))) throw new Error('Source changed');
          closeSync(file); file = undefined; renameSync(temporary, destination);
          const record = { id, taskId: task.id, turnId: task.turnId, name, size: stat.size, mimeType,
            sha256: hash.digest('hex'), createdAt: Date.now() };
          this.records.set(id, record); output.push(descriptor(record));
        } finally {
          if (input !== undefined) closeSync(input); if (file !== undefined) closeSync(file);
          try { unlinkSync(temporary); } catch { }
        }
      } catch { warnings.push((source ? path.basename(source) : '交付文件') + '：文件不可读或在收集期间发生变化'); }
    }
    this.save(); return { artifacts: output, warnings };
  }
  chunk(taskId, artifactId, offset, length = ARTIFACT_CHUNK_BYTES) {
    const record = this.records.get(artifactId);
    if (!record || record.taskId !== taskId) return null;
    if (!Number.isSafeInteger(offset) || offset < 0 || offset >= record.size) throw new Error('Invalid artifact offset');
    if (!Number.isSafeInteger(length) || length < 16384 || length > ARTIFACT_CHUNK_BYTES) throw new Error('Invalid artifact length');
    const file = openSync(path.join(this.directory, artifactId + '.bin'), constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    try {
      const stat = fstatSync(file); if (!stat.isFile() || stat.size !== record.size) throw new Error('Artifact unavailable');
      const buffer = Buffer.alloc(Math.min(length, record.size - offset));
      let read = 0; while (read < buffer.length) { const count = readSync(file, buffer, read, buffer.length - read, offset + read);
        if (!count) throw new Error('Artifact unavailable'); read += count; }
      return { id: record.id, offset, total: record.size, sha256: record.sha256, base64: buffer.toString('base64') };
    } finally { closeSync(file); }
  }
}
