import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class RecordingPlayback {
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;
  private epoch: number = 0;
  async play(path: string, start: number, end: number, onEnd: () => void, onError: (message: string) => void): Promise<void> {
    await this.stop(); let epoch = ++this.epoch;
    let file = await fs.open(path, fs.OpenMode.READ_ONLY);
    if (epoch !== this.epoch) { await fs.close(file); return; }
    this.file = file;
    let player: media.AVPlayer;
    try { player = await media.createAVPlayer(); }
    catch (e) { if (epoch === this.epoch) { await this.stop(); } throw new Error((e as Error).message); }
    if (epoch !== this.epoch) { await player.release(); return; }
    this.player = player;
    let complete = (): void => { if (epoch === this.epoch) { onEnd(); this.stop().catch((): void => {}); } };
    player.on('stateChange', async (state: string): Promise<void> => {
      if (epoch !== this.epoch) { return; }
      try {
        if (state === 'initialized') { await player.prepare(); }
        if (state === 'prepared') {
          if (start > 0) { player.seek(Math.floor(start * 1000), media.SeekMode.SEEK_CLOSEST); }
          await player.play();
        }
        if (state === 'completed') { complete(); }
      } catch (e) { if (epoch === this.epoch) { onError((e as Error).message); complete(); } }
    });
    player.on('timeUpdate', (time: number): void => { if (end > 0 && time >= end * 1000) { complete(); } });
    player.on('error', (error: BusinessError): void => {
      if (epoch === this.epoch) { onError(error.message); complete(); }
    });
    player.fdSrc = { fd: file.fd, offset: 0, length: fs.statSync(file.fd).size };
  }
  async stop(): Promise<void> {
    this.epoch++; let player = this.player; let file = this.file; this.player = null; this.file = null;
    try { if (player !== null) { await player.release(); } }
    finally { if (file !== null) { await fs.close(file); } }
  }
}
