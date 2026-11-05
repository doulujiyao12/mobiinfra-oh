import worker, { MessageEvents } from '@ohos.worker';
import { OfflineRecognizer, OfflineRecognizerConfig, OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig,
  OfflineSpeakerDiarizationSegment, SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig,
  Vad, VadConfig, SileroVadConfig, TenVadConfig } from 'sherpa_onnx';
import { readWav16k, recordingWavDuration } from '../utils/recording/RecordingWav';
import { RecordingAnalysisCheckpoint } from '../utils/recording/RecordingAnalysisCheckpoint';
import { recordingAvailableThreads } from '../utils/recording/RecordingPerformance';
import { packRecordingSpeech, restoreRecordingSpeechTurns } from '../utils/recording/RecordingSpeechTimeline';
import { RecordingAnalysis, RecordingJob, RecordingSegment, RecordingSpeaker, RecordingWorkerMessage,
  RECORDING_CHUNK_SECONDS, recordingTurns, SpeechRange, voiceSimilarity } from '../utils/recording/RecordingTypes';

const port = worker.workerPort;
function report(progress: number, message: string): void {
  let value: RecordingWorkerMessage = { kind: 'progress', progress: progress, message: message, result: null };
  port.postMessage(value);
}
function addUnassigned(turns: RecordingSegment[], speech: SpeechRange[]): RecordingSegment[] {
  let ordered = turns.slice().sort((a: RecordingSegment, b: RecordingSegment): number => a.start - b.start);
  let all = turns.slice();
  for (let range of speech) {
    let cursor = range.start;
    for (let turn of ordered) {
      if (turn.end <= cursor || turn.start >= range.end) { continue; }
      if (turn.start - cursor >= 0.15) {
        all.push({ id: 0, start: cursor, end: Math.min(turn.start, range.end), speaker: -1, text: '', language: '' });
      }
      cursor = Math.max(cursor, turn.end);
    }
    if (range.end - cursor >= 0.15) {
      all.push({ id: 0, start: cursor, end: range.end, speaker: -1, text: '', language: '' });
    }
  }
  return recordingTurns(all, speech);
}
function embeddingFor(id: number, turns: RecordingSegment[], samples: Float32Array,
  extractor: SpeakerEmbeddingExtractor): number[] {
  if (id < 0) { return []; }
  let clean = turns.filter((s: RecordingSegment): boolean => s.speaker === id && s.end - s.start >= 1.5 &&
    !turns.some((other: RecordingSegment): boolean => other.speaker !== id && other.start < s.end && other.end > s.start))
    .sort((a: RecordingSegment, b: RecordingSegment): number => (b.end - b.start) - (a.end - a.start)).slice(0, 3);
  if (clean.length === 0) { return []; }
  let stream = extractor.createStream();
  for (let part of clean) {
    stream.acceptWaveform({ samples: samples.subarray(Math.floor(part.start * 16000),
      Math.floor(Math.min(part.end, part.start + 10) * 16000)), sampleRate: 16000 });
  }
  stream.inputFinished();
  return extractor.isReady(stream) ? Array.from(extractor.compute(stream, false)) : [];
}
function globalSpeaker(embedding: number[], speakers: RecordingSpeaker[], used: number[]): number {
  let best = -1; let similarity = 0.65;
  for (let speaker of speakers) {
    if (speaker.id < 0 || speaker.embedding.length === 0 || used.indexOf(speaker.id) >= 0 || embedding.length === 0) { continue; }
    let score = voiceSimilarity(embedding, speaker.embedding);
    if (score > similarity) { best = speaker.id; similarity = score; }
  }
  if (best >= 0) { return best; }
  let id = speakers.filter((s: RecordingSpeaker): boolean => s.id >= 0).length;
  speakers.push({ id: id, name: '说话人 ' + (id + 1), seconds: 0, embedding: embedding });
  return id;
}
function analyze(job: RecordingJob): RecordingAnalysis {
  report(2, '读取音频信息');
  let duration = recordingWavDuration(job.audioPath);
  let checkpoint = new RecordingAnalysisCheckpoint(job, duration);
  if (checkpoint.state.completed === checkpoint.state.total) { return checkpoint.state.analysis; }
  let threads = recordingAvailableThreads();
  let dir = job.modelDir + '/';
  let vad: Vad | null = null;
  let diarizer: OfflineSpeakerDiarization | null = null;
  let recognizer: OfflineRecognizer | null = null;
  let extractor: SpeakerEmbeddingExtractor | null = null;
  let count = checkpoint.state.total;
  let resumed = checkpoint.current();
  for (let index = checkpoint.state.completed; index < count; index++) {
    let coreStart = index * RECORDING_CHUNK_SECONDS;
    let coreEnd = Math.min(duration, coreStart + RECORDING_CHUNK_SECONDS);
    // Retain context near boundaries, but transcribe each owned interval once.
    let start = Math.max(0, coreStart - 1);
    let samples = readWav16k(job.audioPath, start, Math.min(duration, coreEnd + 1));
    let prefix = count > 1 ? '第 ' + (index + 1) + ' / ' + count + ' 段 · ' : '';
    let progress = (fraction: number, text: string): void => { report(5 + 94 * (index + fraction) / count, prefix + text); };
    let chunk = resumed; resumed = null;
    if (chunk === null) {
      if (vad === null) {
        progress(0, '加载人声检测模型');
        vad = new Vad(new VadConfig(new SileroVadConfig(dir + 'silero_vad.onnx', 0.5, 0.25, 0.5, 512, 20),
          new TenVadConfig('', 0.5, 0.25, 0.5, 256), 16000, false, threads), 60);
      }
      progress(0, '检测人声与停顿 · 0.0 / ' + (samples.length / 16000).toFixed(1) + ' 秒');
      let began = Date.now(); vad.reset(); vad.clear();
      let speech: SpeechRange[] = [];
      let drain = (): void => {
        while (!vad!.isEmpty()) {
          let range = vad!.front(false);
          let a = Math.max(coreStart - start, range.start / 16000);
          let b = Math.min(coreEnd - start, (range.start + range.samples.length) / 16000);
          if (b > a) { speech.push({ start: a, end: b }); }
          vad!.pop();
        }
      };
      let nextReportAt = 0;
      for (let offset = 0; offset < samples.length; offset += 512) {
        let end = Math.min(samples.length, offset + 512);
        vad.acceptWaveform(samples.subarray(offset, end)); drain();
        if (Date.now() >= nextReportAt || end === samples.length) {
          progress(0.1 * end / samples.length, '检测人声与停顿 · ' + (end / 16000).toFixed(1) +
            ' / ' + (samples.length / 16000).toFixed(1) + ' 秒'); nextReportAt = Date.now() + 250;
        }
      }
      vad.flush(); drain(); chunk = checkpoint.createChunk(index, speech);
      chunk.analysis.timings!.push({ chunk: index, stage: 'vad', milliseconds: Date.now() - began,
        audioSeconds: samples.length / 16000, threads: threads });
      checkpoint.saveCurrent(chunk);
    }
    if (chunk.speech.length === 0) { checkpoint.finishChunk(chunk, start); continue; }
    if (chunk.turns === null && job.diarization !== true) {
      // VAD already supplies speech boundaries. No clustering or voiceprint
      // extraction is required when the user only wants a transcript.
      chunk.turns = recordingTurns([{ id: 0, start: 0, end: samples.length / 16000,
        speaker: -1, text: '', language: '' }], chunk.speech);
      chunk.mapped = true; checkpoint.saveCurrent(chunk);
    }
    if (chunk.turns === null) {
      if (diarizer === null) {
        progress(0.1, '加载说话人模型 · ' + threads + ' 线程');
        let config = new OfflineSpeakerDiarizationConfig();
        config.segmentation.pyannote.model = dir + 'segmentation.int8.onnx';
        config.segmentation.numThreads = threads; config.embedding.model = dir + 'speaker.onnx';
        config.embedding.numThreads = threads; config.clustering.numClusters = -1; config.clustering.threshold = 0.5;
        diarizer = new OfflineSpeakerDiarization(config);
      }
      let packed = packRecordingSpeech(samples, chunk.speech);
      progress(0.12, '划分说话人片段 · ' + threads + ' 线程 · 有效音频 ' +
        (packed.samples.length / 16000).toFixed(1) + ' 秒');
      let began = Date.now();
      let raw = diarizer.process(packed.samples).map((s: OfflineSpeakerDiarizationSegment): RecordingSegment => ({
        id: 0, start: Math.max(0, s.start), end: Math.min(packed.samples.length / 16000, s.end),
        speaker: s.speaker, text: '', language: '' }));
      chunk.turns = addUnassigned(restoreRecordingSpeechTurns(raw, packed.spans), chunk.speech);
      chunk.analysis.timings!.push({ chunk: index, stage: 'diarization', milliseconds: Date.now() - began,
        audioSeconds: packed.samples.length / 16000, threads: threads });
      checkpoint.saveCurrent(chunk);
    }
    let turns = chunk.turns;
    if (!chunk.mapped) {
      progress(0.72, '整理说话人声纹');
      if (extractor === null) {
        let config = new SpeakerEmbeddingExtractorConfig(); config.model = dir + 'speaker.onnx'; config.numThreads = threads;
        extractor = new SpeakerEmbeddingExtractor(config);
      }
      let began = Date.now(); let used: number[] = []; let mapping: Map<number, number> = new Map();
      for (let turn of turns) {
        if (turn.speaker >= 0 && !mapping.has(turn.speaker)) {
          let embedding = embeddingFor(turn.speaker, turns, samples, extractor);
          let id = globalSpeaker(embedding, chunk.analysis.speakers, used); mapping.set(turn.speaker, id); used.push(id);
        }
      }
      for (let turn of turns) { turn.speaker = turn.speaker < 0 ? -1 : mapping.get(turn.speaker)!; }
      chunk.mapped = true;
      chunk.analysis.timings!.push({ chunk: index, stage: 'speaker-matching', milliseconds: Date.now() - began,
        audioSeconds: samples.length / 16000, threads: threads });
      checkpoint.saveCurrent(chunk);
    }
    if (recognizer === null && chunk.nextTurn < turns.length) {
      progress(0.8, '加载多语种转写模型');
      let asrConfig = new OfflineRecognizerConfig();
      asrConfig.modelConfig.senseVoice.model = dir + 'sensevoice.int8.onnx';
      asrConfig.modelConfig.senseVoice.language = job.language === 'auto' ? '' : job.language;
      asrConfig.modelConfig.senseVoice.useItn = true; asrConfig.modelConfig.tokens = dir + 'tokens.txt';
      asrConfig.modelConfig.numThreads = threads; asrConfig.modelConfig.debug = false;
      recognizer = new OfflineRecognizer(asrConfig);
    }
    for (let i = chunk.nextTurn; i < turns.length; i++) {
      // Report before decode, so the first recognition is timed as ASR too.
      progress(0.8 + 0.19 * i / turns.length, '转写片段 ' + (i + 1) + ' / ' + turns.length);
      let began = Date.now();
      let turn = turns[i]; let stream = recognizer!.createStream();
      stream.acceptWaveform({ samples: samples.subarray(Math.floor(turn.start * 16000), Math.floor(turn.end * 16000)), sampleRate: 16000 });
      recognizer!.decode(stream); let text = recognizer!.getResult(stream);
      let id = turn.speaker;
      let speaker = chunk.analysis.speakers.find((s: RecordingSpeaker): boolean => s.id === id);
      if (!speaker) {
        speaker = { id: -1, name: job.diarization === true ? '未区分' : '录音', seconds: 0, embedding: [] };
        chunk.analysis.speakers.push(speaker);
      }
      speaker.seconds += turn.end - turn.start;
      chunk.analysis.segments.push({ id: chunk.analysis.segments.length, start: start + turn.start, end: start + turn.end,
        speaker: id, text: text.text.replace(/<\|[^|]*\|>/g, '').trim(), language: text.lang || job.language });
      let timing = chunk.analysis.timings!.find((t): boolean => t.stage === 'asr');
      if (timing) {
        timing.milliseconds += Date.now() - began; timing.audioSeconds += turn.end - turn.start;
      } else {
        chunk.analysis.timings!.push({ chunk: index, stage: 'asr', milliseconds: Date.now() - began,
          audioSeconds: turn.end - turn.start, threads: threads });
      }
      chunk.nextTurn = i + 1; checkpoint.saveCurrent(chunk);
    }
    checkpoint.finishChunk(chunk, start);
    let timing = chunk.analysis.timings!;
    // DebugSettings/AppStorage belong to the UI thread. Send diagnostics there
    // after committing the checkpoint; never import the UI logger in a Worker.
    let diagnostic: RecordingWorkerMessage = { kind: 'diagnostic', progress: 0, result: null,
      message: 'chunk=' + (index + 1) + '/' + count + ' threads=' + threads + ' stages=' +
        timing.map((t): string => t.stage + ':' + t.milliseconds + 'ms/' + t.audioSeconds.toFixed(1) + 's').join(',') };
    port.postMessage(diagnostic);
    progress(1, '本段已保存');
  }
  return checkpoint.state.analysis;
}
port.onmessage = (event: MessageEvents): void => {
  try {
    let result = analyze(event.data as RecordingJob);
    let value: RecordingWorkerMessage = { kind: 'done', progress: 100, message: '分析完成', result: result }; port.postMessage(value);
  } catch (e) {
    let value: RecordingWorkerMessage = { kind: 'error', progress: 0, message: (e as Error).message, result: null }; port.postMessage(value);
  }
};
