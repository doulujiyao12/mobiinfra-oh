import native from 'libentry.so';
import { AiServiceAccess } from './AiServiceAccess';

export interface LocalTextModel { identity: string; name: string; }
export interface LocalTextProvider { prepare: () => Promise<LocalTextModel>; openDownload: () => void; }

// Model selection/loading remains owned by Index. Feature pages borrow the
// same model with an independent native context and cancellation signal.
export class LocalTextInference {
  private static provider: LocalTextProvider | null = null;
  private static occupied: boolean = false;
  static configure(provider: LocalTextProvider | null): void { LocalTextInference.provider = provider; }
  static isBusy(): boolean { return LocalTextInference.occupied; }
  static openDownload(): void { LocalTextInference.provider?.openDownload(); }
  static async acquire(): Promise<LocalTextSession> {
    AiServiceAccess.requireAllowed();
    if (LocalTextInference.occupied || native.isChatRunning()) { throw new Error('本地模型正在使用，请稍后重试'); }
    let provider = LocalTextInference.provider;
    if (provider === null) { throw new Error('本地模型尚未就绪，请返回首页后重试'); }
    LocalTextInference.occupied = true;
    try { return new LocalTextSession(await provider.prepare()); }
    catch (e) { LocalTextInference.release(); throw new Error((e as Error).message || String(e)); }
  }
  static release(): void { LocalTextInference.occupied = false; }
}

export class LocalTextSession {
  readonly model: LocalTextModel;
  private closed: boolean = false;
  private cancelled: boolean = false;
  private pending: boolean = false;
  private released: boolean = false;
  constructor(model: LocalTextModel) { this.model = model; }
  async generate(prompt: string, onToken: (text: string) => void): Promise<string> {
    if (this.closed || this.cancelled) { throw new Error('摘要已停止'); }
    if (this.pending) { throw new Error('上一段摘要尚未完成'); }
    this.pending = true;
    try {
      let result = await native.completeText(prompt, 768, onToken);
      if (this.cancelled) { throw new Error('摘要已停止'); }
      return result;
    } catch (e) { throw new Error((e as Error).message || String(e)); }
    finally { this.pending = false; if (this.closed) { this.release(); } }
  }
  cancel(): void { this.cancelled = true; if (this.pending) { native.cancelText(); } }
  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    if (this.pending) { this.cancel(); } else { this.release(); }
  }
  private release(): void { if (!this.released) { this.released = true; LocalTextInference.release(); } }
}
