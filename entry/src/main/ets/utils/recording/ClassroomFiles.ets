import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { writeExact } from './RecordingWav';
import { ClassroomDocument, ClassroomPhoto, classroomDocumentFile, classroomPackDocumentName,
  classroomPhoto } from './ClassroomMaterials';
import { CODEX_MAX_FILE_BYTES } from '../../pages/codex/CodexTypes';

function removeTemporary(path: string): void {
  try { if (fs.accessSync(path)) { fs.unlinkSync(path); } } catch (_) {}
}

export function classroomPhotos(dir: string): ClassroomPhoto[] {
  const photos: ClassroomPhoto[] = [];
  if (!fs.accessSync(dir)) { return photos; }
  for (const name of fs.listFileSync(dir)) {
    const photo = classroomPhoto(name);
    if (photo) { photos.push(photo); }
  }
  return photos.sort((a: ClassroomPhoto, b: ClassroomPhoto): number => a.seconds - b.seconds || a.name.localeCompare(b.name));
}

export async function photographLesson(context: common.UIAbilityContext, dir: string, seconds: number): Promise<boolean> {
  const id = util.generateRandomUUID();
  const temp = context.cacheDir + '/lesson-camera-' + id + '.jpg';
  const dest = dir + '/photo-' + Math.round(seconds * 1000) + '-' + id + '.jpg';
  const partial = dest + '.part';
  try {
    fs.closeSync(fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE));
    const uri = fileUri.getUriFromPath(temp);
    const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK, saveUri: uri };
    const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
    if (result.resultCode !== 0 || result.mediaType !== cameraPicker.PickerMediaType.PHOTO) { return false; }
    const file = await fs.open(result.resultUri.trim() || uri, fs.OpenMode.READ_ONLY);
    try {
      const source = image.createImageSource(file.fd);
      try {
        const info = await source.getImageInfo();
        const scale = Math.min(1, 2400 / Math.max(info.size.width, info.size.height));
        const pixels = await source.createPixelMap({ desiredSize: {
          width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) } });
        try {
          const packer = image.createImagePacker();
          try {
            const data = await packer.packing(pixels, { format: 'image/jpeg', quality: 88 });
            const out = fs.openSync(partial, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
            try { writeExact(out.fd, data); fs.fsyncSync(out.fd); } finally { fs.closeSync(out); }
            fs.renameSync(partial, dest);
          } finally { await packer.release(); }
        } finally { await pixels.release(); }
      } finally { await source.release(); }
    } finally { await fs.close(file); }
    return true;
  } finally { removeTemporary(temp); removeTemporary(partial); }
}

// Only material selected for this lesson enters the archive. In particular the
// recording directory also contains the waveform and may contain voiceprints.
export async function uploadClassroomPack(cacheDir: string, dir: string, material: string,
  photos: ClassroomPhoto[], documents: ClassroomDocument[],
  upload: (name: string, base64: string) => Promise<string>,
  report?: (notice: string) => void): Promise<string[]> {
  const files: ClassroomPackFile[] = [];
  for (const photo of photos) {
    if (!classroomPhoto(photo.name)) { throw new Error('课堂照片无效'); }
    files.push({ path: dir + '/' + photo.name, name: photo.name });
  }
  documents.forEach((doc: ClassroomDocument, index: number): void => {
    files.push({ path: dir + '/' + classroomDocumentFile(doc), name: classroomPackDocumentName(doc, index), size: doc.size });
  });
  return uploadStudyArchive(cacheDir, 'lesson.md', material, files, upload, report);
}

export interface ClassroomPackFile { path: string; name: string; size?: number; }

export async function uploadStudyArchive(cacheDir: string, manifestName: string, material: string,
  files: ClassroomPackFile[], upload: (name: string, base64: string) => Promise<string>,
  report?: (notice: string) => void): Promise<string[]> {
  if (manifestName !== 'lesson.md' && manifestName !== 'course.md') { throw new Error('资料清单名称无效'); }
  const scratch = cacheDir + '/lesson-pack-' + util.generateRandomUUID();
  const staging = scratch + '/materials';
  const notes = staging + '/' + manifestName;
  const archive = scratch + '/classroom.zip';
  fs.mkdirSync(scratch);
  try {
    report?.('正在打包所选学习资料');
    fs.mkdirSync(staging);
    for (const entry of files) {
      if (!/^[a-zA-Z0-9-]+\.[a-zA-Z0-9]+$/.test(entry.name) || fs.accessSync(staging + '/' + entry.name) ||
        entry.name === manifestName) { throw new Error('资料包文件名无效'); }
      report?.('正在打包所选学习资料');
      const input = await fs.open(entry.path, fs.OpenMode.READ_ONLY);
      try {
        if (entry.size !== undefined && (await fs.stat(input.fd)).size !== entry.size) {
          throw new Error('所选文件已变更，请重新选择');
        }
        await fs.copyFile(input.fd, staging + '/' + entry.name);
      } finally { await fs.close(input); }
    }
    const file = fs.openSync(notes, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try { writeExact(file.fd, new util.TextEncoder().encodeInto(material).buffer as ArrayBuffer); }
    finally { fs.closeSync(file); }
    report?.('正在压缩学习资料');
    await zlib.compressFile(staging, archive, {});
    const size = (await fs.stat(archive)).size;
    const parts = Math.ceil(size / CODEX_MAX_FILE_BYTES);
    if (parts < 1 || parts > 6) { throw new Error('资料包超过 48 MiB，请减少本次选中的照片或附件'); }
    const source = await fs.open(archive, fs.OpenMode.READ_ONLY);
    const ids: string[] = [];
    try {
      for (let n = 0; n < parts; n++) {
        report?.('正在上传资料包 · 第 ' + (n + 1) + '/' + parts + ' 份');
        const start = n * CODEX_MAX_FILE_BYTES;
        const bytes = new Uint8Array(Math.min(CODEX_MAX_FILE_BYTES, size - start));
        let done = 0;
        while (done < bytes.length) {
          const chunk = new ArrayBuffer(Math.min(512 * 1024, bytes.length - done));
          const count = await fs.read(source.fd, chunk, { length: chunk.byteLength });
          if (count <= 0) { throw new Error('课堂资料包读取不完整'); }
          bytes.set(new Uint8Array(chunk, 0, count), done); done += count;
        }
        const name = parts === 1 ? 'classroom.zip' : 'classroom.zip.' + String(n + 1).padStart(3, '0');
        ids.push(await upload(name, new util.Base64Helper().encodeToStringSync(bytes)));
      }
    } finally { await fs.close(source); }
    return ids;
  } finally {
    // Both directories belong to this export. The OS also reclaims its cache after a process exit.
    removeTemporary(archive);
    try {
      if (fs.accessSync(staging)) {
        for (const name of fs.listFileSync(staging)) { removeTemporary(staging + '/' + name); }
        fs.rmdirSync(staging);
      }
    } catch (_) {}
    try { fs.rmdirSync(scratch); } catch (_) {}
  }
}
