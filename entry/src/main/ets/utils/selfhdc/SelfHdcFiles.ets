import { fileIo as fs } from '@kit.CoreFileKit';
import { encodeUtf8Compat } from '../TextEncodingCompat';
import { selfHdcErrorText } from './SelfHdcError';

export function selfHdcExists(path: string): boolean {
  try { return fs.accessSync(path); } catch (e) {
    throw new Error('SELF_HDC_FILE: access ' + path + ' ' + selfHdcErrorText(e as Error));
  }
}

export function selfHdcEnsureDirectory(path: string): void {
  try {
    if (!fs.accessSync(path)) { fs.mkdirSync(path, true); }
  } catch (e) {
    throw new Error('SELF_HDC_FILE: mkdir ' + path + ' ' + selfHdcErrorText(e as Error));
  }
}

export function selfHdcWrite(path: string, bytes: Uint8Array, append: boolean = false): void {
  try {
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
      (append ? fs.OpenMode.APPEND : fs.OpenMode.TRUNC));
    try {
      let offset = 0;
      while (offset < bytes.length) {
        let count = fs.writeSync(file.fd, bytes.slice(offset).buffer);
        if (count <= 0) { throw new Error('short file write'); }
        offset += count;
      }
    } finally { fs.closeSync(file); }
  } catch (e) {
    throw new Error('SELF_HDC_FILE: write ' + path + ' ' + selfHdcErrorText(e as Error));
  }
}

export function selfHdcWriteText(path: string, value: string, append: boolean = false): void {
  selfHdcWrite(path, encodeUtf8Compat(value), append);
}

export function selfHdcReadText(path: string, maxBytes: number): string {
  try {
    if (fs.statSync(path).size > maxBytes) { throw new Error('file too large'); }
    return fs.readTextSync(path);
  } catch (e) {
    throw new Error('SELF_HDC_FILE: read ' + path + ' ' + selfHdcErrorText(e as Error));
  }
}

export function selfHdcWriteAtomicText(path: string, value: string): void {
  selfHdcWriteText(path + '.tmp', value);
  try { fs.renameSync(path + '.tmp', path); } catch (e) {
    throw new Error('SELF_HDC_FILE: rename ' + path + ' ' + selfHdcErrorText(e as Error));
  }
}
