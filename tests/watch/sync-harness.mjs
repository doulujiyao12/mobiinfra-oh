import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadSdkTypeScript } from './sdk-paths.mjs';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ts = loadSdkTypeScript();

export function createSyncHarness(filesDir) {
  const handles = new Map();
  const timeouts = new Set();
  const intervals = new Map();
  const state = {
    now: Date.now(), maxWrite: Infinity, failRename: false, messages: [], transfers: [], registrations: [],
    background: [], receivers: new Set(), serviceDie: new Set(), taskCancel: new Set(),
    devices: [{ randomId: 'paired-phone-1', name: 'Test HarmonyOS phone', category: 1, osCategory: 1 }],
    installed: true, sendFailures: 0, phoneReceivers: new Set(), phoneFileReceivers: new Set(),
    autoTransfer: false, corruptNextTransfer: false, dropAckReplies: 0, fastRequestTimeout: 0,
    phoneRegistrations: [], deferBackground: false, releaseBackground: undefined
  };
  const io = {
    OpenMode: { CREATE: 64, READ_WRITE: 2, READ_ONLY: 0, TRUNC: 512 },
    WhenceType: { SEEK_SET: 0 },
    accessSync: name => fs.existsSync(name),
    statSync: name => fs.statSync(name),
    listFileSync: name => fs.readdirSync(name),
    readTextSync: name => fs.readFileSync(name, 'utf8'),
    mkdirSync: name => fs.mkdirSync(name),
    unlinkSync: name => fs.unlinkSync(name),
    copyFile: async (from, to) => fs.copyFileSync(typeof from === 'number' ? handles.get(from).path : from, to),
    openSync: (name, flags) => {
      const mode = flags & 512 ? 'w+' : flags & 64 ? (fs.existsSync(name) ? 'r+' : 'w+') : flags & 2 ? 'r+' : 'r';
      const fd = fs.openSync(name, mode);
      handles.set(fd, { position: 0, path: name });
      return { fd, path: name, name: path.basename(name) };
    },
    readSync: (fd, buffer) => {
      const file = handles.get(fd);
      const length = fs.readSync(fd, Buffer.from(buffer), 0, buffer.byteLength, file.position);
      file.position += length; return length;
    },
    writeSync: (fd, buffer) => {
      const file = handles.get(fd);
      const length = fs.writeSync(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, state.maxWrite), file.position);
      file.position += length; return length;
    },
    fsyncSync: fd => fs.fsyncSync(fd),
    closeSync: fd => { fs.closeSync(fd); handles.delete(fd); },
    renameSync: (from, to) => {
      if (state.failRename) { throw new Error('simulated durable journal failure'); }
      fs.renameSync(from, to);
    }
  };
  const client = {
    isRemoteAppInstalled: async () => state.installed,
    registerMessageReceiver: async (id, app, receiver) => {
      state.registrations.push({ id, app }); state.receivers.add(receiver);
    },
    unregisterMessageReceiver: async (_id, _app, receiver) => state.receivers.delete(receiver),
    sendMessage: async (_id, app, message) => {
      if (state.sendFailures-- > 0) { throw new Error('temporary radio failure'); }
      const response = JSON.parse(new TextDecoder().decode(message.content));
      state.messages.push(response);
      if (response.type === 'RECORDING_ACKED' && state.dropAckReplies > 0) { state.dropAckReplies--; }
      else { for (const receiver of state.phoneReceivers) { queueMicrotask(() => receiver(message)); } }
      return { code: 207 };
    },
    transferFile: (id, app, file, callback) => {
      if (!handles.has(file.file.fd)) { throw new Error('closed descriptor passed to Wear Engine'); }
      state.transfers.push({ id, app, file, callback });
      if (state.autoTransfer) {
        queueMicrotask(() => {
          const receivedPath = path.join(filesDir, `native-received-${state.transfers.length}.wav`);
          fs.copyFileSync(handles.get(file.file.fd).path, receivedPath);
          if (state.corruptNextTransfer) {
            state.corruptNextTransfer = false;
            const bytes = fs.readFileSync(receivedPath); bytes[bytes.length - 1] ^= 1; fs.writeFileSync(receivedPath, bytes);
          }
          for (const receiver of state.phoneFileReceivers) {
            receiver({ file: io.openSync(receivedPath, 0) });
          }
          callback(undefined, { progress: 100 }); callback(undefined, { code: 207 });
        });
      }
    },
    cancelFileTransfer: async () => ({ code: 207 })
  };
  let nextInterval = 0;
  const globals = {
    console, ArrayBuffer, DataView, Int16Array, Uint8Array,
    Date: class extends Date { static now() { return state.now; } },
    canIUse: () => true,
    setTimeout: (callback, ms) => {
      const timer = setTimeout(() => { timeouts.delete(timer); callback(); },
        ms === 15000 && state.fastRequestTimeout ? state.fastRequestTimeout : ms);
      timeouts.add(timer); return timer;
    },
    clearTimeout: timer => { clearTimeout(timer); timeouts.delete(timer); },
    setInterval: callback => { const id = ++nextInterval; intervals.set(id, callback); return id; },
    clearInterval: id => intervals.delete(id)
  };
  function createLoader(sdk) {
    const context = vm.createContext(globals);
    const modules = new Map();
    function load(name) {
      const filename = path.isAbsolute(name) ? name : path.join(project, 'watch_entry/src/main/ets', name);
      if (modules.has(filename)) { return modules.get(filename).exports; }
      const module = { exports: {} }; modules.set(filename, module);
      const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
        fileName: filename.replace(/\.ets$/, '.ts'),
        compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
      }).outputText;
      const localRequire = name => {
        if (name in sdk) { return sdk[name]; }
        const base = path.resolve(path.dirname(filename), name);
        const found = ['.ts', '.ets'].map(ext => base + ext).find(name => fs.existsSync(name));
        if (!found) { throw new Error('Unmocked dependency ' + name); }
        return load(found);
      };
      vm.runInContext(`(function(require,module,exports){${code}\n})`, context, { filename })(localRequire, module, module.exports);
      return module.exports;
    }
    return load;
  }
  const util = {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes) }) }
  };
  const sdk = {
    '@kit.CoreFileKit': { fileIo: io, hash: { hash: async name => crypto.createHash('sha256').update(fs.readFileSync(name)).digest('hex') } },
    '@kit.ArkTS': { util, worker: {} },
    '@kit.AbilityKit': { wantAgent: {
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({})
    } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      on: (_event, cb) => state.taskCancel.add(cb), off: (_event, cb) => state.taskCancel.delete(cb),
      startBackgroundRunning: async (_context, modes) => {
        state.background.push(['start', [...modes]]);
        if (state.deferBackground) { await new Promise(resolve => { state.releaseBackground = resolve; }); }
        return {};
      },
      updateBackgroundRunning: async (_context, modes) => { state.background.push(['update', [...modes]]); return {}; },
      stopBackgroundRunning: async () => { state.background.push(['stop', []]); }
    } },
    '@kit.BasicServicesKit': {},
    '@kit.WearEngine': { wearEngine: {
      DeviceCategory: { DEFAULT: 1 }, P2pResultCode: { COMMUNICATION_SUCCESS: 207 },
      getDeviceClient: () => ({ getConnectedDevices: async () => state.devices }), getP2pClient: () => client,
      on: (_event, cb) => state.serviceDie.add(cb), off: (_event, cb) => state.serviceDie.delete(cb)
    } }
  };
  sdk['@kit.ArkTS'].worker.ThreadWorker = class {
    constructor() {
      this.active = true;
      this.port = { postMessage: result => {
        if (this.active) { queueMicrotask(() => this.onmessage?.({ data: structuredClone(result) })); }
      } };
      const workerSdk = { ...sdk, '@kit.ArkTS': { util, worker: { workerPort: this.port } } };
      createLoader(workerSdk)('workers/SyncWorker.ets');
    }
    postMessage(command) { if (this.active) { this.port.onmessage({ data: structuredClone(command) }); } }
    terminate() { this.active = false; }
  };
  const load = createLoader(sdk);
  const phoneClient = {
    isRemoteAppInstalled: async () => true,
    registerMessageReceiver: async (id, app, receiver) => { state.phoneRegistrations.push({ id, app }); state.phoneReceivers.add(receiver); },
    unregisterMessageReceiver: async (_id, _app, receiver) => state.phoneReceivers.delete(receiver),
    registerFileReceiver: async (_id, _app, receiver) => state.phoneFileReceivers.add(receiver),
    unregisterFileReceiver: async (_id, _app, receiver) => state.phoneFileReceivers.delete(receiver),
    startRemoteApp: async () => ({ code: 207 }),
    sendMessage: async (_id, _app, message) => {
      for (const receiver of state.receivers) { queueMicrotask(() => receiver(message)); }
      return { code: 207 };
    }
  };
  const phoneSdk = { ...sdk, '@kit.WearEngine': { wearEngine: {
    DeviceCategory: { WATCH: 2 }, getP2pClient: () => phoneClient,
    getDeviceClient: () => ({ getConnectedDevices: async () => { if (state.deferPhoneDevices) await new Promise(resolve => { state.releasePhoneDevices = resolve; }); return [{ category: 2, randomId: 'test-watch' }]; } })
  } } };
  const phoneLoad = createLoader(phoneSdk);
  let requestId = 0;
  const request = async (type, extra = {}) => {
    const id = `phone_${++requestId}`;
    const wire = JSON.stringify({ protocol: 'clawmate.recordings', version: 1, requestId: id, type, ...extra });
    for (const receiver of state.receivers) { receiver({ content: new TextEncoder().encode(wire) }); }
    await waitFor(() => state.messages.some(message => message.requestId === id));
    return state.messages.find(message => message.requestId === id);
  };
  return {
    load, state, handles, request,
    phoneClient(context) {
      const module = phoneLoad(process.env.CLAWMATE_PHONE_CLIENT_SOURCE || path.join(project, 'phonebridge/src/main/ets/WatchRecordingClient.ets'));
      return new module.WatchRecordingClient(context);
    },
    async tick(ms = 5000) { state.now += ms; for (const callback of intervals.values()) { callback(); } await new Promise(r => setTimeout(r, 20)); },
    dispose() { for (const t of timeouts) { clearTimeout(t); } intervals.clear(); for (const fd of handles.keys()) { fs.closeSync(fd); } handles.clear(); }
  };
}

export async function waitFor(condition) {
  const deadline = Date.now() + 3000;
  while (!condition()) {
    if (Date.now() > deadline) { throw new Error('test condition timed out'); }
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}
