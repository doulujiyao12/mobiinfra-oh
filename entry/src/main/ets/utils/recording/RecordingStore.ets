import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { RecordingRecord, RecordingWatchSource, RECORDING_MAX_BYTES } from './RecordingTypes';
import { DownloadedRecording } from './WatchRecordingClient';
import { inspectWav, wavHeader, writeExact } from './RecordingWav';
import { normalizeRecordingSummaryTitles } from './RecordingSummaryTitle';
import { normalizeRecordingSummaryLists } from './RecordingSummaryLists';
import { RECORDING_ANALYSIS_FILES, recordingAnalysisCheckpointPath } from './RecordingAnalysisCheckpoint';
import { RECORDING_LIVE_FILE } from './RecordingLiveTypes';
import { RecordingLiveCheckpoint } from './RecordingLiveCheckpoint';
import { SYSTEM_ASR_FILE } from './RecordingSystemAsrPolicy';

export class RecordingStore {
  readonly root: string;
  constructor(filesDir: string) {
    // Deliberately outside workflows/daily-log and all memory source catalogs.
    this.root = filesDir + '/recording-analysis';
    if (!fs.accessSync(this.root)) { fs.mkdirSync(this.root, true); }
  }
  private checkId(id: string): void {
    if (!/^[a-f0-9-]{36}$/.test(id)) { throw new Error('录音标识无效'); }
  }
  directory(id: string): string { this.checkId(id); return this.root + '/' + id; }
  audioPath(id: string): string { return this.directory(id) + '/audio.wav'; }
  hasAudio(id: string): boolean { return fs.accessSync(this.audioPath(id)); }
  livePath(id: string): string { return this.directory(id) + '/' + RECORDING_LIVE_FILE; }
  systemAsrPath(id: string): string { return this.directory(id) + '/' + SYSTEM_ASR_FILE; }
  hasSystemAsrDraft(id: string): boolean { return fs.accessSync(this.systemAsrPath(id)); }
  clearSystemAsrDraft(id: string): void { if (this.hasSystemAsrDraft(id)) { fs.unlinkSync(this.systemAsrPath(id)); } }
  clearLiveDraft(id: string): void { if (fs.accessSync(this.livePath(id))) { fs.unlinkSync(this.livePath(id)); } }
  hasAnalysisDraft(id: string, diarization?: boolean): boolean {
    if (diarization === undefined) { return this.hasAnalysisDraft(id, false) || this.hasAnalysisDraft(id, true); }
    return fs.accessSync(recordingAnalysisCheckpointPath(this.audioPath(id), diarization) + '.json');
  }
  clearAnalysisDraft(id: string): void {
    for (let name of RECORDING_ANALYSIS_FILES) {
      let path = this.directory(id) + '/' + name;
      if (fs.accessSync(path)) { fs.unlinkSync(path); }
    }
  }
  create(source: string): RecordingRecord {
    let record: RecordingRecord = { schema: 1, id: util.generateRandomUUID(), title: '新录音',
      createdAt: new Date().toISOString(), source: source, duration: 0, analysis: null, titleEdited: false };
    fs.mkdirSync(this.directory(record.id));
    return record;
  }
  save(record: RecordingRecord): void {
    this.checkId(record.id);
    let text = ArkJSON.stringify(record); let path = this.directory(record.id) + '/record.json';
    let file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let buffer = new util.TextEncoder().encodeInto(text); let done = 0;
      while (done < buffer.byteLength) {
        let n = fs.writeSync(file.fd, buffer.buffer.slice(buffer.byteOffset + done, buffer.byteOffset + buffer.byteLength));
        if (n <= 0) { throw new Error('保存录音信息失败'); } done += n;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(path + '.tmp', path);
  }
  recoverCaptures(): void {
    for (let record of this.list()) {
      let changed = false;
      if (record.capturing) {
        let file = fs.openSync(this.audioPath(record.id), fs.OpenMode.READ_WRITE);
        try {
          let bytes = Math.max(0, fs.statSync(file.fd).size - 44); bytes -= bytes % 2;
          if (bytes > RECORDING_MAX_BYTES - 44) { throw new Error('未完成录音文件过大，请先备份'); }
          fs.lseek(file.fd, 0, fs.WhenceType.SEEK_SET); writeExact(file.fd, wavHeader(bytes)); fs.fsyncSync(file.fd);
          record.duration = bytes / 32000; record.capturing = false; changed = true;
        } finally { fs.closeSync(file); }
      }
      const draft = record.transcriptionEngine === 'system' ? this.systemAsrPath(record.id) : this.livePath(record.id);
      if (record.transcriptionComplete === false && fs.accessSync(draft)) {
        record.analysis = new RecordingLiveCheckpoint(draft).restore(record.duration); changed = true;
      }
      if (changed) { this.save(record); }
    }
  }
  findWatch(sourceId: string, recordingId: string): RecordingRecord | null {
    return this.list().find((record: RecordingRecord): boolean => record.watch?.sourceId === sourceId &&
      record.watch?.recordingId === recordingId) || null;
  }
  async importWatch(saved: DownloadedRecording): Promise<RecordingRecord> {
    let existing = this.findWatch(saved.sourceId, saved.recording.id);
    if (existing !== null) {
      if (existing.watch?.sha256 !== saved.sha256) { throw new Error('同一条手表录音的校验信息发生变化，原录音已保留'); }
      // A different returned path means the receiver could not verify the
      // managed copy and downloaded a replacement. Repair audio, retain edits.
      if (saved.path !== this.audioPath(existing.id)) {
        let input = fs.openSync(saved.path, fs.OpenMode.READ_ONLY);
        let temporary = this.audioPath(existing.id) + '.part';
        try {
          await fs.copyFile(input.fd, temporary);
          let output = fs.openSync(temporary, fs.OpenMode.READ_WRITE);
          try { fs.fsyncSync(output.fd); } finally { fs.closeSync(output.fd); }
          fs.renameSync(temporary, this.audioPath(existing.id));
        } catch (e) {
          if (fs.accessSync(temporary)) { fs.unlinkSync(temporary); }
          throw new Error((e as Error).message);
        } finally { fs.closeSync(input); }
      }
      if (existing.audioDeleted && this.hasAudio(existing.id)) { existing.audioDeleted = false; this.save(existing); }
      return existing;
    }
    return this.importWav(saved.path, { sourceId: saved.sourceId, recordingId: saved.recording.id, sha256: saved.sha256 }, saved.recording.createdAt);
  }
  list(): RecordingRecord[] {
    let result: RecordingRecord[] = [];
    for (let id of fs.listFileSync(this.root)) {
      if (!/^[a-f0-9-]{36}$/.test(id)) { continue; }
      let path = this.directory(id) + '/record.json';
      if (!fs.accessSync(path)) { continue; }
      let record = ArkJSON.parse(fs.readTextSync(path)) as RecordingRecord;
      if (record.schema !== 1 || record.id !== id || typeof record.title !== 'string' ||
        !Number.isFinite(record.duration) || (!record.audioDeleted && !this.hasAudio(id))) {
        throw new Error('有录音记录损坏，请保留数据后重试');
      }
      normalizeRecordingSummaryTitles(record);
      normalizeRecordingSummaryLists(record);
      result.push(record);
    }
    return result.sort((a: RecordingRecord, b: RecordingRecord): number => b.createdAt.localeCompare(a.createdAt));
  }
  async importWav(uri: string, watch?: RecordingWatchSource, createdAt: number = 0): Promise<RecordingRecord> {
    let source = await fs.open(uri, fs.OpenMode.READ_ONLY);
    let record: RecordingRecord | null = null;
    try {
      let info = inspectWav(source.fd);
      record = this.create(watch ? '手表' : '导入'); record.watch = watch;
      let name = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1)).replace(/\.wav$/i, '');
      record.title = name.length > 0 ? name.substring(0, 80) : '导入的录音';
      if (watch) {
        if (!Number.isFinite(createdAt) || createdAt <= 0) { throw new Error('手表录音时间无效'); }
        record.createdAt = new Date(createdAt).toISOString(); record.title = '手表录音 ' + new Date(createdAt).toLocaleString();
      }
      let dest = await fs.open(this.audioPath(record.id), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      try {
        fs.lseek(source.fd, 0, fs.WhenceType.SEEK_SET);
        let total = 0; let size = fs.statSync(source.fd).size;
        while (total < size) {
          let block = new ArrayBuffer(Math.min(1024 * 1024, size - total));
          let n = await fs.read(source.fd, block, { length: block.byteLength });
          if (n <= 0 || total + n > RECORDING_MAX_BYTES) { throw new Error('读取 WAV 文件失败'); }
          let written = 0;
          while (written < n) {
            let part = block.slice(written, n);
            let count = await fs.write(dest.fd, part);
            if (count <= 0) { throw new Error('保存录音失败'); } written += count;
          }
          total += n;
        }
      } finally { await fs.close(dest); }
      record.duration = info.bytes / info.align / info.rate;
      this.save(record); return record;
    } catch (e) {
      if (record !== null) { this.remove(record.id); }
      throw new Error((e as Error).message);
    } finally { await fs.close(source); }
  }
  remove(id: string): void {
    let dir = this.directory(id);
    if (!fs.accessSync(dir)) { return; }
    // Only this UUID's files; never recurse into a caller-provided path.
    for (let name of ['record.json', 'record.json.tmp', 'audio.wav', 'audio.wav.part', RECORDING_LIVE_FILE, SYSTEM_ASR_FILE].concat(RECORDING_ANALYSIS_FILES)) {
      let path = dir + '/' + name;
      if (fs.accessSync(path)) { fs.unlinkSync(path); }
    }
    fs.rmdirSync(dir);
  }
  removeAudio(record: RecordingRecord): void {
    if (record.capturing) { throw new Error('请先结束录音'); }
    if (this.hasAnalysisDraft(record.id) || this.hasSystemAsrDraft(record.id)) {
      throw new Error('请先完成或恢复转写，再删除音频，避免丢失已保存的转写进度');
    }
    // Commit the deletion intent first. A crash after unlink must not make the
    // retained text/summary look like a corrupt record on the next launch.
    const old = record.audioDeleted; record.audioDeleted = true;
    try { this.save(record); } catch (e) { record.audioDeleted = old; throw new Error((e as Error).message); }
    try { if (this.hasAudio(record.id)) { fs.unlinkSync(this.audioPath(record.id)); } }
    catch (e) {
      record.audioDeleted = old;
      try { this.save(record); } catch (ignored) {}
      throw new Error('音频删除失败，请重试：' + (e as Error).message);
    }
    const partial = this.audioPath(record.id) + '.part';
    if (fs.accessSync(partial)) { fs.unlinkSync(partial); }
    this.clearAnalysisDraft(record.id); this.clearLiveDraft(record.id); this.clearSystemAsrDraft(record.id);
  }
}
