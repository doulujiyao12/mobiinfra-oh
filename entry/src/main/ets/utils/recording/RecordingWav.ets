import { fileIo as fs } from '@kit.CoreFileKit';
import { RECORDING_MAX_BYTES, RECORDING_MAX_SECONDS } from './RecordingTypes';

export interface RecordingWavInfo {
  format: number; channels: number; rate: number; bits: number; align: number; offset: number; bytes: number;
}
export function writeExact(fd: number, buffer: ArrayBuffer): void {
  let done = 0;
  while (done < buffer.byteLength) {
    let count = fs.writeSync(fd, buffer.slice(done));
    if (count <= 0) { throw new Error('录音文件写入失败'); }
    done += count;
  }
}

// Only the app's fixed-format capture WAV. The header may lag behind the
// appended PCM, so read only a bounded range the capture writer has committed.
export function readCapturedPcm(path: string, start: number, end: number): Float32Array {
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || end - start > 64000) {
    throw new Error('实时转写的音频范围无效');
  }
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const header = new DataView(readExact(file.fd, 0, 44));
    if (header.getUint16(20, true) !== 1 || header.getUint16(22, true) !== 1 ||
      header.getUint32(24, true) !== 16000 || header.getUint16(34, true) !== 16 || fs.statSync(file.fd).size < 44 + end * 2) {
      throw new Error('实时录音数据尚未完整写入');
    }
    const bytes = new DataView(readExact(file.fd, 44 + start * 2, (end - start) * 2));
    const result = new Float32Array(end - start);
    for (let i = 0; i < result.length; i++) { result[i] = bytes.getInt16(i * 2, true) / 32768; }
    return result;
  } finally { fs.closeSync(file); }
}
function tag(bytes: Uint8Array, start: number): string {
  return String.fromCharCode(bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3]);
}
export function wavHeader(pcmBytes: number): ArrayBuffer {
  let bytes = new Uint8Array(44); let view = new DataView(bytes.buffer);
  let labels: string[] = ['RIFF', 'WAVE', 'fmt ', 'data']; let offsets: number[] = [0, 8, 12, 36];
  labels.forEach((label: string, i: number): void => {
    for (let k = 0; k < 4; k++) { bytes[offsets[i] + k] = label.charCodeAt(k); }
  });
  view.setUint32(4, pcmBytes + 36, true); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
  view.setUint16(22, 1, true); view.setUint32(24, 16000, true); view.setUint32(28, 32000, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true); view.setUint32(40, pcmBytes, true);
  return bytes.buffer;
}
export function readExact(fd: number, offset: number, length: number): ArrayBuffer {
  let buffer = new ArrayBuffer(length); let done = 0;
  fs.lseek(fd, offset, fs.WhenceType.SEEK_SET);
  while (done < length) {
    let part = new ArrayBuffer(length - done);
    let n = fs.readSync(fd, part, { length: length - done });
    if (n <= 0) { throw new Error('WAV 文件不完整'); }
    new Uint8Array(buffer).set(new Uint8Array(part, 0, n), done); done += n;
  }
  return buffer;
}
export function inspectWav(fd: number): RecordingWavInfo {
  let size = fs.statSync(fd).size;
  if (size < 44 || size > RECORDING_MAX_BYTES) { throw new Error('请选择完整 WAV 文件，文件须小于 2 GB'); }
  let head = new Uint8Array(readExact(fd, 0, 12));
  if (tag(head, 0) !== 'RIFF' || tag(head, 8) !== 'WAVE') { throw new Error('文件不是 RIFF/WAVE 音频'); }
  let info: RecordingWavInfo = { format: 0, channels: 0, rate: 0, bits: 0, align: 0, offset: 0, bytes: 0 };
  let end = new DataView(head.buffer).getUint32(4, true) + 8;
  if (end > size || end < 44) { throw new Error('WAV 长度声明无效'); }
  for (let pos = 12; pos + 8 <= end;) {
    let chunk = new Uint8Array(readExact(fd, pos, 8)); let length = new DataView(chunk.buffer).getUint32(4, true);
    if (pos + 8 + length > end) { throw new Error('WAV 数据块已损坏'); }
    if (tag(chunk, 0) === 'fmt ') {
      if (length < 16) { throw new Error('WAV 格式块不完整'); }
      let fmt = new DataView(readExact(fd, pos + 8, Math.min(length, 40)));
      info.format = fmt.getUint16(0, true); info.channels = fmt.getUint16(2, true);
      info.rate = fmt.getUint32(4, true); info.align = fmt.getUint16(12, true); info.bits = fmt.getUint16(14, true);
    }
    if (tag(chunk, 0) === 'data' && info.bytes === 0) { info.offset = pos + 8; info.bytes = length; }
    pos += 8 + length + (length % 2);
  }
  if ((info.format !== 1 && info.format !== 3) || (info.channels !== 1 && info.channels !== 2) ||
    info.rate < 8000 || info.rate > 192000 || [8, 16, 24, 32].indexOf(info.bits) < 0 ||
    (info.format === 3 && info.bits !== 32) || info.align !== info.channels * info.bits / 8 ||
    info.bytes === 0 || info.bytes % info.align !== 0) {
    throw new Error('支持单/双声道 PCM 8/16/24/32位及 Float32 WAV；请先转换压缩或扩展格式 WAV');
  }
  if (info.bytes / info.align / info.rate > RECORDING_MAX_SECONDS) { throw new Error('单条录音最长支持 12 小时'); }
  return info;
}
// Read through a small window instead of loading the entire original WAV into memory.
export function recordingWavDuration(path: string): number {
  let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try { let info = inspectWav(file.fd); return info.bytes / info.align / info.rate; }
  finally { fs.closeSync(file); }
}
export function readWav16k(path: string, startSeconds: number = 0, endSeconds: number = RECORDING_MAX_SECONDS): Float32Array {
  let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    let info = inspectWav(file.fd); let frames = info.bytes / info.align;
    let start = Math.max(0, Math.floor(startSeconds * 16000));
    let stop = Math.min(Math.floor(frames * 16000 / info.rate), Math.ceil(endSeconds * 16000));
    let output = new Float32Array(Math.max(0, stop - start));
    let cacheStart = -1; let cache = new DataView(new ArrayBuffer(0)); let cacheFrames = 0;
    let sampleAt = (frame: number): number => {
      frame = Math.min(frames - 1, Math.max(0, frame));
      if (frame < cacheStart || frame >= cacheStart + cacheFrames) {
        cacheStart = frame; cacheFrames = Math.min(16384, frames - frame);
        cache = new DataView(readExact(file.fd, info.offset + frame * info.align, cacheFrames * info.align));
      }
      let value = 0;
      for (let c = 0; c < info.channels; c++) {
        let p = (frame - cacheStart) * info.align + c * info.bits / 8; let s = 0;
        if (info.format === 3) { s = cache.getFloat32(p, true); }
        else if (info.bits === 8) { s = (cache.getUint8(p) - 128) / 128; }
        else if (info.bits === 16) { s = cache.getInt16(p, true) / 32768; }
        else if (info.bits === 24) {
          let n = cache.getUint8(p) | cache.getUint8(p + 1) << 8 | cache.getUint8(p + 2) << 16;
          s = ((n & 0x800000) !== 0 ? n - 0x1000000 : n) / 8388608;
        } else { s = cache.getInt32(p, true) / 2147483648; }
        value += Number.isFinite(s) ? Math.max(-1, Math.min(1, s)) : 0;
      }
      return value / info.channels;
    };
    let ratio = info.rate / 16000;
    for (let i = 0; i < output.length; i++) {
      let position = (start + i) * ratio; let left = Math.floor(position);
      if (ratio > 1) {
        // Box prefilter prevents simply dropping high-rate samples during downsampling.
        let end = (start + i + 1) * ratio; let sum = 0;
        for (let f = left; f < Math.ceil(end); f++) {
          sum += sampleAt(f) * (Math.min(end, f + 1) - Math.max(position, f));
        }
        output[i] = sum / ratio;
      } else { output[i] = sampleAt(left) * (1 - position + left) + sampleAt(left + 1) * (position - left); }
    }
    return output;
  } finally { fs.closeSync(file); }
}
