import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { AppLogger } from '../AppLogger';
import { DebugSettings } from '../DebugSettings';
import { AgentExecutionController } from '../AgentExecutionController';
import { encodeUtf8Compat } from '../TextEncodingCompat';
import { HdcClient } from '../selfhdc/HdcClient';
import { SelfHdcTaskSettings } from '../selfhdc/SelfHdcTaskSettings';
import { SelfHdcTestRunner } from '../selfhdc/SelfHdcTestRunner';
import { parseSelfHdcEndpoint, selfHdcShellQuote } from '../selfhdc/SelfHdcPolicy';
import {
  selfHdcEnsureDirectory, selfHdcWrite, selfHdcExists, selfHdcReadText, selfHdcWriteAtomicText
} from '../selfhdc/SelfHdcFiles';
import { GalleryPhotoInput } from './GalleryTypes';
import { GalleryStorage } from './GalleryStorage';
import {
  GALLERY_HDC_MEDIA_ROOT, GALLERY_HDC_CHUNK_BYTES, GalleryHdcEntry,
  galleryHdcListing, galleryHdcLatest, galleryHdcMediaPath, galleryHdcImageExtension,
  galleryHdcChunkSize, galleryHdcChecksum
} from './GalleryHdcPolicy';

interface GalleryHdcPendingExports { paths: string[]; }

// HDC commands are serialized; OCR/model work may overlap the next file transfer.
export class GalleryHdcReader {
  private context: common.UIAbilityContext;
  private shouldPause: () => boolean;
  private onProgress: (message: string) => void;
  private onCancel: () => void;
  private client: HdcClient | undefined = undefined;
  private hub: SelfHdcTestRunner = SelfHdcTestRunner.shared();
  private ownsLog: boolean = false;
  private operations: Promise<void> = Promise.resolve();
  private prepared: number = 0;
  private total: number = 0;
  private cacheRoot: string;

  constructor(context: common.UIAbilityContext, shouldPause: () => boolean,
    onProgress: (message: string) => void, onCancel: () => void) {
    this.context = context; this.shouldPause = shouldPause;
    this.onProgress = onProgress; this.onCancel = onCancel;
    this.cacheRoot = GalleryStorage.rootDir(context.filesDir) + '/hdc-images';
  }

  async open(title: string = '图库批量读图'): Promise<void> {
    if (AgentExecutionController.isExecutionActive()) { throw new Error('请先停止正在执行的手机任务，再批量读图'); }
    let settings = SelfHdcTaskSettings.load(this.context.filesDir);
    let endpoint = parseSelfHdcEndpoint(settings.ip, settings.port);
    this.hub.beginExternal(this.context.filesDir, title, endpoint.ip + ':' + endpoint.port,
      this.onCancel, 'phone-gallery');
    this.ownsLog = true;
    selfHdcEnsureDirectory(this.cacheRoot);
    this.log('STAGE_BEGIN gallery-connect');
    this.onProgress('正在连接本机 HDC…');
    await this.command('for t in mediatool dd base64 stat sha256sum; do command -v "$t" >/dev/null 2>&1 || ' +
      '{ printf "missing:%s\\n" "$t"; exit 1; }; done', 'tools');
    this.log('TOOLS_READY media export, chunk transfer, SHA256; no PC proxy');
    let pending = this.pendingExports();
    if (pending.length > 0) {
      this.log('STAGE_BEGIN gallery-cleanup pending=' + pending.length);
      await this.command('rm -f ' + pending.map((path: string): string => selfHdcShellQuote(path)).join(' '), 'old-export-cleanup');
      this.savePendingExports([]);
    }
  }

  private checkPause(): void {
    if (this.shouldPause()) { throw new Error('GALLERY_HDC_PAUSED: 已暂停读取'); }
  }

  private async connected(): Promise<HdcClient> {
    if (this.client !== undefined) { return this.client; }
    this.checkPause();
    let settings = SelfHdcTaskSettings.load(this.context.filesDir);
    let endpoint = parseSelfHdcEndpoint(settings.ip, settings.port);
    let client = new HdcClient((event: string): void => { this.log(event); });
    this.client = client;
    try { await client.connect(endpoint.ip, endpoint.port, this.context.filesDir); }
    catch (e) { client.close(); this.client = undefined; throw e as Error; }
    return client;
  }

