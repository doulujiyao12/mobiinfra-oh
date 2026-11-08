import { worker, ThreadWorkerGlobalScope, MessageEvents } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { fileIo as fs, statfs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { createDetector, VoiceDetector } from 'libvoicevad.so';
import { CaptureCommand, CaptureEvent, RecordingInfo, RecordingMode } from '../model/RecorderModels';
import { AudioGate, GateSink } from '../core/AudioGate';
import { alignedPcmBytes, createWavHeader, isOwnWavHeader, MAX_SESSION_SECONDS,
  parseRecordingName, triggeredFileName, SEGMENT_SECONDS, WAV_HEADER_BYTES } from '../core/Wav';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const SPACE_RESERVE: number = 32 * 1024 * 1024;
let directory: string = '';
let capturer: audio.AudioCapturer | undefined = undefined;
let file: fs.File | undefined = undefined;
let activeName: string = '';
let inputRate: number = 16000;
let sessionTime: number = 0;
let segmentIndex: number = 0;
let segmentBytes: number = 0;
let sessionBytes: number = 0;
let running: boolean = false;
let starting: boolean = false;
let closing: boolean = false;
let lastMeterAt: number = 0;
let checkpointTimer: number = -1;
let lastSpaceCheck: number = 0;
let startedAt: number = 0;
let lastAudioAt: number = 0;
let recoveredCount: number = 0;
let mode: RecordingMode = 'sound';
let gate: AudioGate | undefined = undefined;
let voiceDetector: VoiceDetector | undefined = undefined;
let listenedSamples: number = 0;
let segmentTime: number = 0;

function errorText(error: BusinessError): string {
  return `${error.message || '系统操作失败'}${error.code ? ` (${error.code})` : ''}`;
}

function send(kind: string, message: string = ''): void {
  const event: CaptureEvent = new CaptureEvent();
  event.kind = kind;
  event.message = message;
  event.durationMs = sessionBytes / (inputRate * 2) * 1000;
  event.segment = segmentIndex;
  event.inputRate = inputRate;
  event.listeningMs = listenedSamples / inputRate * 1000;
  event.saving = file !== undefined;
  port.postMessage(event);
}

function freeBytes(): number {
  return statfs.getFreeSizeSync(directory);
}

// Explicit seeking avoids ambiguous offsets and handles short filesystem writes.
function writeAt(fd: number, buffer: ArrayBuffer, position: number): void {
  let done: number = 0;
  while (done < buffer.byteLength) {
    fs.lseek(fd, position + done, fs.WhenceType.SEEK_SET);
    const chunk: ArrayBuffer = done === 0 ? buffer : buffer.slice(done);
    const written: number = fs.writeSync(fd, chunk);
    if (written <= 0) { throw new Error('存储空间不足或文件写入失败'); }
    done += written;
  }
}

function checkpoint(): void {
  if (file === undefined) { return; }
  writeAt(file.fd, createWavHeader(segmentBytes, inputRate), 0);
  fs.fsyncSync(file.fd);
}

function openSegment(timestamp: number): void {
  segmentIndex++;
  segmentTime = timestamp;
  activeName = triggeredFileName(timestamp, segmentIndex, inputRate, mode);
  const path: string = `${directory}/${activeName}.part`;
  if (fs.accessSync(path) || fs.accessSync(`${directory}/${activeName}`)) {
    throw new Error('录音文件名冲突，请重新开始录音');
  }
  file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
  segmentBytes = 0;
  writeAt(file.fd, createWavHeader(0, inputRate), 0);
  fs.fsyncSync(file.fd);
}

function finishSegment(): void {
  if (file === undefined) { return; }
  const path: string = `${directory}/${activeName}.part`;
  try {
    checkpoint();
  } finally {
    fs.closeSync(file.fd);
    file = undefined;
  }
  if (segmentBytes > 0) {
    fs.renameSync(path, `${directory}/${activeName}`);
  } else {
    fs.unlinkSync(path);
  }
}

function listRecords(): RecordingInfo[] {
  const result: RecordingInfo[] = [];
  const names: string[] = fs.listFileSync(directory);
  names.forEach((name: string) => {
    const parsed = parseRecordingName(name);
    if (parsed === undefined || parsed.partial) { return; }
    const stat: fs.Stat = fs.statSync(`${directory}/${name}`);
    if (stat.size <= WAV_HEADER_BYTES) { return; }
    const info: RecordingInfo = new RecordingInfo();
    info.name = name;
    info.path = `${directory}/${name}`;
    info.createdAt = parsed.version === 2 ? parsed.timestamp :
      parsed.timestamp + (parsed.segment - 1) * SEGMENT_SECONDS * 1000;
    info.segment = parsed.segment;
    info.bytes = stat.size;
    info.mode = parsed.mode;
    info.durationMs = alignedPcmBytes(stat.size - WAV_HEADER_BYTES) / (parsed.sampleRate * 2) * 1000;
    result.push(info);
  });
  return result.sort((a: RecordingInfo, b: RecordingInfo) => b.createdAt - a.createdAt);
}

function publishLibrary(): void {
  const event: CaptureEvent = new CaptureEvent();
  event.kind = 'library';
  event.records = listRecords();
  event.availableBytes = freeBytes();
  event.recoveredCount = recoveredCount;
  recoveredCount = 0;
  port.postMessage(event);
}

function recoverPartialFiles(): string {
  let warning: string = '';
  const names: string[] = fs.listFileSync(directory);
  names.forEach((name: string) => {
    const parsed = parseRecordingName(name);
    if (parsed === undefined || !parsed.partial) { return; }
    try {
    const path: string = `${directory}/${name}`;
    const size: number = fs.statSync(path).size;
    if (size <= WAV_HEADER_BYTES) {
      fs.unlinkSync(path);
      return;
    }
    const handle: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE);
    try {
      const header: ArrayBuffer = new ArrayBuffer(WAV_HEADER_BYTES);
      const count: number = fs.readSync(handle.fd, header);
      if (count !== WAV_HEADER_BYTES || !isOwnWavHeader(header, parsed.sampleRate)) {
        throw new Error('未完成录音的文件头损坏，原文件已保留');
      }
      const dataBytes: number = alignedPcmBytes(size - WAV_HEADER_BYTES);
      fs.truncateSync(handle.fd, dataBytes + WAV_HEADER_BYTES);
      writeAt(handle.fd, createWavHeader(dataBytes, parsed.sampleRate), 0);
      fs.fsyncSync(handle.fd);
    } finally {
      fs.closeSync(handle.fd);
    }
    const target: string = path.slice(0, -5);
    if (fs.accessSync(target)) { throw new Error('恢复录音时发现重名文件，原文件已保留'); }
    fs.renameSync(path, target);
    recoveredCount++;
    } catch (error) {
      warning = errorText(error as BusinessError);
    }
  });
  return warning;
}

