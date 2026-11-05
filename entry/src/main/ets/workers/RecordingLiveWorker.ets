import worker, { MessageEvents } from '@ohos.worker';
import { OfflineRecognizer, OfflineRecognizerConfig, Vad, VadConfig, SileroVadConfig, TenVadConfig } from 'sherpa_onnx';
import { readCapturedPcm } from '../utils/recording/RecordingWav';
import { RecordingLiveJob, RecordingLiveRequest, RecordingLiveUpdate } from '../utils/recording/RecordingLiveTypes';
import { RecordingSegment, SpeechRange } from '../utils/recording/RecordingTypes';
import { recordingAvailableThreads } from '../utils/recording/RecordingPerformance';

const port = worker.workerPort;
let job: RecordingLiveJob | null = null;
let vad: Vad | null = null;
let recognizer: OfflineRecognizer | null = null;
let processed = 0;
let finished = false;

function start(input: RecordingLiveJob): void {
  if (job !== null) { throw new Error('实时转写已经启动'); }
  job = input;
  const threads = Math.min(2, recordingAvailableThreads());
  vad = new Vad(new VadConfig(new SileroVadConfig(input.modelDir + '/silero_vad.onnx', 0.5, 0.5, 0.25, 512, 15),
    new TenVadConfig('', 0.5, 0.5, 0.25, 256), 16000, false, threads), 30);
  const config = new OfflineRecognizerConfig();
  config.modelConfig.senseVoice.model = input.modelDir + '/sensevoice.int8.onnx';
  config.modelConfig.senseVoice.language = input.language === 'auto' ? '' : input.language;
  config.modelConfig.senseVoice.useItn = true; config.modelConfig.tokens = input.modelDir + '/tokens.txt';
  config.modelConfig.numThreads = threads; config.modelConfig.debug = false;
  recognizer = new OfflineRecognizer(config);
}

function advance(end: number, final: boolean): RecordingLiveUpdate {
  if (job === null || vad === null || recognizer === null || finished || end < processed) { throw new Error('实时转写状态无效'); }
  const segments: RecordingSegment[] = []; const speech: SpeechRange[] = [];
  const drain = (): void => {
    while (!vad!.isEmpty()) {
      const range = vad!.front(false);
      const stop = Math.min(end, range.start + range.samples.length);
      if (stop - range.start >= 2400) {
        const stream = recognizer!.createStream();
        stream.acceptWaveform({ samples: range.samples.subarray(0, stop - range.start), sampleRate: 16000 });
        recognizer!.decode(stream);
        const result = recognizer!.getResult(stream);
        const text = result.text.replace(/<\|[^|]*\|>/g, '').trim();
        speech.push({ start: range.start / 16000, end: stop / 16000 });
        if (text) { segments.push({ id: segments.length, start: range.start / 16000, end: stop / 16000, speaker: -1, text: text, language: result.lang || job!.language }); }
      }
      vad!.pop();
    }
  };
  const samples = readCapturedPcm(job.audioPath, processed, end);
  for (let offset = 0; offset < samples.length; offset += 512) { vad.acceptWaveform(samples.subarray(offset, Math.min(offset + 512, samples.length))); drain(); }
  if (final) { vad.flush(); drain(); finished = true; }
  processed = end;
  return { kind: final ? 'done' : 'update', processed: processed, segments: segments, speech: speech, error: '' };
}

port.onmessage = (event: MessageEvents): void => {
  try {
    const request = event.data as RecordingLiveRequest;
    if (request.kind === 'start' && request.job) {
      start(request.job);
      const reply: RecordingLiveUpdate = { kind: 'ready', processed: 0, segments: [], speech: [], error: '' }; port.postMessage(reply);
    } else if ((request.kind === 'advance' || request.kind === 'finish') && request.end !== undefined) {
      port.postMessage(advance(request.end, request.kind === 'finish'));
    } else { throw new Error('实时转写请求无效'); }
  } catch (e) {
    const reply: RecordingLiveUpdate = { kind: 'error', processed: processed, segments: [], speech: [], error: (e as Error).message }; port.postMessage(reply);
  }
};
