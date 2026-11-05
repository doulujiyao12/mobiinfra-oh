import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { RecordingAnalysis } from './RecordingTypes';
import { RecordingLiveUpdate, emptyLiveAnalysis, appendLiveUpdate } from './RecordingLiveTypes';
import { writeExact } from './RecordingWav';

// Append small completed batches. Do not rewrite hours of transcript every
// second or keep another copy of the audio. A torn final line is recoverable.
export class RecordingLiveCheckpoint {
  constructor(privatePath: string) { this.path = privatePath; }
  private path: string;
  append(update: RecordingLiveUpdate): void {
    const file = fs.openSync(this.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    try {
      fs.lseek(file.fd, fs.statSync(file.fd).size, fs.WhenceType.SEEK_SET);
      const bytes = new util.TextEncoder().encodeInto(ArkJSON.stringify(update) + '\n');
      writeExact(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
  }
  restore(duration: number): RecordingAnalysis {
    const result = emptyLiveAnalysis(duration);
    if (!fs.accessSync(this.path)) { return result; }
    const lines = fs.readTextSync(this.path).split('\n'); let processed = 0;
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].trim()) { continue; }
      // An append that did not reach its newline was never committed.
      if (i === lines.length - 1) { break; }
      const update = ArkJSON.parse(lines[i]) as RecordingLiveUpdate;
      if (update.processed < processed || update.processed > duration * 16000 + 1) { throw new Error('已保存的转写时间超出录音范围'); }
      appendLiveUpdate(result, update); processed = update.processed;
    }
    return result;
  }
}
