import { RecordingAnalysis, RecordingSegment, SpeechRange, RECORDING_MODEL_ID } from './RecordingTypes';

export const RECORDING_LIVE_FILE: string = 'live-transcript.jsonl';
export interface RecordingLiveJob { audioPath: string; modelDir: string; language: string; fileInput?: boolean; }
export interface RecordingLiveRequest { kind: string; job?: RecordingLiveJob; end?: number; }
export interface RecordingLiveUpdate {
  kind: string; processed: number; segments: RecordingSegment[]; speech: SpeechRange[]; error: string;
  modelId?: string; method?: string; resumeAt?: number;
  // Mutable recognition hypothesis. Display separately from committed rows;
  // it must never be written as a completed transcript/checkpoint.
  preview?: RecordingSegment;
}
export interface RecordingLiveState { analysis: RecordingAnalysis; processed: number; committed: number; }
export interface RecordingLiveTranscriber {
  start(job: RecordingLiveJob, available: () => number, update: (value: RecordingLiveUpdate) => void,
    onFailure: (message: string) => void): void;
  finish(samples: number): Promise<RecordingAnalysis>;
  snapshot(duration: number): RecordingAnalysis;
  recent(): RecordingSegment[];
  completedSamples(): number;
  cancel(): void;
}

export function emptyLiveAnalysis(duration: number): RecordingAnalysis {
  return { modelId: RECORDING_MODEL_ID, method: 'live', duration: duration, segments: [], speech: [], speakers: [], timings: [] };
}

export function appendLiveUpdate(analysis: RecordingAnalysis, update: RecordingLiveUpdate): void {
  if (!Number.isInteger(update.processed) || update.processed < 0 || !Array.isArray(update.segments) || !Array.isArray(update.speech) ||
    update.segments.some((segment: RecordingSegment): boolean => typeof segment.text !== 'string' || typeof segment.language !== 'string' ||
      !Number.isFinite(segment.start) || !Number.isFinite(segment.end) || segment.start < 0 || segment.end <= segment.start || segment.end > update.processed / 16000 + 0.01)) {
    throw new Error('实时转写结果格式无效');
  }
  if (update.modelId !== undefined) {
    if (analysis.segments.length > 0 && analysis.modelId !== update.modelId) { throw new Error('转写进度属于不同识别引擎'); }
    analysis.modelId = update.modelId; analysis.method = update.method;
  }
  for (let segment of update.segments) {
    analysis.segments.push({ id: analysis.segments.length, start: segment.start, end: segment.end,
      speaker: -1, text: segment.text, language: segment.language });
  }
  let addedSeconds = 0;
  for (let range of update.speech) {
    if (!Number.isFinite(range.start) || !Number.isFinite(range.end) || range.start < 0 || range.end <= range.start || range.end > update.processed / 16000 + 0.01) {
      throw new Error('实时转写的人声时间无效');
    }
    analysis.speech.push({ start: range.start, end: range.end });
    addedSeconds += range.end - range.start;
  }
  if (analysis.segments.length > 0) {
    analysis.speakers = [{ id: -1, name: '现场录音', seconds: (analysis.speakers[0]?.seconds || 0) + addedSeconds, embedding: [] }];
  }
}
