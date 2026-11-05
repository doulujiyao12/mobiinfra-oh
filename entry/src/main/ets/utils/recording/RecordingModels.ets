import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { request } from '@kit.BasicServicesKit';
import { JSON as ArkJSON, url } from '@kit.ArkTS';

export interface RecordingModelFile { name: string; label: string; url: string; sha256: string; bytes: number; }
export interface RecordingModelProgress { percent: number; preparedBytes: number; totalBytes: number; }
export const DEFAULT_RECORDING_MODEL_URL: string =
  'https://modelscope.cn/models/fengerhu1/recording-analysis-models/resolve/master';
const RECORDING_MODEL_USER_AGENT: string = 'ClawMate/1.0 (HarmonyOS; recording models)';

export function recordingModelBaseUrl(value: string): string {
  let text = value.trim();
  if (!/^https?:\/\//i.test(text) || /\s/.test(text)) { throw new Error('请填写完整的 HTTP 或 HTTPS 模型目录地址'); }
  let parsed: url.URL;
  try { parsed = url.URL.parseURL(text); }
  catch (e) { throw new Error('模型下载地址格式不正确'); }
  if (!parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('请填写模型目录地址，不要包含账号、查询参数或页面锚点');
  }
  let path = parsed.pathname.replace(/\/+$/, '');
  if ((parsed.hostname === 'modelscope.cn' || parsed.hostname === 'www.modelscope.cn') &&
    /^\/models\/[^/]+\/[^/]+(?:\/files)?$/.test(path)) {
    path = path.replace(/\/files$/, '') + '/resolve/master';
  }
  return parsed.origin + path;
}

export function recordingModelDownloadUrl(baseUrl: string, model: RecordingModelFile): string {
  return recordingModelBaseUrl(baseUrl) + '/' + model.name;
}

// Keep upstream references for provenance; downloads use the configured directory and local filenames.
const HF: string = 'https://huggingface.co/csukuangfj/';
export const RECORDING_MODELS: RecordingModelFile[] = [
  { name: 'sensevoice.int8.onnx', label: '多语种转写', bytes: 239233841,
    url: HF + 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
    sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' },
  { name: 'tokens.txt', label: '多语种词表', bytes: 315894,
    url: HF + 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
    sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' },
  { name: 'silero_vad.onnx', label: '人声检测', bytes: 643854,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6' },
  { name: 'segmentation.int8.onnx', label: '说话人分段', bytes: 1540506,
    url: HF + 'sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.int8.onnx',
    sha256: 'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d' },
  { name: 'speaker.onnx', label: '声纹特征', bytes: 39593761,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/' +
      '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
    sha256: '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b' }
];
interface ModelReceipt { name: string; sha256: string; bytes: number; }
interface ModelDownloadSettings { baseUrl: string; }
export function recordingRequiredModels(diarization: boolean): RecordingModelFile[] {
  return diarization ? RECORDING_MODELS : RECORDING_MODELS.filter((model: RecordingModelFile): boolean =>
    model.name !== 'speaker.onnx' && model.name !== 'segmentation.int8.onnx');
}
export class RecordingModels {
  private static preparing: boolean = false;
  readonly directory: string;
  private cancelled: boolean = false;
  private task: request.DownloadTask | null = null;
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.directory = context.filesDir + '/recording-models';
    if (!fs.accessSync(this.directory)) { fs.mkdirSync(this.directory, true); }
  }
  downloadBaseUrl(): string {
    let path = this.directory + '/download-source.json';
    if (fs.accessSync(path)) {
      try {
        let settings = ArkJSON.parse(fs.readTextSync(path)) as ModelDownloadSettings;
        if (typeof settings.baseUrl === 'string') { return recordingModelBaseUrl(settings.baseUrl); }
      } catch (e) { /* Fall back to the bundled source if saved settings are invalid. */ }
    }
    return DEFAULT_RECORDING_MODEL_URL;
  }
  setDownloadBaseUrl(value: string): string {
    let baseUrl = recordingModelBaseUrl(value);
    let settings: ModelDownloadSettings = { baseUrl: baseUrl };
    let path = this.directory + '/download-source.json';
    let temp = path + '.tmp';
    let file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, ArkJSON.stringify(settings)); } finally { fs.closeSync(file); }
    fs.renameSync(temp, path);
    return baseUrl;
  }
  readyForTranscription(diarization: boolean): boolean {
    return this.readyCount(diarization) === recordingRequiredModels(diarization).length;
  }
  readyCount(diarization: boolean = true): number {
    return recordingRequiredModels(diarization).filter((model: RecordingModelFile): boolean => {
      let path = this.directory + '/' + model.name;
      if (!fs.accessSync(path) || !fs.accessSync(path + '.json')) { return false; }
      try {
        let receipt = ArkJSON.parse(fs.readTextSync(path + '.json')) as ModelReceipt;
        return receipt.name === model.name && receipt.bytes === fs.statSync(path).size &&
          (model.sha256.length === 0 || receipt.sha256 === model.sha256);
      } catch (e) { return false; }
    }).length;
  }
  cancel(): void {
    this.cancelled = true;
    if (this.task !== null) { this.task.delete().catch((): void => {}); }
  }
  private checkCancelled(): void { if (this.cancelled) { throw new Error('已停止模型准备'); } }
  private async hash(path: string): Promise<string> {
    let md = cryptoFramework.createMd('SHA256'); let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let size = fs.statSync(file.fd).size;
      for (let offset = 0; offset < size;) {
        this.checkCancelled();
        let block = new ArrayBuffer(Math.min(1024 * 1024, size - offset));
        let n = await fs.read(file.fd, block, { length: block.byteLength });
        if (n <= 0) { throw new Error('模型文件读取不完整'); }
        await md.update({ data: new Uint8Array(block, 0, n) }); offset += n;
      }
      let digest = await md.digest(); let hex = '';
      for (let b of digest.data) { hex += b.toString(16).padStart(2, '0'); }
      return hex;
    } finally { fs.closeSync(file); }
  }
  private async accept(temp: string, model: RecordingModelFile, digest: string): Promise<void> {
    this.checkCancelled();
    let size = fs.statSync(temp).size;
    if (model.sha256.length > 0 && digest !== model.sha256) { throw new Error(model.label + '校验失败，请重新下载'); }
    if (model.name === 'tokens.txt') {
      if (size < 200000 || size > 1000000) { throw new Error('词表大小不正确'); }
      let tokens = fs.readTextSync(temp);
      if (!tokens.startsWith('<unk> 0\n') || tokens.trim().split('\n').length !== 25055) { throw new Error('词表与 SenseVoice 模型不匹配'); }
    }
    let path = this.directory + '/' + model.name;
    fs.renameSync(temp, path);
    let receipt: ModelReceipt = { name: model.name, sha256: digest, bytes: size };
    let file = fs.openSync(path + '.json', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, ArkJSON.stringify(receipt)); } finally { fs.closeSync(file); }
  }
  private async download(url: string, path: string, report: (text: string) => void,
    onBytes: (received: number) => void = (): void => {}): Promise<void> {
    if (fs.accessSync(path)) { fs.unlinkSync(path); }
    // ModelScope rejects the system downloader's default User-Agent with HTTP 403 (UA ACL).
    let headers: Record<string, string> = { 'User-Agent': RECORDING_MODEL_USER_AGENT, 'Accept': '*/*' };
    let task = await request.downloadFile(this.context, { url: url, filePath: path, header: headers }); this.task = task;
    try {
      await new Promise<void>((resolve, reject) => {
        let done = false;
        let timer = setTimeout((): void => {
          if (!done) { done = true; task.delete().catch((): void => {}); reject(new Error('下载超时，可重试或导入模型文件')); }
        }, 10 * 60 * 1000);
        task.on('progress', (received: number, total: number): void => {
          if (done || this.cancelled || !Number.isFinite(received) || received < 0) { return; }
          onBytes(received);
          report((received / 1048576).toFixed(1) + ' MB' + (total > 0 ? ' / ' + (total / 1048576).toFixed(1) + ' MB' : ''));
        });
        task.on('complete', (): void => { if (!done) { done = true; clearTimeout(timer); resolve(); } });
        task.on('fail', (code: number): void => {
          if (!done) {
            done = true; clearTimeout(timer);
            let hint = code === request.ERROR_INSUFFICIENT_SPACE ? '请释放手机存储空间' :
              '请检查网络或更换模型下载地址，也可导入模型文件';
            reject(new Error('下载失败（' + code + '），' + hint));
          }
        });
        task.on('remove', (): void => { if (!done) { done = true; clearTimeout(timer); reject(new Error('已停止下载')); } });
        if (this.cancelled) { task.delete().catch((): void => {}); }
      });
    } finally { this.task = null; }
  }
  async prepare(report: (text: string) => void, baseUrl: string = this.downloadBaseUrl(),
    onProgress: (value: RecordingModelProgress) => void = (): void => {}): Promise<void> {
    let source = recordingModelBaseUrl(baseUrl);
    if (RecordingModels.preparing) { throw new Error('另一项模型准备尚未结束，请稍后重试'); }
    RecordingModels.preparing = true;
    this.cancelled = false;
    const total = RECORDING_MODELS.reduce((sum: number, model: RecordingModelFile): number => sum + model.bytes, 0);
    let completed = 0; let highWater = 0;
    let publish = (pending: number, ready: boolean = false): void => {
      highWater = Math.max(highWater, Math.min(total, completed + pending));
      let value: RecordingModelProgress = { percent: ready ? 100 : Math.min(99, Math.floor(highWater * 100 / total)),
        preparedBytes: highWater, totalBytes: total };
      onProgress(value);
    };
    try {
      publish(0);
      for (let model of RECORDING_MODELS) {
        this.checkCancelled();
        // Rehash existing files when explicitly preparing; size receipts alone never bless an import.
        let path = this.directory + '/' + model.name;
        if (fs.accessSync(path)) {
          report('正在检查 · ' + model.label);
          let digest = await this.hash(path);
          if (model.sha256.length > 0 && digest === model.sha256) {
            let receipt: ModelReceipt = { name: model.name, sha256: digest, bytes: fs.statSync(path).size };
            let f = fs.openSync(path + '.json', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
            try { fs.writeSync(f.fd, ArkJSON.stringify(receipt)); } finally { fs.closeSync(f); }
            completed += model.bytes; publish(0);
            continue;
          }
        }
        let temp = this.directory + '/' + model.name + '.part';
        try {
          report('正在连接 · ' + model.label);
          await this.download(recordingModelDownloadUrl(source, model), temp,
            (text: string): void => { report(model.label + ' · ' + text); },
            (received: number): void => { publish(Math.min(model.bytes, received)); });
          publish(Math.min(model.bytes, fs.statSync(temp).size));
          report('正在校验' + model.label);
          await this.accept(temp, model, await this.hash(temp));
          completed += model.bytes; publish(0);
        } catch (e) {
          throw new Error(model.label + '：' + (e as Error).message);
        } finally { if (fs.accessSync(temp)) { fs.unlinkSync(temp); } }
      }
      this.checkCancelled(); publish(0, true);
    } finally { RecordingModels.preparing = false; }
  }
  async importFiles(report: (text: string) => void, onSelected: () => void = (): void => {}): Promise<void> {
    if (RecordingModels.preparing) { throw new Error('另一项模型准备尚未结束，请稍后重试'); }
    RecordingModels.preparing = true;
    this.cancelled = false;
    try {
      let options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 8;
      let uris = await new picker.DocumentViewPicker(this.context).select(options);
      onSelected();
      for (let uri of uris) {
        this.checkCancelled(); report('校验并导入模型文件');
        let file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        try {
          let size = fs.statSync(file.fd).size;
          if (size <= 0 || size > 300 * 1048576) { throw new Error('模型文件大小不正确'); }
          let digest = await this.hash(uri);
          let model = RECORDING_MODELS.find((item: RecordingModelFile): boolean => item.sha256 === digest);
          if (model === undefined && size < 1000000 && decodeURIComponent(uri).endsWith('tokens.txt')) {
            model = RECORDING_MODELS[1];
          }
          if (model === undefined) { throw new Error('文件不属于本页支持的 SenseVoice 模型组合'); }
          let temp = this.directory + '/' + model.name + '.part';
          await fs.copyFile(file.fd, temp);
          try { await this.accept(temp, model, digest); }
          finally { if (fs.accessSync(temp)) { fs.unlinkSync(temp); } }
        } finally { fs.closeSync(file); }
      }
    } finally { RecordingModels.preparing = false; }
  }
}