function requestStop(reason: string): void {
  if (closing) { return; }
  // Never call capturer stop/release from inside readData itself.
  closing = true;
  setTimeout(() => {
    commands = commands.then(() => stopCapture(reason)).catch((error: BusinessError) => send('error', errorText(error)));
  }, 0);
}

function writeAudio(buffer: ArrayBuffer): void {
  let consumed: number = 0;
  const segmentLimit: number = inputRate * 2 * SEGMENT_SECONDS;
  while (consumed < buffer.byteLength) {
    if (file === undefined) { throw new Error('录音片段尚未打开'); }
    if (segmentBytes === segmentLimit) {
      const nextTime: number = segmentTime + SEGMENT_SECONDS * 1000;
      finishSegment();
      openSegment(nextTime);
      send('segment', '上一片段已保存，监听继续');
    }
    const length: number = Math.min(buffer.byteLength - consumed, segmentLimit - segmentBytes);
    const chunk: ArrayBuffer = buffer.slice(consumed, consumed + length);
    writeAt(file!.fd, chunk, WAV_HEADER_BYTES + segmentBytes);
    segmentBytes += length;
    sessionBytes += length;
    consumed += length;
  }
}

const gateSink: GateSink = {
  begin: (startSample: number): void => {
    openSegment(sessionTime + startSample / inputRate * 1000);
    send('activity');
  },
  write: (pcm: ArrayBuffer): void => { writeAudio(pcm); },
  end: (): void => {
    finishSegment();
    send('activity', '片段已保存，继续等待');
  }
};

