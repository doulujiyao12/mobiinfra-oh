export interface VoiceDetector {
  /** One exact 20 ms frame of S16LE mono PCM, at the configured sample rate. */
  process(pcm: ArrayBuffer): boolean;
  close(): void;
}
export const createDetector: (sampleRate: number, aggressiveness: number) => VoiceDetector;
