import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { AudioCodecJob, createAudioCodecJob } from 'libwatchaudio.so';
import { parseRecordingName } from '../core/Wav';

class AudioCache {
  sourceBytes: number = 0;
  sourceMtime: number = 0;
  encodedBytes: number = 0;
  version: number = 1;
}

export function removeAudioCache(path: string): void {
  for (const suffix of ['.transfer.aac', '.transfer.aac.json']) {
    if (fs.accessSync(path + suffix)) { fs.unlinkSync(path + suffix); }
  }
}

export function cleanInterruptedAudioCaches(directory: string): void {
  for (const name of fs.listFileSync(directory)) {
    const index = name.indexOf('.transfer.aac');
    if (index < 0 || parseRecordingName(name.substring(0, index)) === undefined) { continue; }
    const path = directory + '/' + name;
    if (name.endsWith('.lock')) { fs.rmdirSync(path); }
    else if (name.endsWith('.part')) { fs.unlinkSync(path); }
  }
}

// A directory lease coordinates post-recording and foreground jobs across Workers.
export async function prepareWatchAac(path: string, active: () => boolean,
  onProgress: (percent: number) => void): Promise<string> {
  if (!canIUse('SystemCapability.Multimedia.Media.AudioCodec')) { return ''; }
  const lock = path + '.transfer.aac.lock';
  const deadline = Date.now() + 120000;
  while (true) {
    if (!active()) { throw new Error('音频处理已取消'); }
    try { fs.mkdirSync(lock); break; }
    catch (error) { if (!fs.accessSync(lock)) { throw error as Error; } }
    if (Date.now() >= deadline) { return ''; }
    onProgress(0);
    await new Promise<void>((resolve) => { setTimeout(resolve, 300); });
  }
  try { return await encodeWatchAac(path, active, onProgress); }
  finally { if (fs.accessSync(lock)) { fs.rmdirSync(lock); } }
}

async function encodeWatchAac(path: string, active: () => boolean,
  onProgress: (percent: number) => void): Promise<string> {
  if (!canIUse('SystemCapability.Multimedia.Media.AudioCodec')) { return ''; }
  const parsed = parseRecordingName(path.substring(path.lastIndexOf('/') + 1));
  if (parsed === undefined || parsed.partial) { return ''; }
  const source = fs.statSync(path);
  if (source.size < 32 * 1024) { return ''; }
  const destination = path + '.transfer.aac';
  const receipt = destination + '.json';
  try {
    if (fs.accessSync(destination) && fs.accessSync(receipt)) {
      const cached = ArkJSON.parse(fs.readTextSync(receipt)) as AudioCache;
      if (cached.version === 1 && cached.sourceBytes === source.size && cached.sourceMtime === source.mtime &&
        cached.encodedBytes > 0 && cached.encodedBytes < source.size &&
        fs.statSync(destination).size === cached.encodedBytes) { return destination; }
    }
  } catch (_) { /* An interrupted cache never affects the original recording. */ }
  const temporary = destination + '.' + util.generateRandomUUID(true) + '.part';
  const job: AudioCodecJob = createAudioCodecJob();
  const timer = setInterval((): void => {
    if (!active()) { job.cancel(); }
    else { onProgress(job.progress()); }
  }, 300);
  try {
    if (!active()) { throw new Error('音频处理已取消'); }
    onProgress(0);
    const encodedBytes = await job.run(path, temporary, false, parsed.sampleRate, source.size);
    if (!active()) { throw new Error('音频处理已取消'); }
    const current = fs.statSync(path);
    if (current.size !== source.size || current.mtime !== source.mtime || encodedBytes >= source.size) { return ''; }
    fs.renameSync(temporary, destination);
    const cache = new AudioCache();
    cache.sourceBytes = source.size; cache.sourceMtime = source.mtime; cache.encodedBytes = encodedBytes;
    const file = fs.openSync(receipt, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const content = new util.TextEncoder().encodeInto(ArkJSON.stringify(cache));
      let offset = 0;
      while (offset < content.byteLength) {
        const size = fs.writeSync(file.fd, content.slice(offset).buffer as ArrayBuffer);
        if (size <= 0) { throw new Error('保存音频缓存失败'); }
        offset += size;
      }
    } finally { fs.closeSync(file.fd); }
    if (!fs.accessSync(path)) { removeAudioCache(path); return ''; }
    return destination;
  } finally {
    clearInterval(timer);
    if (fs.accessSync(temporary)) { fs.unlinkSync(temporary); }
  }
}