  private async command(command: string, stage: string): Promise<string> {
    this.checkPause();
    let client = await this.connected();
    this.checkPause();
    try {
      // Filenames and Base64 payloads are never included in protocol diagnostics.
      let result = await client.shell(command, 30000, true, true);
      if (result.exitCode !== 0 || /^\s*(\[fail|error:|permission denied)/im.test(result.output)) {
        let missing = /missing:([a-z0-9_]+)/i.exec(result.output);
        throw new Error('GALLERY_HDC_COMMAND: ' + stage + ' exit=' + result.exitCode +
          (missing ? ' missing=' + missing[1] : '') + '；请确认无线调试连接及设备命令支持情况');
      }
      return result.output;
    } catch (e) {
      client.close(); this.client = undefined;
      this.log('COMMAND_FAILED stage=' + stage + ' error=' + (e as Error).message);
      throw e as Error;
    }
  }

  async latestImages(count: number): Promise<GalleryPhotoInput[]> {
    this.log('STAGE_BEGIN gallery-list requested=' + count + ' sort=file-modified-time');
    let directories: string[] = [GALLERY_HDC_MEDIA_ROOT];
    let seen: Record<string, boolean> = {};
    let entries: GalleryHdcEntry[] = [];
    for (let index = 0; index < directories.length; index++) {
      this.checkPause();
      if (index >= 4096 || entries.length > 100000) {
        throw new Error('GALLERY_HDC_LIST_LIMIT: 图库目录过大，请改用“选择图片”');
      }
      let path = directories[index];
      if (seen[path]) { continue; }
      seen[path] = true;
      let output = await this.command('mediatool ls -l ' + selfHdcShellQuote(path), 'media-list');
      let children = galleryHdcListing(path, output);
      for (let entry of children) {
        if (entry.directory) { directories.push(entry.path); }
        else { entries.push(entry); }
      }
      this.onProgress('正在扫描图片目录 ' + (index + 1) + '/' + directories.length + '，已发现 ' + entries.length + ' 个文件');
    }
    let selected = galleryHdcLatest(entries, count, Date.now());
    if (selected.length === 0) { throw new Error('GALLERY_HDC_EMPTY: 未找到可读取的本地图片'); }
    let bytes = selected.reduce((sum: number, entry: GalleryHdcEntry): number => sum + entry.size, 0);
    if (!Number.isSafeInteger(bytes) || bytes > 1024 * 1024 * 1024) {
      throw new Error('本批原图总大小超过 1 GiB，请减少读取数量');
    }
    let inputs: GalleryPhotoInput[] = [];
    for (let entry of selected) {
      this.checkPause();
      let id = 'gallery_hdc_' + await this.hashText(entry.path + '\0' + entry.modifiedAt);
      inputs.push({ uri: this.cacheRoot + '/' + id + '.pending', id: id,
        date: GalleryStorage.formatDate(entry.modifiedAt), hdcSourcePath: entry.path,
        hdcSourceSize: entry.size, hdcModifiedAt: entry.modifiedAt });
    }
    this.total = inputs.length;
    this.log('SELECT requested=' + count + ' selected=' + inputs.length + ' bytes=' + bytes +
      ' sort=file-modified-time; hidden/cloud-only assets excluded');
    return inputs;
  }

  async prepareImage(input: GalleryPhotoInput, forceRefresh: boolean = false): Promise<void> {
    let pending = this.operations.then(async (): Promise<void> => { await this.readImage(input, forceRefresh); });
    this.operations = pending.catch((): void => {});
    await pending;
  }

  private async readImage(input: GalleryPhotoInput, forceRefresh: boolean): Promise<void> {
    this.checkPause();
    let source = input.hdcSourcePath || '';
    let size = input.hdcSourceSize || 0;
    if (!galleryHdcMediaPath(source) || !galleryHdcImageExtension(source)) {
      throw new Error('GALLERY_HDC_PATH: 批次中的图片源路径无效');
    }
    galleryHdcChunkSize(size, 0);
    let sourceId = 'gallery_hdc_' + await this.hashText(source + '\0' + (input.hdcModifiedAt || 0));
    let extension = galleryHdcImageExtension(source);
    // A resumed batch reads its verified immutable snapshot, even if the original has since changed.
    if (!forceRefresh && input.hdcChecksum && /^[0-9a-f]{64}$/.test(input.hdcChecksum) &&
      input.uri === this.cacheRoot + '/' + sourceId + '_' + input.hdcChecksum + extension &&
      this.hasFile(input.uri, size)) {
      input.id = sourceId + '_' + input.hdcChecksum;
      this.log('READ_RESUME_CACHE id=' + input.id);
      return;
    }
    let remote = '/data/local/tmp/clawmate_gallery_' + util.generateRandomUUID(true).replace(/-/g, '') + '.img';
    let localPart = '';
    try {
      this.onProgress('正在读取第 ' + (++this.prepared) + ' 张原图' + (this.total > 0 ? ' / ' + this.total : ''));
      this.log('STAGE_BEGIN gallery-export item=' + this.prepared + ' bytes=' + size);
      let pending = this.pendingExports();
      pending.push(remote);
      this.savePendingExports(pending);
      await this.command('mediatool recv ' + selfHdcShellQuote(source) + ' ' + selfHdcShellQuote(remote), 'media-export');
      let actualSize = Number((await this.command('stat -c %s ' + selfHdcShellQuote(remote), 'export-size')).trim());
      if (actualSize !== size) { throw new Error('GALLERY_HDC_CHANGED: 原图大小已变化，请重新选择批量读图'); }
      let digest = galleryHdcChecksum(await this.command('sha256sum ' + selfHdcShellQuote(remote), 'export-hash'));
      let id = sourceId + '_' + digest;
      let local = this.cacheRoot + '/' + id + extension;
      if (forceRefresh || !this.hasFile(local, size)) {
        localPart = local + '.part';
        selfHdcWrite(localPart, new Uint8Array(0));
        let md = cryptoFramework.createMd('SHA256');
        for (let index = 0; index * GALLERY_HDC_CHUNK_BYTES < size; index++) {
          this.checkPause();
          let expected = galleryHdcChunkSize(size, index);
          let encoded = (await this.command('dd if=' + selfHdcShellQuote(remote) + ' bs=' + GALLERY_HDC_CHUNK_BYTES +
            ' skip=' + index + ' count=1 2>/dev/null | base64', 'image-chunk')).replace(/\s/g, '');
          if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length !== Math.ceil(expected / 3) * 4) {
            throw new Error('GALLERY_HDC_CHUNK: 原图分块长度不符，未将不完整图片交给模型');
          }
          let chunk = new util.Base64Helper().decodeSync(encoded);
          if (chunk.length !== expected) { throw new Error('GALLERY_HDC_CHUNK: 原图分块解码长度不符'); }
          await md.update({ data: chunk });
          selfHdcWrite(localPart, chunk, true);
          let received = Math.min(size, (index + 1) * GALLERY_HDC_CHUNK_BYTES);
          this.onProgress('读取第 ' + this.prepared + ' 张原图 ' + Math.floor(received * 100 / size) + '%');
        }
        let actual = this.hex((await md.digest()).data);
        if (actual !== digest || !this.hasFile(localPart, size)) {
          throw new Error('GALLERY_HDC_HASH: 原图校验失败，未进入分析');
        }
        fs.renameSync(localPart, local);
        localPart = '';
      }
      input.uri = local; input.id = id; input.hdcChecksum = digest;
      this.log('READ_VERIFIED id=' + id + ' bytes=' + size + ' SHA256=' + digest);
    } finally {
      if (localPart) { try { fs.unlinkSync(localPart); } catch (e) { /* Our partial cache only. */ } }
      // Only remove the export created by this reader, never a source photo or media directory.
      let client = this.client;
      if (client) {
        try {
          let result = await client.shell('rm -f ' + selfHdcShellQuote(remote), 10000, true, true);
          if (result.exitCode !== 0) { this.log('CLEANUP_PENDING remote=' + remote); }
          else { this.savePendingExports(this.pendingExports().filter((path: string): boolean => path !== remote)); }
        } catch (e) { this.log('CLEANUP_PENDING remote=' + remote); client.close(); this.client = undefined; }
      } else { this.log('CLEANUP_PENDING remote=' + remote); }
    }
  }

