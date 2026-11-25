import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { writeExact } from './RecordingWav';

export function writeRecordingMetadata(path: string, payload: Object): void {
  const bytes = new util.TextEncoder().encodeInto(ArkJSON.stringify(payload));
  const temporary = path + '.tmp';
  const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    writeExact(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
    fs.fsyncSync(file.fd);
  } finally { fs.closeSync(file); }
  fs.renameSync(temporary, path);
}
