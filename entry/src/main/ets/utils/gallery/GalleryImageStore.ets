import { image } from '@kit.ImageKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { AppLogger } from '../AppLogger';
import { DebugSettings } from '../DebugSettings';
import { SelfHdcTestRunner } from '../selfhdc/SelfHdcTestRunner';
import { GalleryStorage } from './GalleryStorage';
import { GalleryAnalysisResult, GalleryPhotoInput, GalleryScanItem, GalleryScanSession } from './GalleryTypes';
import { galleryHdcOwnedCopy, galleryHdcCanDiscardCopy, galleryHdcMediaPath,
  galleryHdcImageExtension, galleryImageDecodeSize } from './GalleryHdcPolicy';

// Display addresses and source references have different permissions and lifetimes.
export class GalleryImageStore {
  static report(message: string, error?: Error): void {
    if (!DebugSettings.isEnabled()) { return; }
    let detail = error ? message + ' error=' + error.message : message;
    if (error) { AppLogger.error('Gallery.Images', detail); } else { AppLogger.info('Gallery.Images', detail); }
    let previous = AppStorage.get<string>('galleryLogs') || '';
    AppStorage.setOrCreate('galleryLogs', (previous + '\n[' + new Date().toLocaleTimeString() + '] [Images] ' + detail).slice(-60000));
    let hub = SelfHdcTestRunner.shared();
    if (hub.snapshot().stage === '图库批量读图') { hub.recordExternal('GALLERY_IMAGE ' + detail); }
  }

  static displayUri(path: string): string {
    if (!path || galleryHdcMediaPath(path)) { return ''; }
    return path.startsWith('/') ? fileUri.getUriFromPath(path) : path;
  }

  static previewUri(result: GalleryAnalysisResult): string {
    return GalleryImageStore.displayUri(result.thumbnailUri || result.uri);
  }

  static exists(path: string): boolean {
    try { return fs.accessSync(path) && fs.statSync(path).size > 0; } catch (e) { return false; }
  }

  static localCopy(filesDir: string, result: GalleryAnalysisResult): string {
    if (galleryHdcOwnedCopy(filesDir, result.uri)) { return result.uri; }
    let source = result.hdcSourcePath || '';
    let candidate = GalleryStorage.rootDir(filesDir) + '/hdc-images/' + result.id + galleryHdcImageExtension(source);
    return galleryHdcOwnedCopy(filesDir, candidate) ? candidate : '';
  }

  static sourceInput(result: GalleryAnalysisResult): GalleryPhotoInput {
    return { uri: result.uri, id: result.id, date: result.date, hdcSourcePath: result.hdcSourcePath,
      hdcSourceSize: result.hdcSourceSize, hdcModifiedAt: result.hdcModifiedAt, hdcChecksum: result.hdcChecksum };
  }

  static async decode(path: string, maxEdge: number): Promise<image.PixelMap> {
    let file = await fs.open(path, fs.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(file.fd);
      let info = await source.getImageInfo();
      let size = galleryImageDecodeSize(info.size.width, info.size.height, maxEdge);
      return await source.createPixelMap({ desiredSize: { width: size.width, height: size.height } });
    } finally {
      try { if (source) { await source.release(); } }
      catch (e) { GalleryImageStore.report('IMAGE_SOURCE_RELEASE_FAILED', e as Error); }
      try { await fs.close(file); }
      catch (e) { GalleryImageStore.report('IMAGE_FILE_CLOSE_FAILED', e as Error); }
    }
  }

  private static thumbnailPath(filesDir: string, id: string): string {
    if (!/^gallery_hdc_[0-9a-f]{64}_[0-9a-f]{64}$/.test(id)) { throw new Error('GALLERY_THUMB_ID: 图片标识无效'); }
    return GalleryStorage.rootDir(filesDir) + '/thumbnails/' + id + '.jpg';
  }

  private static async thumbnail(filesDir: string, id: string, local: string, shouldStop: () => boolean): Promise<string> {
    let path = GalleryImageStore.thumbnailPath(filesDir, id);
    if (GalleryImageStore.exists(path)) {
      try {
        let check = await GalleryImageStore.decode(path, 16);
        await check.release();
        return path;
      } catch (e) { GalleryImageStore.report('THUMBNAIL_INVALID id=' + id, e as Error); }
    }
    let pixels = await GalleryImageStore.decode(local, 384);
    let packer = image.createImagePacker();
    try {
      let bytes = await packer.packing(pixels, { format: 'image/jpeg', quality: 80 });
      if (bytes.byteLength === 0) { throw new Error('GALLERY_THUMB_EMPTY: 缩略图编码结果为空'); }
      if (shouldStop()) { throw new Error('GALLERY_THUMB_CANCELLED: 已取消历史缩略图整理'); }
      GalleryStorage.ensureDirectory(GalleryStorage.rootDir(filesDir) + '/thumbnails');
      GalleryStorage.writeBytes(path + '.part', bytes);
      if (fs.statSync(path + '.part').size !== bytes.byteLength) { throw new Error('GALLERY_THUMB_WRITE: 缩略图写入不完整'); }
      fs.renameSync(path + '.part', path);
      GalleryImageStore.report('THUMBNAIL_SAVED id=' + id + ' bytes=' + bytes.byteLength);
      return path;
    } finally {
      try { await packer.release(); } finally { await pixels.release(); }
    }
  }

