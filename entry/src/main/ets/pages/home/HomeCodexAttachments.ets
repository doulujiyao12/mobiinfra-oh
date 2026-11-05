import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DataManagerImageResolver } from '../../datamanager/DataManagerImageResolver';
import { homeCodexImageLabel } from '../../datamanager/HomeCodexContext';
import { DataManagerPaths } from '../../datamanager/DataManagerPaths';
import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { ChatSessionStorage } from '../../utils/ChatSessionStorage';
import { CODEX_MAX_FILE_BYTES } from '../codex/CodexTypes';

export interface HomeCodexAttachments {
  paths: string[];
  sources: string[];
  notices: string[];
}

// Copy source images into the new session's managed assets, including legacy
// JSON/base64 references. Codex accepts only files owned by this exact session.
export async function prepareHomeCodexAttachments(filesDir: string, sessionId: string,
  refs: string[]): Promise<HomeCodexAttachments> {
  let result: HomeCodexAttachments = { paths: [], sources: [], notices: [] };
  let storage = new DataManagerStorage();
  let resolver = new DataManagerImageResolver(new DataManagerPaths(filesDir, storage), storage);
  ChatSessionStorage.ensureSessionAssetsDir(filesDir, sessionId);
  let seen = new Set<string>();
  let fingerprints = new Set<string>();
  for (let ref of refs) {
    if (result.paths.length >= 6) { result.notices.push('截图较多，本次最多附 6 张。'); break; }
    let target = '';
    let input: fileIo.File | null = null;
    let output: fileIo.File | null = null;
    try {
      let resolved = resolver.resolveAll([ref])[0];
      if (!resolved || !resolved.available) { throw new Error('原图不可用'); }
      let uri = resolved.uri;
      if (seen.has(uri)) { continue; }
      seen.add(uri);
      let bytes: Uint8Array;
      let extension = 'jpg';
      if (uri.startsWith('data:image/')) {
        let match = /^data:image\/(png|jpe?g|webp);base64,([\s\S]+)$/.exec(uri);
        if (!match || match[2].length > Math.ceil(CODEX_MAX_FILE_BYTES * 4 / 3) + 8) {
          throw new Error('图片格式不支持或超过 8 MB');
        }
        extension = match[1] === 'jpeg' ? 'jpg' : match[1];
        bytes = new util.Base64Helper().decodeSync(match[2]);
      } else {
        if (/^https?:/.test(uri)) { throw new Error('原图不在本机'); }
        input = await fileIo.open(uri.startsWith('file://') ? uri.substring(7) : uri, fileIo.OpenMode.READ_ONLY);
        let size = (await fileIo.stat(input.fd)).size;
        if (size <= 0 || size > CODEX_MAX_FILE_BYTES) { throw new Error('图片为空或超过 8 MB'); }
        let buffer = new ArrayBuffer(size);
        let offset = 0;
        while (offset < size) {
          let chunk = new ArrayBuffer(size - offset);
          let count = await fileIo.read(input.fd, chunk, { offset: offset, length: chunk.byteLength });
          if (count <= 0) { throw new Error('图片读取不完整'); }
          new Uint8Array(buffer).set(new Uint8Array(chunk, 0, count), offset); offset += count;
        }
        bytes = new Uint8Array(buffer);
        let suffix = /\.(png|jpe?g|webp)(?:\?|$)/i.exec(uri);
        if (suffix) { extension = suffix[1].toLowerCase(); }
      }
      if (bytes.byteLength <= 0 || bytes.byteLength > CODEX_MAX_FILE_BYTES) { throw new Error('图片为空或超过 8 MB'); }
      let digest = cryptoFramework.createMd('SHA256');
      await digest.update({ data: bytes });
      let fingerprint = new util.Base64Helper().encodeToStringSync((await digest.digest()).data);
      if (fingerprints.has(fingerprint)) { continue; }
      target = ChatSessionStorage.sessionAssetsDir(filesDir, sessionId) + '/home-evidence-' + util.generateRandomUUID(true) + '.' + extension;
      output = await fileIo.open(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let written = 0;
      while (written < bytes.byteLength) {
        let buffer = bytes.slice(written).buffer as ArrayBuffer;
        let count = await fileIo.write(output.fd, buffer);
        if (count <= 0) { throw new Error('图片保存不完整'); }
        written += count;
      }
      result.paths.push('file://' + target); result.sources.push(homeCodexImageLabel(ref));
      fingerprints.add(fingerprint);
    } catch (e) {
      if (target) { try { await fileIo.unlink(target); } catch (cleanupError) { } }
      result.notices.push('未附截图 ' + homeCodexImageLabel(ref) + '：' + (e as Error).message);
    } finally {
      if (input !== null) { try { await fileIo.close(input); } catch (e) { } }
      if (output !== null) { try { await fileIo.close(output); } catch (e) { } }
    }
  }
  return result;
}
