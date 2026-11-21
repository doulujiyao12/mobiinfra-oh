export interface AudioCodecJob {
  run(input: string, output: string, decode: boolean, sampleRate: number, originalBytes: number): Promise<number>;
  progress(): number;
  cancel(): void;
}
export function createAudioCodecJob(): AudioCodecJob;
