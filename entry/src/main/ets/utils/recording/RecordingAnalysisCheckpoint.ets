import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { RecordingAnalysis, RecordingJob, RecordingSegment, RecordingSpeaker, SpeechRange,
  RECORDING_CHUNK_SECONDS, RECORDING_MODEL_ID } from './RecordingTypes';
import { writeExact } from './RecordingWav';

const POLICY: string = 'speech-packed-cpu-v1';
export const RECORDING_ANALYSIS_FILES: string[] = ['audio.wav.analysis.json', 'audio.wav.analysis.json.tmp',
  'audio.wav.analysis-current.json', 'audio.wav.analysis-current.json.tmp', 'audio.wav.transcription.json',
  'audio.wav.transcription.json.tmp', 'audio.wav.transcription-current.json', 'audio.wav.transcription-current.json.tmp'];

export function recordingAnalysisCheckpointPath(audioPath: string, diarization: boolean): string {
  return audioPath + (diarization ? '.analysis' : '.transcription');
}

export interface RecordingChunkCheckpoint {
  index: number; speech: SpeechRange[]; turns: RecordingSegment[] | null; mapped: boolean; nextTurn: number;
  analysis: RecordingAnalysis;
}
interface AnalysisCheckpoint {
  policy: string; identity: string; model: string; language: string; run: string;
  completed: number; total: number; analysis: RecordingAnalysis;
}
interface CurrentCheckpoint { run: string; chunk: RecordingChunkCheckpoint; }

function emptyAnalysis(duration: number): RecordingAnalysis {
  return { modelId: RECORDING_MODEL_ID, duration: duration, speech: [], segments: [], speakers: [], timings: [] };
}
function validRange(range: SpeechRange, duration: number): boolean {
  return Number.isFinite(range.start) && Number.isFinite(range.end) && range.start >= 0 &&
    range.end >= range.start && range.end <= duration + 0.01;
}
function validateAnalysis(analysis: RecordingAnalysis, duration: number): boolean {
  return analysis?.modelId === RECORDING_MODEL_ID && analysis.duration === duration &&
    Array.isArray(analysis.speech) && analysis.speech.every((r: SpeechRange): boolean => validRange(r, duration)) &&
    Array.isArray(analysis.speakers) && analysis.speakers.every((s: RecordingSpeaker): boolean =>
      Number.isInteger(s.id) && s.id >= -1 && typeof s.name === 'string' && Number.isFinite(s.seconds) &&
      s.seconds >= 0 && Array.isArray(s.embedding) && s.embedding.every((n: number): boolean => Number.isFinite(n))) &&
    Array.isArray(analysis.timings) && analysis.timings.every((t): boolean =>
      Number.isInteger(t.chunk) && t.chunk >= 0 && typeof t.stage === 'string' && Number.isFinite(t.milliseconds) &&
      t.milliseconds >= 0 && Number.isFinite(t.audioSeconds) && t.audioSeconds >= 0 &&
      // Accept timings from historical six-thread checkpoints; new inference
      // uses the four-thread cap in RecordingPerformance.
      Number.isInteger(t.threads) && t.threads >= 1 && t.threads <= 6) &&
    Array.isArray(analysis.segments) && analysis.segments.every((s: RecordingSegment, index: number): boolean =>
      s.id === index && validRange(s, duration) && typeof s.text === 'string' && typeof s.language === 'string' &&
      analysis.speakers.some((speaker: RecordingSpeaker): boolean => speaker.id === s.speaker));
}