  private hasFile(path: string, size: number): boolean {
    try { return fs.accessSync(path) && fs.statSync(path).size === size; } catch (e) { return false; }
  }

  private pendingExports(): string[] {
    let path = this.context.filesDir + '/self_hdc/gallery-pending-exports.json';
    if (!selfHdcExists(path)) { return []; }
    let saved = ArkJSON.parse(selfHdcReadText(path, 256 * 1024)) as GalleryHdcPendingExports;
    if (!Array.isArray(saved.paths) || saved.paths.length > 1000 || saved.paths.some((item: string): boolean =>
      typeof item !== 'string' || !/^\/data\/local\/tmp\/clawmate_gallery_[0-9a-f]{32}\.img$/.test(item))) {
      throw new Error('GALLERY_HDC_CLEANUP: 暂存清理记录无效，未执行文件删除');
    }
    return saved.paths;
  }

  private savePendingExports(paths: string[]): void {
    let saved: GalleryHdcPendingExports = { paths: paths };
    selfHdcWriteAtomicText(this.context.filesDir + '/self_hdc/gallery-pending-exports.json', ArkJSON.stringify(saved));
  }

  private async hashText(text: string): Promise<string> {
    let md = cryptoFramework.createMd('SHA256');
    await md.update({ data: encodeUtf8Compat(text) });
    return this.hex((await md.digest()).data);
  }

  private hex(bytes: Uint8Array): string {
    return Array.from(bytes).map((value: number): string => value.toString(16).padStart(2, '0')).join('');
  }

  note(message: string): void { this.log(message); }

  pause(): void {
    // Interrupt authentication/a chunk immediately. Export cleanup is retried from the owned-path manifest next time.
    if (this.client) { this.client.close(); this.client = undefined; }
  }

  finish(outcome: string, message: string): void {
    if (this.client) { this.client.close(); this.client = undefined; }
    if (this.ownsLog) { this.hub.finishExternal(outcome, message); this.ownsLog = false; }
  }

  private log(message: string): void {
    AppLogger.info('Gallery.Hdc', message);
    if (this.ownsLog) { this.hub.recordExternal('GALLERY ' + message); }
    if (!DebugSettings.isEnabled()) { return; }
    let previous = AppStorage.get<string>('galleryLogs') || '';
    AppStorage.setOrCreate('galleryLogs', (previous + '\n[' + new Date().toLocaleTimeString() + '] [HDC] ' + message).slice(-60000));
  }
}
