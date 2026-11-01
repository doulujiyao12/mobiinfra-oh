// Node-side checks of production ArkTS logic. This does not compile ArkUI or build a HAP.
// Usage: node scripts/check_codex_logic.cjs [path-to-typescript-module]
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
const { gzipSync, gunzipSync } = require('node:zlib');
const root = path.resolve(__dirname, '..');
const cache = new Map();
let response = { statusCode: 200, body: new ArrayBuffer(2), toString: () => '{}' };
let sessionConfiguration;
let sentRequest;
let sessionCloses = 0;
let sessionCreates = 0;
let sessionCancels = 0;
let fetchCount = 0;
let fetchErrors = [];
let captureTimers = false;
let timerSequence = 1;
let timerJobs = [];
let fetchReplies = [];
let cancelledRequest;
let resolveFetch;
let deferred = false;
let resolveScan;
let resolveCamera;
let deferCamera = false;
let helpNavigation;
let cameraResult = { resultCode: 0, resultUri: '', mediaType: 'photo' };
let attachmentSize = 3;
const removedCameraFiles = [];
let uploadCount = 0;
const storedAssets = new Map();
const preferencesData = new Map();
const appStorage = new Map();
const dummy = () => {};
const decorator = () => dummy;
class Scroller { edges = []; scrollEdge(edge) { this.edges.push(edge); } }
function mockTimeout(callback, ms) {
  const id = timerSequence++;
  if (captureTimers) timerJobs.push({ id, callback, ms });
  else if (ms >= 600 && ms < 1200) queueMicrotask(callback);
  return id;
}
const asset = {
  Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, AUTH_TYPE: 5, SYNC_TYPE: 6, CONFLICT_RESOLUTION: 7,
    DATA_LABEL_CRITICAL_1: 8, DATA_LABEL_CRITICAL_2: 9, DATA_LABEL_CRITICAL_4: 10 },
  ReturnType: { ALL: 1, ATTRIBUTES: 2 }, Accessibility: { DEVICE_UNLOCKED: 2 }, AuthType: { NONE: 0 },
  SyncType: { NEVER: 0 }, ConflictResolution: { OVERWRITE: 1 },
  add: async attributes => { storedAssets.set(attributes.get(1).toString(), attributes); },
  query: async query => {
    const alias = query.get(asset.Tag.ALIAS);
    const group = query.get(asset.Tag.DATA_LABEL_CRITICAL_4);
    const items = [...storedAssets.values()].filter(item => alias ? item.get(asset.Tag.ALIAS).toString() === alias.toString() :
      item.get(asset.Tag.DATA_LABEL_CRITICAL_4)?.toString() === group?.toString());
    if (!items.length) throw Object.assign(new Error('Not found'), { code: 24000002 });
    return items.map(item => {
      const result = new Map(item);
      if (query.get(asset.Tag.RETURN_TYPE) === asset.ReturnType.ATTRIBUTES) result.delete(asset.Tag.SECRET);
      return result;
    });
  },
  remove: async query => { storedAssets.delete(query.get(1).toString()); }
};
let platformAccepted = true;
const kitMocks = {
  '@kit.AppGalleryKit': { privacyManager: {
    AppPrivacyType: { PRIVACY_AGREEMENT: 1, USER_AGREEMENT: 2 },
    AppPrivacyResultType: { DISAGREED: 0, FULL_MODE_AGREED: 1, REQUIRE_RESIGNING_VERSION_UPDATE: 2 },
    getAppPrivacyResult: () => [{type: 1, result: platformAccepted ? 1 : 0, id: 'fixture', versionCode: 1}]
  } },
  '@kit.ArkUI': { router: { pushUrl: async options => { helpNavigation = options; } } },
  '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { zlib: {
    ReturnStatus: { OK: 0, STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 },
    createZip: async () => {
      const state = {};
      return { getZStream: async () => state, inflateInit2: async (_stream, bits) => { assert.equal(bits, 31); return 0; },
        inflate: async stream => {
          const decoded = gunzipSync(Buffer.from(stream.nextIn), { maxOutputLength: stream.availableOut });
          Buffer.from(stream.nextOut).set(decoded); state.totalOut = decoded.length; state.availableIn = 0; return 1;
        }, inflateEnd: async () => 0 };
    }
  } }, '@kit.PreviewKit': {}, '@kit.CryptoArchitectureKit': {},
  '@kit.CoreFileKit': {
    fileIo: { OpenMode: { CREATE: 1, READ_WRITE: 2, READ_ONLY: 4 },
      open: async () => ({ fd: 1 }), close: async () => {}, stat: async () => ({ size: attachmentSize }),
      read: async (_fd, chunk, options) => Math.min(chunk.byteLength, attachmentSize - options.offset),
      unlink: async filename => { removedCameraFiles.push(filename); } },
    fileUri: { getUriFromPath: filename => 'file://' + filename, FileUri: class {
      constructor(uri) { this.name = uri.split('/').pop(); }
    } },
    picker: { DocumentSelectOptions: class {}, DocumentViewPicker: class {
      async select() { return ['file:///selected/notes.txt']; }
    } }
  },
  '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoSelectOptions: class {}, PhotoViewMIMETypes: { IMAGE_TYPE: 'image' },
    PhotoViewPicker: class { async select() { return { photoUris: ['file:///selected/photo.jpg'] }; } } } },
  '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_BACK: 0 } }, cameraPicker: {
    PickerMediaType: { PHOTO: 'photo' }, pick: async () => deferCamera ? new Promise(resolve => { resolveCamera = resolve; }) : cameraResult
  } },
  '@kit.NetworkKit': { http: {} },
  '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => preferencesData.get(key) ?? fallback,
    put: async (key, value) => { preferencesData.set(key, value); }, flush: async () => {}
  }) } },
  '@kit.ArkTS': { util: {
    TextEncoder: class { encodeInto(value) { return Buffer.from(value); } },
    TextDecoder: class { decodeWithStream(value) { return Buffer.from(value).toString(); } },
    Base64Helper: class {
      decodeSync(value) { return Buffer.from(value, 'base64'); }
      encodeToStringSync(value) { return Buffer.from(value).toString('base64'); }
    },
    generateRandomUUID: () => randomUUID()
  } },
  '@kit.AssetStoreKit': { asset },
  '@kit.ScanKit': { scanCore: { ScanType: { QR_CODE: 11 } },
    scanBarcode: { startScanForResult: () => new Promise(resolve => { resolveScan = resolve; }) } },
  '@kit.RemoteCommunicationKit': { rcp: {
    Request: class { constructor(url, method, headers, body) { Object.assign(this, { url, method, headers, body }); } },
    createSession: configuration => {
      sessionCreates++;
      sessionConfiguration = configuration;
      return {
        fetch: async request => {
          sentRequest = request; fetchCount++;
          if (fetchErrors.length) throw fetchErrors.shift();
          if (fetchReplies.length) return fetchReplies.shift();
          return deferred ? new Promise(resolve => { resolveFetch = resolve; }) : response;
        },
        close: () => { sessionCloses++; }, cancel: request => { sessionCancels++; cancelledRequest = request; }
      };
    }
  } }
};
function load(relative) {
  const filename = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets').replaceAll('\\', '/');
  if (cache.has(filename)) return cache.get(filename);
  if (/\/(AppTheme|AppHeader|FrostedPage|MarkdownView|CodexApprovalCard|CodexConnectionViews|CodexChatViews|CodexArtifactCard)\.ets$/.test(filename)) return {};
  if (filename.endsWith('/chat/ChatPageTypes.ets')) return { chatPageBackgroundColor: () => '#FFFFFF' };
  let source = fs.readFileSync(filename, 'utf8');
  if (filename.endsWith('/CodexPage.ets')) {
    source = source.slice(0, source.indexOf('  @Builder private')).replace('export struct CodexPage', 'export class CodexPage') + '}';
  }
  const compiled = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, experimentalDecorators: true
  }, reportDiagnostics: true, fileName: filename.replace(/\.ets$/, '.ts') });
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, ts.formatDiagnosticsWithColorAndContext(errors, {
    getCurrentDirectory: () => root, getCanonicalFileName: f => f, getNewLine: () => '\n'
  }));
  const module = { exports: {} };
  const context = { module, exports: module.exports, require: name => {
    if (Object.hasOwn(kitMocks, name)) return kitMocks[name];
    return load(path.resolve(path.dirname(filename), name));
  }, Buffer, Uint8Array, ArrayBuffer, Map, console, setTimeout: mockTimeout, Edge: { Top: 'top', Bottom: 'bottom' },
  clearTimeout: dummy, setInterval: () => 1, clearInterval: dummy, Scroller,
  Component: dummy, State: decorator, Prop: decorator, Link: decorator, Watch: decorator, StorageProp: decorator,
  canIUse: () => true,
  AppStorage: { get: k => appStorage.get(k), setOrCreate: (k, v) => appStorage.set(k, v) } };
  vm.runInNewContext(compiled.outputText, context, { filename });
  cache.set(filename, module.exports);
  return module.exports;
}

