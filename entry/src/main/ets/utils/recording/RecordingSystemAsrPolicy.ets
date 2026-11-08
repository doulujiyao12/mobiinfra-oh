import { speechRecognizer } from '@kit.CoreSpeechKit';

export const SYSTEM_ASR_MODEL_ID: string = 'harmony-offline-asr-v1';
export const SYSTEM_ASR_FILE: string = 'system-transcript.jsonl';
export const SYSTEM_ASR_FRAME: number = 640; // 40 ms, 1280 bytes of PCM16.
export const SYSTEM_ASR_WINDOW: number = 55 * 16000;
export const SYSTEM_ASR_OVERLAP: number = 12800;

// Long mode supplies partial sentences. Bounded sessions also work with systems
// whose writeAudio path still imposes the documented 60-second input limit.
export function systemAsrStartParams(sessionId: string): speechRecognizer.StartParams {
  const option: Record<string, Object> = { 'enablePartialResult': true };
  const extra: Record<string, Object> = {
    'recognitionMode': 1, 'vadBegin': 10000, 'vadEnd': 10000,
    'maxAudioDuration': 60000, 'recognizerOption': option
  };
  return { sessionId: sessionId,
    audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }, extraParams: extra };
}

export function systemAsrPcm(samples: Float32Array): Uint8Array {
  if (samples.length > SYSTEM_ASR_FRAME) { throw new Error('系统转写音频帧过长'); }
  const data = new Uint8Array(SYSTEM_ASR_FRAME * 2); const view = new DataView(data.buffer);
  for (let i = 0; i < samples.length; i++) {
    if (!Number.isFinite(samples[i])) { throw new Error('系统转写音频数据无效'); }
    view.setInt16(i * 2, Math.round(Math.max(-1, Math.min(32767 / 32768, samples[i])) * 32768), true);
  }
  return data;
}

// Trim only the audio overlap we intentionally replay at a hard session
// boundary. Ordinary repeated phrases and neighbouring sentences are retained.
export function trimSystemAsrOverlap(previous: string, next: string, replayed: boolean): string {
  if (!replayed || !previous || !next) { return next; }
  const punctuation = /[\s，。！？、；：,.!?;:]/;
  let tail = ''; let prefix = ''; const offsets: number[] = [];
  for (let char of previous.slice(-100).split('')) { if (!punctuation.test(char)) { tail += char.toLowerCase(); } }
  for (let i = 0; i < next.length && prefix.length < 12; i++) {
    if (!punctuation.test(next.charAt(i))) { prefix += next.charAt(i).toLowerCase(); offsets.push(i + 1); }
  }
  for (let length = Math.min(tail.length, prefix.length, 12); length >= 2; length--) {
    if (tail.endsWith(prefix.substring(0, length))) {
      const remainder = next.substring(offsets[length - 1]).replace(/^[\s，。！？、；：,.!?;:]+/, '');
      return remainder || next;
    }
  }
  return next;
}
