// Pure parsing/selection rules. Media mtimes are not MediaLibrary DATE_ADDED or EXIF capture times.
export const GALLERY_HDC_MEDIA_ROOT: string = '/storage/media/local/files/Photo';
export const GALLERY_HDC_MAX_COUNT: number = 500;
export const GALLERY_HDC_CHUNK_BYTES: number = 256 * 1024;
export const GALLERY_HDC_MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;

export interface GalleryHdcEntry {
  path: string;
  directory: boolean;
  size: number;
  modifiedAt: number;
}

export function galleryHdcCount(text: string): number {
  if (!/^\d{1,3}$/.test(text.trim())) { throw new Error('请输入 1–500 之间的整数'); }
  let count = Number(text.trim());
  if (count < 1 || count > GALLERY_HDC_MAX_COUNT) { throw new Error('每批可读取 1–500 张图片'); }
  return count;
}

export function galleryHdcMediaPath(path: string): boolean {
  return (path === GALLERY_HDC_MEDIA_ROOT || path.startsWith(GALLERY_HDC_MEDIA_ROOT + '/')) &&
    !/[\x00-\x1f\x7f]/.test(path) && !path.split('/').some((part: string): boolean => part === '..' || part === '.');
}

export function galleryHdcImageExtension(path: string): string {
  let match = /\.(jpe?g|png|webp|heic|heif|avif|bmp|gif|dng)$/i.exec(path);
  return match ? '.' + match[1].toLowerCase() : '';
}

export function galleryHdcListing(parent: string, output: string): GalleryHdcEntry[] {
  if (!galleryHdcMediaPath(parent)) { throw new Error('GALLERY_HDC_PATH: 媒体目录不合法'); }
  let entries: GalleryHdcEntry[] = [];
  for (let raw of output.split(/\r?\n/)) {
    let line = raw.trim();
    if (!line || /^total\s+\d+$/i.test(line) || /^Table Name:/.test(line)) { continue; }
    // Never follow symlinks out of the media directory.
    if (line.startsWith('l')) { continue; }
    let match = /^([d-][rwxstST-]{9}[+.@]?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+(.+)$/.exec(line);
    if (!match) {
      // Include the column shape, not the potentially private filename or full command output.
      throw new Error('GALLERY_HDC_LIST_FORMAT: 无法解析设备媒体目录；字段前缀=' + line.split(/\s+/).slice(0, 7).join(' '));
    }
    let name = match[9];
    if (name === '.' || name === '..' || name.startsWith('.')) { continue; }
    if (name.indexOf('/') >= 0) { throw new Error('GALLERY_HDC_PATH: 媒体文件名包含非法路径'); }
    let path = parent + '/' + name;
    if (!galleryHdcMediaPath(path)) { throw new Error('GALLERY_HDC_PATH: 媒体文件路径不合法'); }
    let year = Number(match[3]); let month = Number(match[4]); let day = Number(match[5]);
    let hour = Number(match[6]); let minute = Number(match[7]); let second = Number(match[8] || '0');
    // The filename is the ninth capture group (including filenames containing spaces).
    let date = new Date(year, month - 1, day, hour, minute, second);
    let valid = year >= 1980 && month >= 1 && month <= 12 && day >= 1 && hour < 24 && minute < 60 && second < 60 &&
      date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day;
    entries.push({ path: path, directory: match[1].startsWith('d'), size: Number(match[2]),
      modifiedAt: valid ? date.getTime() : 0 });
  }
  return entries;
}

export function galleryHdcLatest(entries: GalleryHdcEntry[], count: number, now: number): GalleryHdcEntry[] {
  galleryHdcCount(String(count));
  let images: GalleryHdcEntry[] = [];
  let seen: Record<string, boolean> = {};
  for (let entry of entries) {
    if (entry.directory || !galleryHdcImageExtension(entry.path)) { continue; }
    if (!galleryHdcMediaPath(entry.path)) { throw new Error('GALLERY_HDC_PATH: 图片路径不合法'); }
    if (!Number.isFinite(entry.modifiedAt) || entry.modifiedAt <= 0 || entry.modifiedAt > now + 86400000) {
      throw new Error('GALLERY_HDC_TIME: 设备未提供可信的文件修改时间，无法确定最近 N 张。请改用“选择图片”');
    }
    if (!seen[entry.path]) { images.push(entry); seen[entry.path] = true; }
  }
  images.sort((left: GalleryHdcEntry, right: GalleryHdcEntry): number => {
    if (left.modifiedAt !== right.modifiedAt) { return right.modifiedAt - left.modifiedAt; }
    return left.path < right.path ? -1 : (left.path === right.path ? 0 : 1);
  });
  return images.slice(0, count);
}

export function galleryHdcChunkSize(size: number, index: number): number {
  if (!Number.isSafeInteger(size) || size <= 0 || size > GALLERY_HDC_MAX_IMAGE_BYTES ||
    !Number.isSafeInteger(index) || index < 0 || index * GALLERY_HDC_CHUNK_BYTES >= size) {
    throw new Error('GALLERY_HDC_SIZE: 图片为空、超过 64 MiB 或分块位置无效');
  }
  return Math.min(GALLERY_HDC_CHUNK_BYTES, size - index * GALLERY_HDC_CHUNK_BYTES);
}

export function galleryHdcChecksum(output: string): string {
  let match = /^([0-9a-f]{64})\s+/i.exec(output.trim());
  if (!match) { throw new Error('GALLERY_HDC_HASH: 未取得原图 SHA256，无法校验传输完整性'); }
  return match[1].toLowerCase();
}

// Only files created by this feature may be removed after a thumbnail is committed.
export function galleryHdcOwnedCopy(filesDir: string, path: string): boolean {
  let root = filesDir + '/gallery-log/hdc-images/';
  return filesDir.length > 0 && path.startsWith(root) &&
    /^gallery_hdc_[0-9a-f]{64}_[0-9a-f]{64}\.(jpe?g|png|webp|heic|heif|avif|bmp|gif|dng)$/.test(path.substring(root.length));
}

export function galleryHdcCanDiscardCopy(filesDir: string, path: string, source: string, thumbnail: string): boolean {
  let root = filesDir + '/gallery-log/thumbnails/';
  let filename = path.substring(path.lastIndexOf('/') + 1).replace(/\.[^.]+$/, '.jpg');
  return galleryHdcOwnedCopy(filesDir, path) && galleryHdcMediaPath(source) && galleryHdcImageExtension(source).length > 0 &&
    thumbnail === root + filename && /^gallery_hdc_[0-9a-f]{64}_[0-9a-f]{64}\.jpg$/.test(filename);
}

export interface GalleryImageSize { width: number; height: number; }

export function galleryImageDecodeSize(width: number, height: number, maxEdge: number): GalleryImageSize {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width <= 0 || height <= 0 ||
    !Number.isSafeInteger(maxEdge) || maxEdge < 1 || maxEdge > 2048) {
    throw new Error('GALLERY_IMAGE_SIZE: 图片尺寸无效');
  }
  let scale = Math.min(1, maxEdge / Math.max(width, height));
  return { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) };
}
