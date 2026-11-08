// Pure binary/filename logic is also exercised on the host by tests/audio-core.test.mjs.
export const WAV_HEADER_BYTES: number = 44;
export const OUTPUT_SAMPLE_RATE: number = 16000;
export const SEGMENT_SECONDS: number = 300;
export const MAX_SESSION_SECONDS: number = 6 * 60 * 60;

export function alignedPcmBytes(bytes: number): number {
  return Math.max(0, Math.floor(bytes / 2) * 2);
}

export function createWavHeader(dataBytes: number, sampleRate: number): ArrayBuffer {
  const bytes: number = alignedPcmBytes(dataBytes);
  if (!Number.isFinite(bytes) || bytes > 0xFFFFFFFF - 36 ||
    (sampleRate !== 16000 && sampleRate !== 48000)) {
    throw new Error('无效的 WAV 参数');
  }
  const header: ArrayBuffer = new ArrayBuffer(WAV_HEADER_BYTES);
  const view: DataView = new DataView(header);
  const magic: number[] = [82, 73, 70, 70, 87, 65, 86, 69, 102, 109, 116, 32, 100, 97, 116, 97];
  for (let i: number = 0; i < 4; i++) {
    view.setUint8(i, magic[i]);
    view.setUint8(8 + i, magic[4 + i]);
    view.setUint8(12 + i, magic[8 + i]);
    view.setUint8(36 + i, magic[12 + i]);
  }
  view.setUint32(4, bytes + 36, true);
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  view.setUint32(40, bytes, true);
  return header;
}

export function isOwnWavHeader(header: ArrayBuffer, sampleRate: number): boolean {
  if (header.byteLength !== WAV_HEADER_BYTES) { return false; }
  const view: DataView = new DataView(header);
  return view.getUint32(0, false) === 0x52494646 &&
    view.getUint32(8, false) === 0x57415645 &&
    view.getUint32(12, false) === 0x666D7420 &&
    view.getUint32(16, true) === 16 && view.getUint16(20, true) === 1 &&
    view.getUint16(22, true) === 1 && view.getUint32(24, true) === sampleRate &&
    view.getUint16(32, true) === 2 && view.getUint16(34, true) === 16 &&
    view.getUint32(36, false) === 0x64617461;
}

export class RecordingName {
  timestamp: number = 0;
  segment: number = 0;
  sampleRate: number = 0;
  partial: boolean = false;
  version: number = 1;
  mode: string = 'manual';
}

export function parseRecordingName(name: string): RecordingName | undefined {
  // Version 2 timestamps describe the actual start of each detected clip.
  const detected: RegExpMatchArray | null = name.match(/^cm2_(\d{13})_(\d{4,6})_(16000|48000)_(sound|speech)\.wav(\.part)?$/);
  if (detected !== null) {
    const result: RecordingName = new RecordingName();
    result.timestamp = Number(detected[1]);
    result.segment = Number(detected[2]);
    result.sampleRate = Number(detected[3]);
    result.mode = detected[4];
    result.partial = detected[5] === '.part';
    result.version = 2;
    return result;
  }
  const match: RegExpMatchArray | null = name.match(/^cm_(\d{13})_(\d{3})_(16000|48000)\.wav(\.part)?$/);
  if (match === null) { return undefined; }
  const result: RecordingName = new RecordingName();
  result.timestamp = Number(match[1]);
  result.segment = Number(match[2]);
  result.sampleRate = Number(match[3]);
  result.partial = match[4] === '.part';
  return result;
}

export function recordingFileName(timestamp: number, segment: number, sampleRate: number): string {
  return `cm_${timestamp}_${segment.toString().padStart(3, '0')}_${sampleRate}.wav`;
}

export function triggeredFileName(timestamp: number, segment: number, sampleRate: number, mode: string): string {
  return `cm2_${Math.round(timestamp)}_${segment.toString().padStart(4, '0')}_${sampleRate}_${mode}.wav`;
}

export function formatDuration(milliseconds: number): string {
  const seconds: number = Math.max(0, Math.floor(milliseconds / 1000));
  const minutes: number = Math.floor(seconds / 60);
  return `${minutes.toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
}
