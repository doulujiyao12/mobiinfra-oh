import { fileIo } from '@kit.CoreFileKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { CodexClient } from './CodexClient';
import { CodexArtifact, CodexLocalArtifact } from './CodexTypes';

const MAX_ARTIFACT_BYTES: number = 128 * 1024 * 1024;
const CHUNK_BYTES: number = 1024 * 1024;

function hex(data: Uint8Array): string {
  let value: string = '';
  for (let i = 0; i < data.length; i++) { value += data[i].toString(16).padStart(2, '0'); }
  return value;
}

export function validateCodexArtifact(artifact: CodexArtifact): void {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(artifact.id) || !/^[a-f0-9]{64}$/.test(artifact.sha256) ||
    !Number.isSafeInteger(artifact.size) || artifact.size < 1 || artifact.size > MAX_ARTIFACT_BYTES ||
    !artifact.name || artifact.name.length > 180 || /[\x00-\x1f/\\:]/.test(artifact.name) ||
    artifact.name === '.' || artifact.name === '..' || artifact.name.startsWith('.')) {
    throw new Error('电脑返回的交付文件信息无效');
  }
}

export class CodexArtifactStore {
  private root: string;
  private constructor(root: string) { this.root = root; }

  static async create(filesDir: string, origin: string, taskId: string): Promise<CodexArtifactStore> {
    if (!filesDir || !/^[A-Za-z0-9_-]{1,128}$/.test(taskId)) { throw new Error('无法创建会话文件目录'); }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(origin) });
    const host = hex((await md.digest()).data);
    const root = filesDir + '/codex/sessions/' + host + '/' + taskId + '/artifacts';
    if (!await fileIo.access(root)) { await fileIo.mkdir(root, true); }
    return new CodexArtifactStore(root);
  }

  private async digestFile(path: string): Promise<string> {
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = (await fileIo.stat(file.fd)).size;
      if (size > MAX_ARTIFACT_BYTES) { throw new Error('会话文件超过大小限制'); }
      const md = cryptoFramework.createMd('SHA256');
      let offset: number = 0;
      while (offset < size) {
        const buffer = new ArrayBuffer(Math.min(CHUNK_BYTES, size - offset));
        const count = await fileIo.read(file.fd, buffer, { offset: offset, length: buffer.byteLength });
        if (count <= 0) { throw new Error('会话文件读取不完整'); }
        await md.update({ data: new Uint8Array(buffer, 0, count) }); offset += count;
      }
      return hex((await md.digest()).data);
    } finally { await fileIo.close(file); }
  }

  private local(artifact: CodexArtifact, path: string): CodexLocalArtifact {
    return { id: artifact.id, turnId: artifact.turnId, name: artifact.name, size: artifact.size,
      mimeType: artifact.mimeType, sha256: artifact.sha256, createdAt: artifact.createdAt, localPath: path };
  }

  async receive(taskId: string, artifact: CodexArtifact, client: CodexClient,
    isCurrent: () => boolean, onProgress: (received: number, total: number) => void): Promise<CodexLocalArtifact> {
    validateCodexArtifact(artifact);
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(taskId)) { throw new Error('会话编号无效'); }
    const directory = this.root + '/' + artifact.id;
    if (!await fileIo.access(directory)) { await fileIo.mkdir(directory, true); }
    const extension = artifact.name.substring(artifact.name.lastIndexOf('.'));
    const filename = new util.TextEncoder().encodeInto(artifact.name).byteLength <= 240 ? artifact.name :
      artifact.name.substring(0, 60) + extension;
    const destination = directory + '/' + filename;
    if (await fileIo.access(destination)) {
      if ((await fileIo.stat(destination)).size === artifact.size && await this.digestFile(destination) === artifact.sha256) {
        return this.local(artifact, destination);
      }
    }
    const partial = directory + '/download-' + util.generateRandomUUID(true) + '.part';
    let file: fileIo.File | null = null;
    const chunkBytes = client.artifactChunkBytes();
    try {
      file = await fileIo.open(partial, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      let offset: number = 0;
      while (offset < artifact.size) {
        if (!isCurrent()) { throw new Error('文件接收已取消'); }
        const result = await client.call('/v1/tasks/' + taskId + '/artifacts/' + artifact.id + '?offset=' + offset +
          (chunkBytes < CHUNK_BYTES ? '&length=' + chunkBytes : ''));
        if (!isCurrent()) { throw new Error('文件接收已取消'); }
        const chunk = result.artifactChunk;
        if (chunk === undefined || chunk.id !== artifact.id || chunk.offset !== offset || chunk.total !== artifact.size ||
          chunk.sha256 !== artifact.sha256 || chunk.base64.length > 1400000 || chunk.base64.length % 4 !== 0 ||
          !/^[A-Za-z0-9+/]*={0,2}$/.test(chunk.base64)) { throw new Error('交付文件分块校验失败'); }
        const data = new util.Base64Helper().decodeSync(chunk.base64);
        const expected = Math.min(chunkBytes, artifact.size - offset);
        if (data.byteLength !== expected) { throw new Error('交付文件分块长度不匹配'); }
        let written: number = 0;
        while (written < data.byteLength) {
          const buffer = new ArrayBuffer(data.byteLength - written);
          new Uint8Array(buffer).set(data.subarray(written));
          const count = await fileIo.write(file.fd, buffer, { offset: offset + written, length: buffer.byteLength });
          if (count <= 0) { throw new Error('无法写入会话文件，请检查手机剩余空间'); }
          written += count;
        }
        offset += data.byteLength; onProgress(offset, artifact.size);
      }
      await fileIo.close(file); file = null;
      if (await this.digestFile(partial) !== artifact.sha256) { throw new Error('交付文件 SHA256 不一致，请重新下载'); }
      if (!isCurrent()) { throw new Error('文件接收已取消'); }
      await fileIo.rename(partial, destination);
      const local = this.local(artifact, destination);
      const manifest = await fileIo.open(directory + '/.metadata.json', fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try { await fileIo.write(manifest.fd, ArkJSON.stringify(artifact)); } finally { await fileIo.close(manifest); }
      return local;
    } finally {
      if (file !== null) { try { await fileIo.close(file); } catch (e) { } }
      try { await fileIo.unlink(partial); } catch (e) { }
    }
  }
}
