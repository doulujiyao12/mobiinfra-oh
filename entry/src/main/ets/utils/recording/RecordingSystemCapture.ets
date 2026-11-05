import native, { RecordingScreenBatch } from 'libentry.so';
import { RecordingAudioMixer } from './RecordingAudioSource';
import { AppLogger } from '../AppLogger';

function systemAudioError(value: string): string {
  if (value.includes('CANCELLED')) { return '已取消系统声音录制授权'; }
  if (value.includes('AUTH_TIMEOUT')) { return '等待系统录音授权超时，请重试'; }
  if (value.includes('PROTECTED')) { return '当前内容受系统保护，已结束录音并保留已录内容'; }
  if (value.includes('MIC_UNAVAILABLE')) { return '麦克风不可用或已被关闭，混合录音已结束'; }
  if (value.includes('BUFFER_OVERFLOW')) { return '音频处理未能及时跟上，已结束录音并保留已录内容'; }
  return '系统声音录制失败（' + value + '），请检查系统授权和其他应用的录音占用';
}
export class RecordingSystemCapture {
  private timer: number = -1;
  private mixer: RecordingAudioMixer = new RecordingAudioMixer(false);
  private stopping: Promise<void> | null = null;
  private write: (buffer: ArrayBuffer) => void = (): void => {};
  async start(mixed: boolean, write: (buffer: ArrayBuffer) => void, onStop: () => void,
    onError: (message: string) => void): Promise<void> {
    this.mixer = new RecordingAudioMixer(mixed); this.stopping = null; this.write = write;
    try { await native.startRecordingScreen(mixed); }
    catch (e) { throw new Error(systemAudioError((e as Error).message)); }
    if (this.stopping !== null) { await this.stopping; throw new Error('已取消声音录制'); }
    this.timer = setInterval((): void => {
      if (this.stopping !== null) { return; }
      try {
        let batch = native.readRecordingScreen(); this.consume(batch, false);
        if (batch.error) { onError(systemAudioError(batch.error)); }
        else if (batch.stopped) { onStop(); }
      } catch (e) { onError((e as Error).message); }
    }, 40);
  }
  private consume(batch: RecordingScreenBatch, final: boolean): void {
    this.mixer.append(batch.frames); this.mixer.advance(batch.elapsedMs);
    this.reportTiming();
    if (!final) { this.mixer.drain(false, this.write); }
  }
  private reportTiming(): void {
    let notice = this.mixer.takeNotice();
    if (notice) { AppLogger.warn('RecordingAudio', notice); }
  }
  stop(): Promise<void> {
    if (this.stopping !== null) { return this.stopping; }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    this.stopping = this.finish(); return this.stopping;
  }
  private async finish(): Promise<void> {
    let batch = await native.stopRecordingScreen(); let failure = '';
    try { this.consume(batch, true); } catch (e) { failure = (e as Error).message; }
    // Preserve valid pending audio even if the last native batch was invalid.
    while (this.mixer.drain(true, this.write)) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
    }
    this.reportTiming();
    if (failure) { throw new Error(failure); }
  }
}