  // Used for new results, cache hits, and migration. A thumbnail failure never destroys the full copy.
  static async persist(filesDir: string, input: GalleryPhotoInput, result: GalleryAnalysisResult,
    shouldStop: () => boolean = (): boolean => false): Promise<GalleryAnalysisResult> {
    let source = input.hdcSourcePath || result.hdcSourcePath || '';
    if (galleryHdcMediaPath(source) && galleryHdcImageExtension(source)) {
      result.hdcSourcePath = source;
      result.hdcSourceSize = input.hdcSourceSize || result.hdcSourceSize;
      result.hdcModifiedAt = input.hdcModifiedAt || result.hdcModifiedAt;
      result.hdcChecksum = input.hdcChecksum || result.hdcChecksum;
    }
    let local = galleryHdcOwnedCopy(filesDir, input.uri) ? input.uri : GalleryImageStore.localCopy(filesDir, result);
    if (local || result.hdcSourcePath) {
      try {
        // Use the canonical private path, never trust a persisted arbitrary thumbnail as permission to delete.
        let thumbnail = await GalleryImageStore.thumbnail(filesDir, result.id, local, shouldStop);
        result.thumbnailUri = GalleryImageStore.displayUri(thumbnail);
        if (result.hdcSourcePath) { result.uri = result.hdcSourcePath; }
      } catch (e) {
        GalleryImageStore.report('THUMBNAIL_FAILED id=' + result.id, e as Error);
      }
    }
    if (shouldStop()) { return result; }
    let saved = GalleryStorage.writeResult(filesDir, result);
    let committed = GalleryStorage.loadResult(filesDir, saved.date, saved.id);
    if (!committed || committed.id !== saved.id || committed.uri !== saved.uri ||
      committed.thumbnailUri !== saved.thumbnailUri || committed.hdcSourcePath !== saved.hdcSourcePath ||
      committed.hdcChecksum !== saved.hdcChecksum || committed.hdcSourceSize !== saved.hdcSourceSize) {
      throw new Error('GALLERY_IMAGE_COMMIT: 图片引用保存校验失败，已保留完整副本');
    }
    GalleryImageStore.discardCopy(filesDir, local, saved);
    return saved;
  }

  static discardCopy(filesDir: string, path: string, saved: GalleryAnalysisResult): void {
    if (!galleryHdcOwnedCopy(filesDir, path)) { return; }
    let thumbnail = GalleryImageStore.thumbnailPath(filesDir, saved.id);
    if (!galleryHdcCanDiscardCopy(filesDir, path, saved.hdcSourcePath || '', thumbnail) ||
      saved.thumbnailUri !== GalleryImageStore.displayUri(thumbnail) || saved.uri !== saved.hdcSourcePath ||
      !Number.isSafeInteger(saved.hdcSourceSize || 0) || (saved.hdcSourceSize || 0) <= 0 ||
      !/^[0-9a-f]{64}$/.test(saved.hdcChecksum || '') || !GalleryImageStore.exists(thumbnail)) { return; }
    try {
      if (fs.accessSync(path)) { fs.unlinkSync(path); GalleryImageStore.report('FULL_COPY_REMOVED id=' + saved.id); }
    } catch (e) { GalleryImageStore.report('FULL_COPY_CLEANUP_FAILED id=' + saved.id, e as Error); }
  }

  static discardPreview(filesDir: string, path: string): void {
    if (!galleryHdcOwnedCopy(filesDir, path)) { return; }
    try { if (fs.accessSync(path)) { fs.unlinkSync(path); } }
    catch (e) { GalleryImageStore.report('PREVIEW_CLEANUP_FAILED', e as Error); }
  }

  static async migrateHistory(filesDir: string, session: GalleryScanSession | null,
    shouldStop: () => boolean, onResult: (result: GalleryAnalysisResult) => void): Promise<void> {
    let results = GalleryStorage.loadResults(filesDir);
    for (let result of results) {
      if (shouldStop()) { return; }
      if (!GalleryImageStore.localCopy(filesDir, result) && !result.hdcSourcePath) { continue; }
      if (/^gallery_hdc_[0-9a-f]{64}_[0-9a-f]{64}$/.test(result.id)) {
        let thumbnail = GalleryImageStore.thumbnailPath(filesDir, result.id);
        if (result.hdcSourcePath && result.uri === result.hdcSourcePath &&
          result.thumbnailUri === GalleryImageStore.displayUri(thumbnail) && GalleryImageStore.exists(thumbnail) &&
          !GalleryImageStore.exists(GalleryImageStore.localCopy(filesDir, result))) { continue; }
      }
      let input = GalleryImageStore.sourceInput(result);
      if (!input.hdcSourcePath && session) {
        let old = session.items.find((item: GalleryScanItem): boolean => item.id === result.id || item.uri === result.uri);
        if (old) {
          input.hdcSourcePath = old.hdcSourcePath; input.hdcSourceSize = old.hdcSourceSize;
          input.hdcModifiedAt = old.hdcModifiedAt; input.hdcChecksum = old.hdcChecksum;
        }
      }
      try {
        let saved = await GalleryImageStore.persist(filesDir, input, result, shouldStop);
        if (shouldStop()) { return; }
        if (session) {
          let old = session.items.find((item: GalleryScanItem): boolean => item.id === saved.id);
          if (old) { old.uri = saved.uri; old.thumbnailUri = saved.thumbnailUri; GalleryStorage.saveScanSession(filesDir, session); }
        }
        onResult(saved);
        GalleryImageStore.report('HISTORY_REPAIRED id=' + saved.id + ' sourceKnown=' + !!saved.hdcSourcePath);
      } catch (e) { GalleryImageStore.report('HISTORY_REPAIR_FAILED id=' + result.id, e as Error); }
    }
  }
}
