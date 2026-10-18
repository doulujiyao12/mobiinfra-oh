import {
  CollectionImageViewModel,
  JsonMap
} from './DataManagerTypes';
import { DataManagerPaths } from './DataManagerPaths';
import { DataManagerStorage } from './DataManagerStorage';
import { normalizeFreeText } from './DataManagerUtils';

export class DataManagerImageResolver {
  private paths: DataManagerPaths;
  private storage: DataManagerStorage;
  private uriCache: Record<string, string> = new Object() as Record<string, string>;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage) {
    this.paths = paths;
    this.storage = storage;
  }

  resolveAll(refs: string[]): CollectionImageViewModel[] {
    let result: CollectionImageViewModel[] = [];
    for (let index = 0; index < refs.length; index++) {
      let ref = normalizeFreeText(refs[index]);
      if (ref.length === 0) {
        continue;
      }
      result.push(this.resolve(ref, index));
    }
    return result;
  }

  private resolve(ref: string, index: number): CollectionImageViewModel {
    let uri = this.displayUri(ref);
    let image: CollectionImageViewModel = {
      ref: ref,
      uri: uri,
      available: uri.length > 0,
      label: '图片 ' + (index + 1).toString()
    };
    return image;
  }

  private displayUri(ref: string): string {
    let cached = this.uriCache[ref];
    if (cached !== undefined) {
      return cached;
    }
    let uri = this.displayUriUncached(ref);
    if (uri.length > 0) {
      this.uriCache[ref] = uri;
    }
    return uri;
  }

  private displayUriUncached(ref: string): string {
    if (ref.startsWith('data:image/')) {
      return ref;
    }
    if (this.isDisplayableGalleryUri(ref)) {
      return ref;
    }
    let hashIndex = ref.indexOf('#');
    if (hashIndex >= 0) {
      let fileRef = ref.substring(0, hashIndex);
      let pointer = ref.substring(hashIndex + 1);
      // Old memories point to #uri. HDC results now keep a source reference there;
      // prefer the committed thumbnail so existing memories survive full-copy cleanup.
      if (this.isGalleryItemJsonRef(fileRef) && (pointer === 'uri' || pointer === '/uri')) {
        let thumbnail = this.displayUriFromJsonPointer(fileRef, 'thumbnailUri');
        if (thumbnail.length > 0) { return thumbnail; }
      }
      return this.displayUriFromJsonPointer(fileRef, pointer);
    }
    if (this.isGalleryItemJsonRef(ref)) {
      let uri = this.displayUriFromJsonPointer(ref, 'thumbnailUri');
      return uri.length > 0 ? uri : this.displayUriFromJsonPointer(ref, 'uri');
    }
    let imageText = normalizeFreeText(ref);
    let dataUri = this.base64DataUri(imageText);
    if (dataUri.length > 0) {
      return dataUri;
    }
    let absolutePath = this.absoluteImagePath(imageText);
    return absolutePath.length > 0 ? 'file://' + absolutePath : '';
  }

  private displayUriFromJsonPointer(fileRef: string, pointer: string): string {
    let filePath = this.absoluteJsonPath(fileRef);
    if (filePath.length === 0) {
      return '';
    }
    let payload = this.storage.readJson<JsonMap>(filePath, new Object() as JsonMap);
    let value = this.pointerString(payload, pointer);
    if (value.length === 0) {
      return '';
    }
    if (this.isDisplayableGalleryUri(value)) {
      return value;
    }
    if (value.startsWith('data:image/')) {
      return value;
    }
    let dataUri = this.base64DataUri(value);
    if (dataUri.length > 0) {
      return dataUri;
    }
    let absolutePath = this.absoluteImagePath(value);
    return absolutePath.length > 0 ? 'file://' + absolutePath : '';
  }

  private pointerString(payload: JsonMap, pointer: string): string {
    let segments = pointer.split('/').filter((segment: string) => segment.length > 0);
    let current: Object | string | number | boolean | null | undefined = payload;
    for (let segment of segments) {
      if (!current || typeof current !== 'object' || Array.isArray(current)) {
        return '';
      }
      let currentMap = current as JsonMap;
      current = currentMap[segment];
    }
    return normalizeFreeText(current);
  }

  private absoluteJsonPath(fileRef: string): string {
    let filePath = normalizeFreeText(fileRef).replace(/\\/g, '/');
    if (filePath.startsWith('file://')) {
      filePath = filePath.substring('file://'.length);
    }
    if (this.isAbsolutePath(filePath)) {
      return this.storage.exists(filePath) ? filePath : '';
    }
    if (filePath.startsWith('workflows/')) {
      let absolute = this.storage.join(this.paths.filesDir, filePath);
      return this.storage.exists(absolute) ? absolute : '';
    }
    if (filePath.startsWith('gallery-log/')) {
      let absolute = this.storage.join(this.paths.filesDir, filePath);
      return this.storage.exists(absolute) ? absolute : '';
    }
    let relative = this.paths.fromDataManagerRelative(filePath);
    return this.storage.exists(relative) ? relative : '';
  }

  private absoluteImagePath(value: string): string {
    let pathText = normalizeFreeText(value).replace(/\\/g, '/');
    if (pathText.startsWith('file://')) {
      pathText = pathText.substring('file://'.length);
    }
    if (this.isAbsolutePath(pathText)) {
      return this.storage.exists(pathText) ? pathText : '';
    }
    if (pathText.startsWith('workflows/')) {
      let absolute = this.storage.join(this.paths.filesDir, pathText);
      return this.storage.exists(absolute) ? absolute : '';
    }
    let relative = this.paths.fromDataManagerRelative(pathText);
    return this.storage.exists(relative) ? relative : '';
  }

  private isAbsolutePath(pathText: string): boolean {
    return pathText.startsWith('/') || /^[A-Za-z]:\//.test(pathText);
  }

  private isGalleryItemJsonRef(ref: string): boolean {
    let normalized = normalizeFreeText(ref).replace(/\\/g, '/');
    return normalized.startsWith('gallery-log/items/') && normalized.endsWith('.json');
  }

  private isDisplayableGalleryUri(value: string): boolean {
    let text = normalizeFreeText(value);
    return text.startsWith('datashare://') || text.startsWith('content://') ||
      text.startsWith('photo://') || text.startsWith('file://');
  }

  private base64DataUri(value: string): string {
    let text = this.compactBase64(value);
    if (text.startsWith('iVBORw0KGgo')) {
      return 'data:image/png;base64,' + text;
    }
    if (text.startsWith('R0lGOD')) {
      return 'data:image/gif;base64,' + text;
    }
    if (text.startsWith('UklGR')) {
      return 'data:image/webp;base64,' + text;
    }
    if (text.startsWith('/9j/')) {
      return 'data:image/jpeg;base64,' + text;
    }
    return '';
  }

  private compactBase64(value: string): string {
    for (let index = 0; index < value.length; index++) {
      let code = value.charCodeAt(index);
      if (code === 9 || code === 10 || code === 13 || code === 32) {
        return value.replace(/\s+/g, '');
      }
    }
    return value;
  }
}
