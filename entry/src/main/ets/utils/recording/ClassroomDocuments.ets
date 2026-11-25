import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { writeRecordingMetadata } from './RecordingMetadata';
import { ClassroomDocument, CLASSROOM_DOCUMENT_BYTES, CLASSROOM_DOCUMENT_LIMIT, classroomDocumentFile,
  classroomDocumentExtension } from './ClassroomMaterials';

interface ClassroomDocumentIndex { version: number; documents: ClassroomDocument[]; }

export const CLASSROOM_FILE_FILTER: string = '学习资料|.ppt,.pptx,.pdf,.doc,.docx,.xls,.xlsx,.txt,.md,.png,.jpg,.jpeg';

export class ClassroomDocuments {
  readonly directory: string;
  private courseLibrary: boolean;
  constructor(directory: string, courseLibrary: boolean = false) {
    this.directory = directory;
    this.courseLibrary = courseLibrary;
  }
  private legacy(): ClassroomDocument[] {
    const path = this.directory + '/documents.json';
    if (!fs.accessSync(path)) { return []; }
    const index = ArkJSON.parse(fs.readTextSync(path)) as ClassroomDocumentIndex;
    if (index.version !== 1 || !Array.isArray(index.documents) || index.documents.length > CLASSROOM_DOCUMENT_LIMIT) {
      throw new Error('课堂附件清单无法读取');
    }
    return index.documents;
  }
  list(): ClassroomDocument[] {
    if (!fs.accessSync(this.directory)) { return []; }
    const documents = this.legacy();
    for (const folder of fs.listFileSync(this.directory)) {
      if (!/^asset-[a-f0-9-]{36}$/.test(folder)) { continue; }
      const entry = ArkJSON.parse(fs.readTextSync(this.directory + '/' + folder + '/meta.json')) as ClassroomDocument;
      if (!entry || folder !== 'asset-' + entry.id || entry.portable !== true) { throw new Error('资料目录无效'); }
      documents.push(entry);
    }
    const ids = new Set<string>();
    for (const entry of documents) {
      if (!entry || typeof entry.name !== 'string' || typeof entry.id !== 'string') { throw new Error('课堂附件清单无法读取'); }
      classroomDocumentFile(entry);
      if (ids.has(entry.id) || !Number.isInteger(entry.size) || entry.size <= 0 || entry.size > CLASSROOM_DOCUMENT_BYTES) {
        throw new Error('课堂附件清单数据无效');
      }
      ids.add(entry.id);
    }
    return documents;
  }
  private ensureDirectory(): void {
    if (!fs.accessSync(this.directory)) { fs.mkdirSync(this.directory, true); }
  }
  private requireSpace(size: number): void {
    if (size <= 0 || size > CLASSROOM_DOCUMENT_BYTES) { throw new Error('单份资料需大于 0 且不超过 48 MiB'); }
    if (this.courseLibrary) { return; }
    const documents = this.list();
    if (documents.length >= CLASSROOM_DOCUMENT_LIMIT) { throw new Error('每节课最多保存 16 份附件'); }
    const stored = documents.reduce((total: number, entry: ClassroomDocument): number => total + entry.size, 0);
    if (stored + size > CLASSROOM_DOCUMENT_BYTES) { throw new Error('每节课的附件合计最多 48 MiB'); }
  }
  async add(uri: string): Promise<ClassroomDocument[]> {
    const name = (new fileUri.FileUri(uri).name || '').replace(/[\u0000-\u001f\u007f/\\]/g, ' ').trim();
    const extension = classroomDocumentExtension(name);
    if (!extension) { throw new Error('请选择课件、文档或 JPG、PNG 图片'); }
    const displayName = name.length > 180 ? name.substring(0, 170) + '.' + extension : name;
    const input = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = (await fs.stat(input.fd)).size;
      this.requireSpace(size);
      this.ensureDirectory();
      const entry: ClassroomDocument = { id: util.generateRandomUUID(), name: displayName, size: size, portable: true };
      const partial = this.directory + '/.import-' + entry.id;
      fs.mkdirSync(partial);
      try {
        const path = partial + '/file.' + extension;
        await fs.copyFile(input.fd, path);
        if ((await fs.stat(path)).size !== size) { throw new Error('资料读取不完整，请重新选择'); }
        const output = fs.openSync(path, fs.OpenMode.READ_WRITE);
        try { fs.fsyncSync(output.fd); } finally { fs.closeSync(output); }
        writeRecordingMetadata(partial + '/meta.json', entry);
        this.requireSpace(size);
        fs.renameSync(partial, this.directory + '/asset-' + entry.id);
      } finally { if (fs.accessSync(partial)) { fs.rmdirSync(partial); } }
    } finally { await fs.close(input); }
    return this.list();
  }
  // Course imports carry their own metadata. One rename commits the binding, including the original file.
  bindToLesson(id: string, target: ClassroomDocuments): void {
    const entry = this.list().find((doc: ClassroomDocument): boolean => doc.id === id);
    if (!this.courseLibrary || target.courseLibrary || !entry?.portable) { throw new Error('待绑定的课件已变更'); }
    target.requireSpace(entry.size);
    target.ensureDirectory();
    const name = '/asset-' + id;
    if (fs.accessSync(target.directory + name)) { throw new Error('本节课已有该文件'); }
    fs.renameSync(this.directory + name, target.directory + name);
  }
  remove(id: string): ClassroomDocument[] {
    const entry = this.list().find((item: ClassroomDocument): boolean => item.id === id);
    if (!entry) { return this.list(); }
    if (entry.portable) {
      const removed = this.directory + '/.removed-' + id;
      fs.renameSync(this.directory + '/asset-' + id, removed);
      fs.rmdirSync(removed);
    } else {
      const index: ClassroomDocumentIndex = { version: 1, documents: this.legacy().filter((item: ClassroomDocument): boolean => item.id !== id) };
      writeRecordingMetadata(this.directory + '/documents.json', index);
      const path = this.directory + '/' + classroomDocumentFile(entry);
      if (fs.accessSync(path)) { fs.unlinkSync(path); }
    }
    return this.list();
  }
}