// The completed prefix is written once per five-minute chunk. The separately
// committed current chunk is bounded, so per-turn saving never rewrites hours
// of transcript. Either rename is independently recoverable after termination.
export class RecordingAnalysisCheckpoint {
  readonly state: AnalysisCheckpoint;
  private path: string;
  private currentPath: string;
  constructor(job: RecordingJob, duration: number) {
    const prefix = recordingAnalysisCheckpointPath(job.audioPath, job.diarization === true);
    this.path = prefix + '.json';
    this.currentPath = prefix + '-current.json';
    const stat = fs.statSync(job.audioPath);
    const identity = String(stat.size) + ':' + String(stat.mtime) + ':' + String(stat.ctime) + ':' + String(stat.ino);
    let total = Math.ceil(duration / RECORDING_CHUNK_SECONDS);
    if (!job.restart && fs.accessSync(this.path)) {
      let saved: AnalysisCheckpoint;
      try { saved = ArkJSON.parse(fs.readTextSync(this.path)) as AnalysisCheckpoint; }
      catch (e) { throw new Error('转写断点无法读取，原录音和已保存结果已保留，可选择从头转写'); }
      if (saved === null) { throw new Error('转写断点内容无效，可选择从头转写'); }
      if (saved.policy === POLICY && saved.identity === identity && saved.model === job.modelDir &&
        saved.language === job.language && saved.total === total) {
        if (!Number.isInteger(saved.completed) || saved.completed < 0 || saved.completed > total ||
          typeof saved.run !== 'string' || !validateAnalysis(saved.analysis, duration)) {
          throw new Error('转写断点内容无效，原录音和已保存结果已保留，可选择从头转写');
        }
        this.state = saved; return;
      }
    }
    this.state = { policy: POLICY, identity: identity, model: job.modelDir, language: job.language,
      run: util.generateRandomUUID(), completed: 0, total: total, analysis: emptyAnalysis(duration) };
    this.state.analysis.method = job.diarization === true ? 'diarized' : 'transcription';
    this.write(this.path, ArkJSON.stringify(this.state));
  }
  private write(path: string, text: string): void {
    let file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let bytes = new util.TextEncoder().encodeInto(text);
      writeExact(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    fs.renameSync(path + '.tmp', path);
  }
  current(): RecordingChunkCheckpoint | null {
    if (!fs.accessSync(this.currentPath)) { return null; }
    let saved: CurrentCheckpoint;
    try { saved = ArkJSON.parse(fs.readTextSync(this.currentPath)) as CurrentCheckpoint; }
    catch (e) { throw new Error('当前分段断点无法读取，请保留录音后选择从头转写'); }
    if (saved === null) { throw new Error('当前分段断点内容无效，可选择从头转写'); }
    if (saved.run !== this.state.run || saved.chunk?.index !== this.state.completed) { return null; }
    let chunk = saved.chunk;
    if (!Array.isArray(chunk.speech) ||
      !chunk.speech.every((r: SpeechRange): boolean => validRange(r, RECORDING_CHUNK_SECONDS + 2)) ||
      !(chunk.turns === null || Array.isArray(chunk.turns)) || typeof chunk.mapped !== 'boolean' ||
      !Number.isInteger(chunk.nextTurn) || chunk.nextTurn < 0 || chunk.nextTurn > (chunk.turns?.length || 0) ||
      (!chunk.mapped && chunk.nextTurn !== 0) || chunk.analysis?.segments?.length !== chunk.nextTurn ||
      !validateAnalysis(chunk.analysis, this.state.analysis.duration) ||
      (chunk.turns !== null && !chunk.turns.every((s: RecordingSegment): boolean =>
        validRange(s, RECORDING_CHUNK_SECONDS + 2) && Number.isInteger(s.speaker) && s.speaker >= -1 &&
        (!chunk.mapped || s.speaker === -1 ||
          chunk.analysis.speakers.some((speaker: RecordingSpeaker): boolean => speaker.id === s.speaker))))) {
      throw new Error('当前分段断点内容无效，请保留录音后选择从头转写');
    }
    return chunk;
  }
  createChunk(index: number, speech: SpeechRange[]): RecordingChunkCheckpoint {
    let analysis = emptyAnalysis(this.state.analysis.duration);
    analysis.speakers = this.state.analysis.speakers.map((speaker: RecordingSpeaker): RecordingSpeaker => ({
      id: speaker.id, name: speaker.name, seconds: speaker.seconds, embedding: speaker.embedding.slice() }));
    return { index: index, speech: speech, turns: null, mapped: false, nextTurn: 0, analysis: analysis };
  }
  saveCurrent(chunk: RecordingChunkCheckpoint): void {
    let saved: CurrentCheckpoint = { run: this.state.run, chunk: chunk };
    this.write(this.currentPath, ArkJSON.stringify(saved));
  }
  finishChunk(chunk: RecordingChunkCheckpoint, start: number): void {
    let result = this.state.analysis;
    for (let range of chunk.speech) {
      let previous = result.speech[result.speech.length - 1];
      if (previous && Math.abs(previous.end - (start + range.start)) < 0.001) { previous.end = start + range.end; }
      else { result.speech.push({ start: start + range.start, end: start + range.end }); }
    }
    for (let segment of chunk.analysis.segments) { segment.id = result.segments.length; result.segments.push(segment); }
    result.speakers = chunk.analysis.speakers;
    result.timings = (result.timings || []).concat(chunk.analysis.timings || []);
    this.state.completed = chunk.index + 1;
    this.write(this.path, ArkJSON.stringify(this.state));
  }
}