async function main() {
  const types = load('entry/src/main/ets/pages/codex/CodexTypes.ets');
  assert.equal(types.normalizeCodexOrigin(' https://Codex.example.com:8787/ '), 'https://codex.example.com:8787');
  assert.equal(types.normalizeCodexOrigin('https://[fd00::1]:8787'), 'https://[fd00::1]:8787');
  for (const value of ['http://host', 'https://user:pass@host', 'https://host/path', 'https://host?token=x',
    'https://host#x', 'https://host:0', 'https://host:65536', 'https://host\n.evil.com']) {
    assert.throws(() => types.normalizeCodexOrigin(value));
  }
  assert.equal(types.validCodexToken('a'.repeat(43)), true);
  assert.equal(types.validCodexToken('password'), false);
  assert.equal(types.codexLinkLabel(1000, 0, 2000), '已连接');
  assert.equal(types.codexLinkLabel(1000, 0, 27000), '正在确认连接');
  assert.equal(types.codexLinkLabel(1000, 2000, 3000), '连接已中断');
  assert.equal(types.codexLinkLabel(1000, 2000, 3000, true), '正在重连');
  assert.equal(types.codexLinkLabel(0, 0, 3000), '正在确认连接');
  const timeline = types.codexTimeline([
    { id: 't1:user', kind: 'user', text: 'create' }, { id: 't1:answer', kind: 'assistant', text: 'done' },
    { id: 'random', turnId: 't2', kind: 'assistant', text: 'second' }, { id: 't3:answer', kind: 'assistant', text: 'third' }
  ], [{ id: 'f1', turnId: 't1', name: 'a.pdf' }, { id: 'f2', turnId: 't2', name: 'b.pdf' },
    { id: 'old', turnId: 't0', name: 'old.pdf' }]);
  assert.equal(timeline[0].id, 'older-deliveries');
  assert.equal(timeline[2].artifacts[0].id, 'f1'); assert.equal(timeline[3].artifacts[0].id, 'f2');
  assert.equal(timeline[4].artifacts.length, 0, 'previous deliveries cannot float to the latest turn');
  assert.notEqual(types.codexTimelineKey({ id: 'one', item: { text: 'first' }, artifacts: [] }),
    types.codexTimelineKey({ id: 'one', item: { text: 'other' }, artifacts: [] }), 'equal-length streamed corrections refresh');
  const legacy = types.codexTimeline([{ id: 'a', kind: 'assistant', text: '[report](out/a.pdf)' },
    { id: 'b', kind: 'assistant', text: 'newer' }], [{ id: 'f', name: 'a.pdf' }]);
  assert.equal(legacy[0].artifacts[0].id, 'f'); assert.equal(legacy[1].artifacts.length, 0);
  const { TaskSync } = await import('../bridge/codex/task-sync.mjs');
  const sync = new TaskSync();
  let original = { id: 'a', revision: 1, items: [{ id: 'one', kind: 'assistant', text: 'hello' }, { id: 'remove', kind: 'tool', text: 'tool' }], artifacts: [] };
  sync.envelope(original, '', true);
  const nextTask = { ...original, revision: 2, items: [{ id: 'new', kind: 'user', text: 'new' },
    { id: 'one', kind: 'assistant', turnId: 'turn-one', text: 'hello world' }], artifacts: [{ id: 'file' }] };
  const patch = sync.envelope(nextTask, '1', true);
  assert.deepEqual(JSON.parse(JSON.stringify(types.mergeCodexTask(original, patch))), nextTask);
  assert.equal(original.items[0].text, 'hello', 'merge does not mutate the base snapshot');
  assert.throws(() => types.mergeCodexTask({ ...original, revision: 0 }, patch), /过期/);
  assert.throws(() => types.mergeCodexTask(null, patch), /过期/);
  assert.equal(types.mergeCodexTask(original, { unchanged: true }), undefined);
  assert.equal(types.codexTaskBusy('waitingApproval'), true);
  assert.equal(types.codexTaskBusy('completed'), false);
  assert.equal(types.codexApprovalLabel('auto'), '帮我批准'); assert.equal(types.codexApprovalLabel('full'), '完全访问控制');
  const waitingTask = { status: 'running', startedAt: 1000, lastActivityAt: 1000 };
  assert.equal(types.codexExecutionNotice(waitingTask, 8000), '');
  assert.match(types.codexExecutionNotice(waitingTask, 9000), /8 秒没有新输出/);
  assert.match(types.codexExecutionNotice({ ...waitingTask, progress: { kind: 'reconnecting', message: '重连（2/5）', since: 2000 } }, 9000), /重连（2\/5）.*7 秒/);
  assert.equal(types.codexExecutionNotice({ ...waitingTask, status: 'completed' }, 9000), '');
  assert.match(types.codexExecutionNotice({ status: 'idle', executionTransport: 'desktop', desktopConnected: true }, 0), /实时共享/);
  assert.match(types.codexExecutionNotice({ status: 'unknown', executionTransport: 'desktop', desktopConnected: false, error: '同步未确认' }, 0), /同步未确认/);
  assert.match(types.codexExecutionNotice({ status: 'running', executionTransport: 'desktop', desktopConnected: true, executionSource: 'desktop' }, 0), /任一端/);
  assert.equal(types.codexExecutionNotice({ status: 'waitingApproval', progress: { kind: 'desktopApproval', message: '请在电脑端处理', since: 0 } }, 5000), '请在电脑端处理');
  const tabs = load('entry/src/main/ets/pages/main/MainTabConfig.ets');
  assert.deepEqual(Array.from(tabs.MAIN_TAB_ITEMS, t => t.label), ['首页', '汇总', '聊天', 'Codex', '任务', '我的']);

  const { PrivacyConsent } = load('entry/src/main/ets/utils/PrivacyConsent.ets');
  await PrivacyConsent.initialize({});
  assert.equal(PrivacyConsent.isAccepted(), true);
  const { CodexClient } = load('entry/src/main/ets/pages/codex/CodexClient.ets');
  const client = new CodexClient();
  client.configure({ origin: 'https://example.com', token: 'a'.repeat(43) });
  await client.call('/v1/info');
  const creates = sessionCreates; await client.call('/v1/info'); assert.equal(sessionCreates, creates, 'successes reuse one RCP transport');
  let reachable; client.onReachability = value => { reachable = value; };
  fetchErrors = [Object.assign(new Error('timeout'), { code: 1007900028 })];
  const count = fetchCount; await client.call('/v1/info');
  assert.equal(fetchCount, count + 2); assert.equal(reachable, true, 'a read recovers after one transport retry');
  fetchErrors = [Object.assign(new Error('timeout'), { code: 1007900028 })];
  const postCount = fetchCount;
  await assert.rejects(client.call('/v1/tasks/session/turns', { text: 'do it' }), /超时/);
  assert.equal(fetchCount, postCount + 1, 'an ambiguous turn submission is never automatically resent');
  assert.equal(reachable, false);
  fetchErrors = [Object.assign(new Error('timeout'), { code: 1007900028 })];
  const healthCount = fetchCount; await assert.rejects(client.call('/v1/health'), /超时/);
  assert.equal(fetchCount, healthCount + 1, 'heartbeat retry is paced by the page');
  fetchErrors = []; await client.call('/v1/info');
  const cancels = sessionCancels; const closed = sessionCloses;
  deferred = true; const pollRequest = client.call('/v1/tasks/a?revision=1&waitMs=12000');
  client.cancelTaskUpdates(); assert.equal(sessionCancels, cancels + 1); assert.equal(sessionCloses, closed);
  assert.equal(cancelledRequest.url, 'https://example.com/v1/tasks/a?revision=1&waitMs=12000');
  resolveFetch(response); await assert.rejects(pollRequest, /取消/); deferred = false;
  const { codexResponseText } = load('entry/src/main/ets/pages/codex/CodexResponseText.ets');
  const encoded = Uint8Array.from(gzipSync(Buffer.from('{"text":"正确的回复"}')));
  assert.equal(await codexResponseText(encoded.buffer, null), '{"text":"正确的回复"}');
  assert.equal(await codexResponseText(new ArrayBuffer(0), '{}'), '{}', 'already decoded RCP responses are not inflated twice');
  const damaged = Uint8Array.from(encoded); damaged[damaged.length - 8] ^= 1;
  await assert.rejects(codexResponseText(damaged.buffer, null));
  const bomb = Uint8Array.from(encoded); new DataView(bomb.buffer).setUint32(bomb.length - 4, 16777217, true);
  await assert.rejects(codexResponseText(bomb.buffer, null), /过大/);
  fetchReplies = [{ statusCode: 200, body: damaged.buffer, toString: () => null }, response];
  await client.call('/v1/info'); assert.equal(sentRequest.headers['Accept-Encoding'], 'identity', 'bad gzip falls back to a plain GET');
  captureTimers = true; timerJobs = []; deferred = true;
  const deadlineCall = client.call('/v1/health');
  timerJobs.find(job => job.ms === 18000).callback();
  await assert.rejects(deadlineCall, /超时/); assert.equal(reachable, false, 'a hard deadline marks the link offline');
  resolveFetch(response); captureTimers = false; deferred = false; timerJobs = [];
  await client.call('/v1/info');
  assert.equal(sessionConfiguration.requestConfiguration.transfer.autoRedirect, false);
  assert.equal(sessionConfiguration.requestConfiguration.tracing.verbose, false);
  assert.equal(sentRequest.url, 'https://example.com/v1/info');
  assert.equal(sentRequest.headers.Authorization, 'Bearer ' + 'a'.repeat(43));
  assert.equal(sentRequest.url.includes('token'), false);
  response.statusCode = 302;
  await assert.rejects(client.call('/v1/info'), /重定向/);
  response.statusCode = 401;
  await assert.rejects(client.call('/v1/info'), /令牌/);
  response.statusCode = 200;
  deferred = true;
  const pending = client.call('/v1/info');
  const before = sessionCloses;
  platformAccepted = false; PrivacyConsent.isAccepted();
  assert.equal(sessionCloses, before, 'external sharing state does not disconnect an in-app Codex transport');
  resolveFetch(response);
  await pending;
  assert.equal(sessionCloses, before);
  const cancelled = client.call('/v1/info');
  client.close();
  resolveFetch(response); await assert.rejects(cancelled);
  assert.equal(sessionCloses, before + 1, 'explicit disconnect closes the session exactly once');
  await assert.rejects(client.call('/v1/info'));

  const { CodexCredentialStore } = load('entry/src/main/ets/pages/codex/CodexCredentialStore.ets');
  assert.equal(await CodexCredentialStore.load(), null);
  await CodexCredentialStore.save({ origin: 'https://example.com', token: 'b'.repeat(43) });
  const saved = await CodexCredentialStore.load();
  assert.equal(saved.origin, 'https://example.com'); assert.equal(saved.token, 'b'.repeat(43));
  const attributes = [...storedAssets.values()][0];
  assert.equal(attributes.get(asset.Tag.SYNC_TYPE), asset.SyncType.NEVER);
  assert.equal(attributes.get(asset.Tag.ACCESSIBILITY), asset.Accessibility.DEVICE_UNLOCKED);
  await CodexCredentialStore.forget(); assert.equal(await CodexCredentialStore.load(), null);

  const ca = '-----BEGIN CERTIFICATE-----\n' + 'A'.repeat(900) + '\n-----END CERTIFICATE-----\n';
  await CodexCredentialStore.save({ origin: 'https://example.com', token: 'b'.repeat(43), caCertificate: ca });
  assert.equal((await CodexCredentialStore.load()).caCertificate, ca);
  const pairedAttributes = [...storedAssets.values()][0];
  assert.ok(pairedAttributes.get(asset.Tag.SECRET).length <= 1024);
  assert.ok(pairedAttributes.get(asset.Tag.DATA_LABEL_CRITICAL_1).length <= 2048);
  const firstId = (await CodexCredentialStore.list())[0].id;
  const second = await CodexCredentialStore.save({ origin: 'https://second.example.com', token: 's'.repeat(43), caCertificate: ca }, 'Office');
  assert.equal((await CodexCredentialStore.list()).length, 2);
  assert.equal((await CodexCredentialStore.load(firstId)).token, 'b'.repeat(43));
  assert.equal((await CodexCredentialStore.load(second.id)).token, 's'.repeat(43));
  assert.equal((await CodexCredentialStore.load(second.id)).caCertificate, ca);
  const refreshed = await CodexCredentialStore.save({ origin: 'https://second.example.com', token: 't'.repeat(43), caCertificate: ca }, 'Office');
  assert.equal(refreshed.id, second.id, 're-pairing the same origin replaces that entry');
  assert.equal((await CodexCredentialStore.list()).length, 2);
  assert.equal((await CodexCredentialStore.load(second.id)).token, 't'.repeat(43));
  await CodexCredentialStore.forget(firstId);
  assert.equal((await CodexCredentialStore.load(second.id)).token, 't'.repeat(43), 'deleting a connection does not delete another computer');
  const legacyAlias = Buffer.from('clawmate.codex.connection.v1');
  storedAssets.set(legacyAlias.toString(), new Map([
    [asset.Tag.ALIAS, legacyAlias], [asset.Tag.SECRET, Buffer.from(JSON.stringify({ origin: 'https://legacy.example.com', token: 'l'.repeat(43) }))],
    [asset.Tag.DATA_LABEL_CRITICAL_1, Buffer.from(ca)]
  ]));
  assert.ok((await CodexCredentialStore.list()).some(item => item.id === 'legacy'));
  assert.equal((await CodexCredentialStore.load('legacy')).caCertificate, ca);
  const migrated = await CodexCredentialStore.save(await CodexCredentialStore.load('legacy'), 'Home');
  assert.notEqual(migrated.id, 'legacy');
  assert.equal(storedAssets.has(legacyAlias.toString()), false);
  assert.equal((await CodexCredentialStore.load(migrated.id)).token, 'l'.repeat(43));
  assert.equal((await CodexCredentialStore.load(second.id)).token, 't'.repeat(43));
  platformAccepted = true; PrivacyConsent.isAccepted(); deferred = false;
  const bundle = { type: 'clawmate-codex-pairing', version: 1, name: 'My PC', origin: 'https://example.com',
    serverId: 'server', code: 'c'.repeat(43), caCertificate: ca, expiresAt: Date.now() + 5 * 60000 };
  const { parseCodexPairingInput } = load('entry/src/main/ets/pages/codex/CodexPairingInput.ets');
  const encodedPairing = types.CODEX_PAIRING_PREFIX + Buffer.from(JSON.stringify(bundle)).toString('base64url');
  assert.equal(parseCodexPairingInput(encodedPairing).code, bundle.code);
  assert.equal(parseCodexPairingInput(JSON.stringify(bundle)).caCertificate, ca);
  for (const invalid of ['https://example.com', '4D:18:36:2F:A4:CD', 'CLAWMATE-CODEX-PAIR:%%%%', 'x'.repeat(12289)]) {
    assert.throws(() => parseCodexPairingInput(invalid));
  }
  assert.throws(() => parseCodexPairingInput(JSON.stringify({ ...bundle, expiresAt: Date.now() - 1 })));
  response.toString = () => JSON.stringify({ token: 'd'.repeat(43), serverId: 'server' });
  const connected = await client.pair(bundle);
  assert.equal(connected.token, 'd'.repeat(43));
  assert.equal(sentRequest.url, 'https://example.com/v1/pair');
  assert.equal(sentRequest.headers.Authorization, undefined, 'one-time pairing does not send a long-lived credential');
  assert.equal(sessionConfiguration.requestConfiguration.security.remoteValidation.content, ca);
  await client.call('/v1/info');
  assert.equal(sentRequest.headers.Authorization, 'Bearer ' + 'd'.repeat(43));
  assert.throws(() => types.validateCodexPairing({ ...bundle, expiresAt: Date.now() - 1 }));
  response.toString = () => JSON.stringify({ token: 'd'.repeat(43), serverId: 'other-computer' });
  await assert.rejects(client.pair(bundle), /不匹配/);
  client.close();

  const { CodexPage } = load('entry/src/main/ets/pages/codex/CodexPage.ets');
  const page = new CodexPage(); page.followOutput = false;
  page.screen = types.CodexScreen.Setup;
  page.getUIContext = () => ({ getHostContext: () => ({}) });
  const scanning = page.scanPairingCode();
  page.screen = types.CodexScreen.Connections; page.screenChanged();
  const requestBeforeScanResult = sentRequest;
  resolveScan({ originalValue: encodedPairing }); await scanning;
  assert.equal(page.busy, false);
  assert.equal(page.pairedConnection, null);
  assert.equal(page.pairingInput, '');
  assert.equal(sentRequest, requestBeforeScanResult, 'a scanner result after back navigation cannot pair');
  const retainedClient = page.client;
  page.connected = true; page.connectedOrigin = 'https://retained.example.com'; page.draft = 'Keep this draft';
  page.screen = types.CodexScreen.Setup; page.originInput = 'https://unavailable.example.com'; page.tokenInput = 'u'.repeat(43);
  response.statusCode = 401;
  await page.connect();
  assert.equal(page.client, retainedClient); assert.equal(page.connected, true);
  assert.equal(page.connectedOrigin, 'https://retained.example.com'); assert.equal(page.draft, 'Keep this draft');
  response.statusCode = 200;
  const savedCount = (await CodexCredentialStore.list()).length;
  page.remember = false;
  response.toString = () => JSON.stringify({ protocol: 1, ready: true, name: 'Temporary',
    workspaces: [{ id: 'project', name: 'Project' }], models: [{ model: 'test-model', supportedReasoningEfforts: [] }], tasks: [] });
  await page.connect();
  assert.equal(page.screen, types.CodexScreen.Workspace);
  assert.equal(page.mode, 'workspace-write'); assert.equal(page.approvalMode, 'ask');
  assert.equal((await CodexCredentialStore.list()).length, savedCount, 'temporary connections do not remove remembered computers');
  page.task = { id: 'a', revision: 10 };
  page.applyTask({ id: 'a', revision: 9 }); assert.equal(page.task.revision, 10);
  page.pendingRequestId = 'retry'; page.draft = 'pending input'; page.attachments = [{}];
  page.applyTask({ id: 'a', revision: 11, lastRequestId: 'retry', status: 'running' });
  assert.equal(page.pendingRequestId, ''); assert.equal(page.draft, ''); assert.equal(page.attachments.length, 0);
  page.task = null;
  page.getUIContext = () => ({ getHostContext: () => ({ cacheDir: '/app/cache' }) });
  page.client.call = async (endpoint, body) => {
    assert.equal(endpoint, '/v1/uploads'); uploadCount++;
    return { attachment: { id: 'attachment-' + uploadCount, name: body.name, image: body.image, size: attachmentSize } };
  };
  cameraResult = { resultCode: -1, resultUri: '', mediaType: 'photo' };
  await page.pickAttachment('camera');
  assert.equal(uploadCount, 0, 'cancelling the camera does not upload');
  assert.equal(removedCameraFiles.length, 1, 'cancelled capture removes its own cache file');
  cameraResult = { resultCode: 0, resultUri: '', mediaType: 'photo' };
  await page.pickAttachment('camera');
  assert.equal(uploadCount, 1); assert.equal(page.attachments[0].image, true);
  assert.equal(removedCameraFiles.length, 2, 'successful capture also removes its local cache file');
  assert.ok(removedCameraFiles.every(filename => filename.startsWith('/app/cache/codex-camera-')));
  await page.pickAttachment('album');
  assert.equal(page.attachments[1].image, true);
  await page.pickAttachment('file');
  assert.equal(page.attachments[2].name, 'notes.txt'); assert.equal(page.attachments[2].image, false);
  attachmentSize = types.CODEX_MAX_FILE_BYTES + 1;
  await page.pickAttachment('album');
  assert.equal(uploadCount, 3, 'oversized files never reach the upload endpoint');
  attachmentSize = 3; deferCamera = true;
  const capturing = page.pickAttachment('camera');
  while (!resolveCamera) await Promise.resolve();
  page.screen = types.CodexScreen.Connections; page.screenChanged();
  resolveCamera(cameraResult); await capturing;
  assert.equal(uploadCount, 3, 'camera return after leaving the workspace cannot upload');
  assert.equal(removedCameraFiles.length, 3);
  assert.equal(page.busy, false);
  page.screen = types.CodexScreen.Workspace; page.active = true; page.existingSessionsSupported = true; page.sameSessionSupported = true;
  const pcHistory = { id: 'pc-original', title: 'PC session', workspaceId: 'project', model: 'test-model', effort: '',
    mode: 'read-only', status: 'history', external: true, revision: 0, items: [{ id: 'recent', kind: 'assistant', text: 'latest' }],
    approvals: [], historyCursor: 'items:older', error: '' };
  let listPages = 0;
  page.client.call = async route => {
    if (route.startsWith('/v1/threads?')) { assert.match(route, /cursor=next/); listPages++; return { threads: [{ id: 'pc-original' }, { id: 'another-pc' }], nextThreadCursor: '' }; }
    if (route === '/v1/threads') { listPages++; return { threads: [{ id: 'pc-original' }], nextThreadCursor: 'next' }; }
    if (route === '/v1/threads/pc-original') return { task: pcHistory };
    if (route.startsWith('/v1/threads/pc-original?')) return { task: { ...pcHistory, items: [{ id: 'old', kind: 'user', text: 'earlier' }, pcHistory.items[0]], historyCursor: '' } };
    if (route === '/v1/tasks') return { tasks: [] };
    throw new Error('Unexpected route: ' + route);
  };
  await page.loadComputerHistory(true); await page.loadComputerHistory(false);
  assert.equal(listPages, 2); assert.equal(page.computerTasks.length, 2, 'history pagination deduplicates records');
  await page.selectTask('pc-original', true);
  assert.equal(page.task.external, true); assert.equal(page.mode, 'read-only');
  await page.poll(); // An external preview must not poll the bridge-owned task route.
  await page.loadOlderHistory();
  assert.equal(page.taskItems().length, 2); assert.equal(page.taskItems()[0].text, 'earlier');
  let resumeAttempts = 0; const resumeRequests = []; const turns = [];
  page.client.call = async (route, body) => {
    if (route.endsWith('/resume')) {
      resumeAttempts++; resumeRequests.push(body.requestId);
      assert.equal(body.mode, 'read-only');
      if (resumeAttempts === 1) throw new Error('Lost resume response');
      return { task: { ...pcHistory, external: false, sharedThread: true, status: 'idle' } };
    }
    if (route === '/v1/tasks/pc-original/turns') {
      turns.push(body.requestId);
      if (turns.length === 1) throw new Error('Lost turn response');
      return { task: { ...pcHistory, external: false, sharedThread: true, status: 'running', revision: 1, lastRequestId: body.requestId } };
    }
    if (route === '/v1/tasks') return { tasks: [] };
    throw new Error('Unexpected execution route: ' + route);
  };
  page.draft = 'Continue with context'; page.attachments = [];
  await page.send(); assert.equal(page.task.id, 'pc-original');
  await page.send(); assert.equal(page.task.id, 'pc-original'); assert.equal(page.task.sharedThread, true);
  await page.send();
  assert.equal(resumeAttempts, 2, 'a lost turn response never registers another session');
  assert.equal(resumeRequests[0], resumeRequests[1], 'registration retries reuse the same request ID');
  assert.equal(turns[0], turns[1], 'turn retries reuse their request ID');
  assert.equal(page.draft, ''); assert.equal(page.historyScope, 'computer');
  page.task = { ...pcHistory, external: false, sharedThread: true, status: 'unknown', revision: 2, executionTransport: 'desktop' };
  page.permissionSettingsSupported = true; page.draft = 'Keep until confirmed'; page.attachments = [];
  page.client.call = async (route, body) => {
    if (route === '/v1/tasks') return { tasks: [] };
    return { task: { ...page.task, revision: 3, lastRequestId: body.requestId, lastRequestConfirmed: false } };
  };
  await page.send(); assert.equal(page.draft, 'Keep until confirmed'); assert.ok(page.pendingRequestId);
  page.applyTask({ ...page.task, revision: 4, lastRequestConfirmed: true });
  assert.equal(page.draft, ''); assert.equal(page.pendingRequestId, '');
  assert.equal(types.codexTaskBusy('releasing'), true);
  assert.equal(types.codexStatusLabel('releasing'), '正在保存并释放会话');
  page.task = pcHistory; page.sameSessionSupported = false; page.draft = 'Keep this draft';
  const acceptedTurns = turns.length;
  await page.send(); assert.match(page.errorText, /升级电脑端/); assert.equal(page.draft, 'Keep this draft');
  assert.equal(turns.length, acceptedTurns, 'older bridges cannot silently fall back to a fork');
  page.task = { ...pcHistory, external: false, sharedThread: true, status: 'completed' };
  page.permissionSettingsSupported = true; page.sameSessionSupported = true; page.draft = 'Use selected permissions';
  page.chooseApprovalMode('full'); assert.equal(page.mode, 'danger-full-access');
  page.chooseApprovalMode('auto'); assert.equal(page.mode, 'workspace-write');
  page.client.call = async (route, body) => {
    if (route === '/v1/tasks') return { tasks: [] };
    assert.equal(body.mode, 'workspace-write'); assert.equal(body.approvalMode, 'auto');
    return { task: { ...page.task, status: 'running', revision: 2, approvalMode: 'auto', mode: 'workspace-write' } };
  };
  await page.send();
  page.chooseApprovalMode('full'); assert.equal(page.approvalMode, 'auto', 'permissions cannot change while running');
  page.taskUpdatesSupported = true;
  let resolveUpdate; let updateRoute;
  page.client.call = async route => { updateRoute = route; return new Promise(resolve => { resolveUpdate = resolve; }); };
  const updating = page.poll();
  assert.match(updateRoute, /waitMs=12000/);
  page.newTask(); assert.equal(page.mode, 'workspace-write'); assert.equal(page.approvalMode, 'ask');
  resolveUpdate({ task: { ...pcHistory, external: false, status: 'running', revision: 20 } }); await updating;
  assert.equal(page.task, null, 'leaving a session discards its delayed status response');
  assert.equal(page.networkText, '', 'cancelled updates do not create a network-failure banner');
  page.historyOpen = true; page.taskSettingsOpen = true;
  page.disconnect();
  assert.equal(page.historyOpen, false); assert.equal(page.taskSettingsOpen, false);
  assert.equal((await CodexCredentialStore.list()).length, savedCount, 'disconnect preserves saved connections');
  const weakPage = new CodexPage(); weakPage.connected = true; weakPage.active = true; weakPage.screen = types.CodexScreen.Workspace;
  weakPage.healthSupported = true; weakPage.lastNetworkSuccess = Date.now() - 60000;
  weakPage.client.call = async route => { assert.equal(route, '/v1/health'); throw new Error('network timeout'); };
  await weakPage.checkConnection(); assert.match(weakPage.linkLabel(), /中断/); assert.equal(weakPage.healthChecking, false);
  weakPage.client.call = async () => ({ ready: true }); await weakPage.checkConnection();
  assert.equal(weakPage.linkLabel(), '已连接'); assert.equal(weakPage.networkText, '');
  captureTimers = true; timerJobs = [];
  weakPage.followOutput = false;
  weakPage.client.call = async () => ({ task: { ...pcHistory, id: 'open-at-bottom', external: false } });
  await weakPage.selectTask('open-at-bottom');
  timerJobs.filter(job => [0, 120, 350].includes(job.ms)).forEach(job => job.callback());
  assert.ok(weakPage.scroller.edges.length > 0); assert.ok(weakPage.scroller.edges.every(edge => edge === 'bottom'));
  weakPage.task = { ...weakPage.task, id: 'a-different-session' };
  const edges = weakPage.scroller.edges.length;
  timerJobs.filter(job => [0, 120, 350].includes(job.ms)).forEach(job => job.callback());
  assert.equal(weakPage.scroller.edges.length, edges, 'late scrolls cannot move a different conversation');
  weakPage.followOutput = true; weakPage.taskDeltaSupported = true; weakPage.task = { ...pcHistory, id: 'delta', revision: 1, external: false };
  weakPage.busy = false; weakPage.polling = false; let syncReads = 0;
  weakPage.client.call = async route => {
    if (route === '/v1/tasks') return { tasks: [] };
    syncReads++;
    if (route.includes('revision=')) return { taskDelta: { baseRevision: 0, task: { ...weakPage.task, revision: 2 }, items: [], itemOrder: [] } };
    return { task: { ...weakPage.task, revision: 2 } };
  };
  await weakPage.poll(); assert.equal(syncReads, 2); assert.equal(weakPage.task.revision, 2, 'a missing delta base triggers a full read');
  weakPage.disconnect(); captureTimers = false; timerJobs = [];
  for (const section of ['download', 'connect', 'tailscale']) {
    await page.openHelp(section);
    assert.equal(helpNavigation.url, 'pages/codex/CodexHelpPage');
    assert.deepEqual(Object.keys(helpNavigation.params), ['section']);
    assert.equal(helpNavigation.params.section, section, 'help routes carry no credentials or pairing data');
  }
console.log('PASS: production ArkTS endpoint/token policies, 6 tabs, RCP redirect/auth handling, explicit cancellation without a duplicate privacy gate, Asset Store size/trust policy, one-time pairing, task reconciliation, and help navigation.');
  console.log('ArkUI rendering and HarmonyOS API type checking require the full DevEco SDK.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
