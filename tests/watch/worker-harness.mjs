import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { loadSdkTypeScript } from './sdk-paths.mjs';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ts = loadSdkTypeScript();

export async function createHarness(filesDir, options = {}) {
  const events = [];
  const handles = new Map();
  const intervalCallbacks = new Map();
  const microphones = [];
  const workerPort = { postMessage: event => events.push(event), onmessage: undefined };
  const state = { freeBytes: 2 ** 30, now: Date.now(), detectorCalls: 0, detectorCloses: 0 };
  let nextInterval = 1;
  let syncs = 0;
  const fileIo = {
    OpenMode: { CREATE: 64, READ_WRITE: 2, READ_ONLY: 0 },
    WhenceType: { SEEK_SET: 0 },
    accessSync: value => fs.existsSync(value),
    mkdirSync: value => fs.mkdirSync(value),
    listFileSync: value => fs.readdirSync(value),
    statSync: value => fs.statSync(value),
    openSync: (value, flags) => {
      const fd = fs.openSync(value, flags & 64 ? 'w+' : flags & 2 ? 'r+' : 'r');
      handles.set(fd, 0);
      return { fd };
    },
    closeSync: fd => { fs.closeSync(fd); handles.delete(fd); },
    lseek: (fd, position) => { handles.set(fd, position); return position; },
    readSync: (fd, buffer) => {
      const count = fs.readSync(fd, Buffer.from(buffer), 0, buffer.byteLength, handles.get(fd));
      handles.set(fd, handles.get(fd) + count);
      return count;
    },
    writeSync: (fd, buffer) => {
      const length = Math.min(buffer.byteLength, options.maxWrite || Infinity);
      const count = fs.writeSync(fd, Buffer.from(buffer), 0, length, handles.get(fd));
      handles.set(fd, handles.get(fd) + count);
      return count;
    },
    fsyncSync: fd => { syncs++; fs.fsyncSync(fd); },
    truncateSync: (fd, length) => fs.ftruncateSync(fd, length),
    renameSync: (from, to) => fs.renameSync(from, to),
    unlinkSync: value => fs.unlinkSync(value)
  };
  const audio = {
    AudioSamplingRate: { SAMPLE_RATE_16000: 16000, SAMPLE_RATE_48000: 48000 },
    AudioChannel: { CHANNEL_1: 1 },
    AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
    SourceType: { SOURCE_TYPE_MIC: 0 },
    AudioState: { STATE_RUNNING: 2, STATE_STOPPED: 3 },
    InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3 },
    createAudioCapturer: async config => {
      if (options.reject16k && config.streamInfo.samplingRate === 16000) { throw new Error('unsupported'); }
      const callbacks = new Map();
      const microphone = {
        state: 1, config, callbacks,
        on: (name, callback) => callbacks.set(name, callback),
        off: name => callbacks.delete(name),
        start: async () => { microphone.state = 2; },
        stop: async () => { microphone.state = 3; },
        release: async () => { microphone.state = 4; }
      };
      microphones.push(microphone);
      return microphone;
    }
  };
  const sdk = {
    '@kit.ArkTS': { worker: { workerPort } },
    '@kit.AudioKit': { audio },
    '@kit.CoreFileKit': { fileIo, statfs: { getFreeSizeSync: () => state.freeBytes } },
    'libvoicevad.so': {
      createDetector: (rate, mode) => {
        if (options.failDetector) { throw new Error('无法初始化人声检测器'); }
        return {
          process: pcm => {
            state.detectorCalls++;
            if (pcm.byteLength !== rate / 50 * 2) { throw new Error('invalid VAD frame'); }
            if (!options.speechClassifier) { throw new Error('Provide an explicit speech test classifier'); }
            return options.speechClassifier(pcm, rate, mode);
          },
          close: () => { state.detectorCloses++; }
        };
      }
    },
    '@kit.BasicServicesKit': {}
  };
  const sandbox = vm.createContext({
    console, ArrayBuffer, DataView, Int16Array,
    Date: class extends Date { static now() { return state.now; } },
    setTimeout, clearTimeout,
    setInterval: callback => { const id = nextInterval++; intervalCallbacks.set(id, callback); return id; },
    clearInterval: id => intervalCallbacks.delete(id)
  });
  const modules = new Map();
  function load(filename) {
    if (modules.has(filename)) { return modules.get(filename).exports; }
    const module = { exports: {} };
    modules.set(filename, module);
    const source = fs.readFileSync(filename, 'utf8');
    const transformed = ts.transpileModule(source, {
      fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const localRequire = name => {
      if (name in sdk) { return sdk[name]; }
      const base = path.resolve(path.dirname(filename), name);
      const actual = ['.ts', '.ets'].map(ext => base + ext).find(value => fs.existsSync(value));
      if (!actual) { throw new Error(`Unmocked dependency: ${name}`); }
      return load(actual);
    };
    const wrapper = vm.runInContext(`(function(require, module, exports) { ${transformed}\n})`, sandbox,
      { filename });
    wrapper(localRequire, module, module.exports);
    return module.exports;
  }
  load(path.join(project, 'watch_entry/src/main/ets/workers/RecorderWorker.ets'));
  const drain = () => new Promise(resolve => setTimeout(resolve, 15));
  const post = async command => { workerPort.onmessage({ data: command }); await drain(); };
  await post({ kind: 'init', filesDir });
  return {
    events, state, microphones, post, drain,
    get syncs() { return syncs; },
    capture: buffer => {
      const mic = microphones.at(-1);
      state.now += buffer.byteLength / (mic.config.streamInfo.samplingRate * 2) * 1000;
      mic.callbacks.get('readData')(buffer);
    },
    interrupt: async () => {
      microphones.at(-1).callbacks.get('audioInterrupt')({ hintType: 2 });
      await drain();
    },
    checkpoint: async () => { for (const callback of intervalCallbacks.values()) { callback(); } await drain(); },
    dispose: () => {
      intervalCallbacks.clear();
      for (const fd of handles.keys()) { fs.closeSync(fd); }
      handles.clear();
    }
  };
}