function consume(buffer: ArrayBuffer): void {
  if (!running || closing || gate === undefined || buffer.byteLength === 0) { return; }
  try {
    lastAudioAt = Date.now();
    if (buffer.byteLength % 2 !== 0) { throw new Error('收到不完整的 PCM 音频帧'); }
    const sampleLimit: number = inputRate * MAX_SESSION_SECONDS;
    const acceptedBytes: number = Math.min(buffer.byteLength, (sampleLimit - listenedSamples) * 2);
    listenedSamples += acceptedBytes / 2;
    gate.consume(acceptedBytes === buffer.byteLength ? buffer : buffer.slice(0, acceptedBytes), gateSink);
    const now: number = Date.now();
    if (now - lastMeterAt >= 200) {
      const event: CaptureEvent = new CaptureEvent();
      event.kind = 'meter';
      event.durationMs = sessionBytes / (inputRate * 2) * 1000;
      event.level = gate.level();
      event.segment = segmentIndex;
      event.inputRate = inputRate;
      event.listeningMs = listenedSamples / inputRate * 1000;
      event.saving = gate.isSaving();
      port.postMessage(event);
      lastMeterAt = now;
    }
    if (listenedSamples >= sampleLimit) { requestStop('已达到单次 6 小时监听上限，已有录音已保存'); }
  } catch (error) {
    requestStop(`录音已停止：${errorText(error as BusinessError)}`);
  }
}

async function createCapturer(): Promise<audio.AudioCapturer> {
  const rates: audio.AudioSamplingRate[] = [audio.AudioSamplingRate.SAMPLE_RATE_16000,
    audio.AudioSamplingRate.SAMPLE_RATE_48000];
  for (let i: number = 0; i < rates.length; i++) {
    try {
      const result: audio.AudioCapturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: rates[i], channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
      });
      inputRate = rates[i];
      return result;
    } catch (error) {
      if (i === rates.length - 1) { throw new Error(errorText(error as BusinessError)); }
    }
  }
  throw new Error('当前设备不支持录音');
}

async function startCapture(selectedMode: RecordingMode): Promise<void> {
  if (starting || running || closing) { throw new Error('录音状态正在切换'); }
  if (directory.length === 0) { throw new Error('存储尚未初始化'); }
  if (freeBytes() < SPACE_RESERVE * 2) { throw new Error('可用空间不足 64 MB，请先删除部分录音'); }
  starting = true;
  if (selectedMode !== 'sound' && selectedMode !== 'speech') { throw new Error('未知的录音模式'); }
  mode = selectedMode;
  segmentIndex = 0;
  sessionBytes = 0;
  segmentBytes = 0;
  lastMeterAt = 0;
  listenedSamples = 0;
  try {
    capturer = await createCapturer();
    if (mode === 'speech') { voiceDetector = createDetector(inputRate, 2); }
    gate = new AudioGate(inputRate, mode, (pcm: ArrayBuffer): boolean => {
      if (voiceDetector === undefined) { throw new Error('人声检测器不可用，请重新开始监听'); }
      return voiceDetector.process(pcm);
    });
    capturer.on('readData', consume);
    capturer.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
        requestStop('麦克风被电话或其他应用占用，已有录音已保存');
      }
    });
    capturer.on('stateChange', (state: audio.AudioState) => {
      if (running && !closing && state === audio.AudioState.STATE_STOPPED) {
        requestStop('系统已停止录音，已有内容已保存');
      }
    });
    sessionTime = Date.now();
    startedAt = sessionTime;
    running = true;
    await capturer.start();
    lastAudioAt = startedAt;
    lastSpaceCheck = startedAt;
    checkpointTimer = setInterval(() => {
      try {
        if (!running || closing) { return; }
        checkpoint();
        if (Date.now() - startedAt >= MAX_SESSION_SECONDS * 1000) {
          requestStop('已达到单次 6 小时监听上限，已有录音已保存');
        }
        if (Date.now() - lastAudioAt > 10000) {
          requestStop('麦克风数据已中断，请检查权限并重新开始录音');
        }
        if (Date.now() - lastSpaceCheck >= 10000) {
          lastSpaceCheck = Date.now();
          if (freeBytes() < SPACE_RESERVE) { requestStop('剩余空间不足，已有录音已保存'); }
        }
      } catch (error) { requestStop(`文件保存异常：${errorText(error as BusinessError)}`); }
    }, 5000);
    send('started');
  } finally {
    starting = false;
  }
}

