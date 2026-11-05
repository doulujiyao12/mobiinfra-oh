import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { wavHeader, writeExact } from './RecordingWav';
import { RECORDING_MAX_SECONDS } from './RecordingTypes';
import { RecordingAudioSource } from './RecordingAudioSource';
import { RecordingSystemCapture } from './RecordingSystemCapture';

export class RecordingCapture {
  private capturer: audio.AudioCapturer | null = null;
  private file: fs.File | null = null;
  private bytes: number = 0;
  private stopping: Promise<number> | null = null;
  private failure: string = '';
  private checkpoint: number = 0;
  private system: RecordingSystemCapture | null = null;
  private generation: number = 0;
  async start(path: string, onLimit: () => void, onError: (message: string) => void,
    source: RecordingAudioSource = 'environment'): Promise<void> {
    this.bytes = 0; this.stopping = null; this.failure = ''; this.checkpoint = Date.now();
    let generation = ++this.generation;
    try {
      this.file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      writeExact(this.file.fd, wavHeader(0));
      if (source !== 'environment') {
        this.system = new RecordingSystemCapture();
        await this.system.start(source === 'mixed', (data: ArrayBuffer): void => { this.write(data, onLimit, onError); }, onLimit, onError);
        return;
      }
      let capturer = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
      });
      if (generation !== this.generation) { await capturer.release(); throw new Error('已取消声音录制'); }
      this.capturer = capturer;
      this.capturer.on('readData', (data: ArrayBuffer): void => {
        this.write(data, onLimit, onError);
      });
      this.capturer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP || event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
          onLimit();
        }
      });
      await this.capturer.start();
      if (generation !== this.generation) { throw new Error('已取消声音录制'); }
      if (this.failure) { throw new Error(this.failure); }
    } catch (e) { await this.stop(); throw new Error((e as Error).message); }
  }
  private write(data: ArrayBuffer, onLimit: () => void, onError: (message: string) => void): void {
    if (this.file === null) { return; }
    try {
      let left = RECORDING_MAX_SECONDS * 32000 - this.bytes;
      let block = data.slice(0, Math.min(data.byteLength, left));
      let written = 0;
      while (written < block.byteLength) {
        let count = fs.writeSync(this.file.fd, block.slice(written));
        if (count <= 0) { throw new Error('录音存储空间不足'); }
        written += count; this.bytes += count;
      }
      if (Date.now() - this.checkpoint >= 5000) {
        fs.lseek(this.file.fd, 0, fs.WhenceType.SEEK_SET);
        writeExact(this.file.fd, wavHeader(this.bytes));
        fs.lseek(this.file.fd, 44 + this.bytes, fs.WhenceType.SEEK_SET);
        fs.fsyncSync(this.file.fd); this.checkpoint = Date.now();
      }
      if (this.bytes >= RECORDING_MAX_SECONDS * 32000) { onLimit(); }
    } catch (e) { this.failure = (e as Error).message; onError(this.failure); }
  }
  stop(): Promise<number> {
    if (this.stopping !== null) { return this.stopping; }
    this.generation++;
    this.stopping = this.finish(); return this.stopping;
  }
  errorMessage(): string { return this.failure; }
  availableSamples(): number { return Math.floor(this.bytes / 2); }
  private async finish(): Promise<number> {
    let capturer = this.capturer; this.capturer = null;
    try {
      if (this.system !== null) {
        let system = this.system; this.system = null;
        try { await system.stop(); } catch (e) { this.failure = (e as Error).message; }
      }
      if (capturer !== null) {
        // Interruptions may already stop the capturer. Finalize the bytes we
        // actually captured even when stop/release reports an invalid state.
        try { await capturer.stop(); } catch (e) { }
        try { await capturer.release(); } catch (e) { }
      }
    } finally {
      let file = this.file; this.file = null;
      if (file !== null) {
        try { fs.lseek(file.fd, 0, fs.WhenceType.SEEK_SET); writeExact(file.fd, wavHeader(this.bytes)); fs.fsyncSync(file.fd); }
        finally { fs.closeSync(file); }
      }
    }
    return this.bytes / 32000;
  }
}