async function stopCapture(reason: string): Promise<void> {
  closing = true;
  running = false;
  if (checkpointTimer !== -1) { clearInterval(checkpointTimer); checkpointTimer = -1; }
  let failure: string = '';
  const current: audio.AudioCapturer | undefined = capturer;
  capturer = undefined;
  if (current !== undefined) {
    try {
      current.off('readData');
      if (current.state === audio.AudioState.STATE_RUNNING) { await current.stop(); }
    } catch (error) { failure = errorText(error as BusinessError); }
    try { await current.release(); } catch (error) { failure = errorText(error as BusinessError); }
  }
  try { gate?.flush(gateSink); } catch (error) { failure = errorText(error as BusinessError); }
  gate = undefined;
  try { voiceDetector?.close(); } catch (error) { failure = errorText(error as BusinessError); }
  voiceDetector = undefined;
  try { finishSegment(); } catch (error) {
    failure = `文件待恢复，请重新打开应用。${errorText(error as BusinessError)}`;
  }
  closing = false;
  starting = false;
  const notice: string = reason === '监听已结束' ?
    (sessionBytes > 0 ? '监听已结束，录音已保存' : '监听已结束，没有检测到可保存的片段') : reason;
  send('stopped', failure.length > 0 ? failure : notice);
  publishLibrary();
}

async function dispatch(command: CaptureCommand): Promise<void> {
  if (command.kind === 'init') {
    directory = `${command.filesDir}/recordings`;
    if (!fs.accessSync(directory)) { fs.mkdirSync(directory); }
    let recoveryWarning: string = '';
    try { recoveryWarning = recoverPartialFiles(); } catch (error) {
      recoveryWarning = errorText(error as BusinessError);
    }
    publishLibrary();
    send('ready', recoveryWarning);
  } else if (command.kind === 'start') {
    try { await startCapture(command.mode || 'sound'); } catch (error) {
      await stopCapture(`无法录音：${errorText(error as BusinessError)}`);
    }
  } else if (command.kind === 'stop') {
    if (!closing) { await stopCapture(command.reason || '监听已结束'); }
  } else if (command.kind === 'list') {
    publishLibrary();
  } else if (command.kind === 'delete') {
    if (running || starting || closing) { throw new Error('请先结束录音再删除文件'); }
    const parsed = parseRecordingName(command.name);
    if (parsed === undefined || parsed.partial) { throw new Error('无效录音文件'); }
    fs.unlinkSync(`${directory}/${command.name}`);
    publishLibrary();
    send('deleted', '录音已删除');
  }
}

// Serialize commands even while audio initialization / release is awaiting the system.
let commands: Promise<void> = Promise.resolve();
port.onmessage = (event: MessageEvents): void => {
  const command: CaptureCommand = event.data as CaptureCommand;
  commands = commands.then(() => dispatch(command)).catch((error: BusinessError) => {
    send('error', errorText(error));
  });
};
