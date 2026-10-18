// Node-side checks of production ArkTS logic. This does not compile ArkUI or build a HAP.
// Usage: node scripts/check_codex_logic.cjs [path-to-typescript-module]
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const cache = new Map();
let response = { statusCode: 200, body: new ArrayBuffer(2), toString: () => '{}' };
let sessionConfiguration;
let sentRequest;
let sessionCloses = 0;
let resolveFetch;
let deferred = false;
const storedAssets = new Map();
const preferencesData = new Map();
const appStorage = new Map();
const dummy = () => {};
const decorator = () => dummy;
class Scroller {}
const asset = {
  Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, AUTH_TYPE: 5, SYNC_TYPE: 6, CONFLICT_RESOLUTION: 7 },
  ReturnType: { ALL: 1 }, Accessibility: { DEVICE_UNLOCKED: 2 }, AuthType: { NONE: 0 },
  SyncType: { NEVER: 0 }, ConflictResolution: { OVERWRITE: 1 },
  add: async attributes => { storedAssets.set(attributes.get(1).toString(), attributes); },
  query: async query => {
    const item = storedAssets.get(query.get(1).toString());
    if (!item) throw { code: 24000002 };
    return [item];
  },
  remove: async query => { storedAssets.delete(query.get(1).toString()); }
};
const kitMocks = {
  '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': {}, '@kit.MediaLibraryKit': {},
  '@kit.NetworkKit': { http: {} },
  '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => preferencesData.get(key) ?? fallback,
    put: async (key, value) => { preferencesData.set(key, value); }, flush: async () => {}
  }) } },
  '@kit.ArkTS': { util: {
    TextEncoder: class { encodeInto(value) { return Buffer.from(value); } },
    TextDecoder: class { decodeWithStream(value) { return Buffer.from(value).toString(); } },
    generateRandomUUID: randomUUID
  } },
  '@kit.AssetStoreKit': { asset },
  '@kit.RemoteCommunicationKit': { rcp: {
    Request: class { constructor(url, method, headers, body) { Object.assign(this, { url, method, headers, body }); } },
    createSession: configuration => {
      sessionConfiguration = configuration;
      return {
        fetch: async request => {
          sentRequest = request;
          return deferred ? new Promise(resolve => { resolveFetch = resolve; }) : response;
        },
        close: () => { sessionCloses++; }
      };
    }
  } }
};
function load(relative) {
  const filename = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(filename)) return cache.get(filename);
  if (/\/(AppTheme|AppHeader|FrostedPage|MarkdownView|CodexApprovalCard)\.ets$/.test(filename)) return {};
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
  }, Buffer, Uint8Array, ArrayBuffer, Map, console, setTimeout: () => 1, clearTimeout: dummy, Scroller,
  Component: dummy, State: decorator, Prop: decorator, Watch: decorator, StorageProp: decorator,
  AppStorage: { setOrCreate: (k, v) => appStorage.set(k, v) } };
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
  assert.equal(types.codexTaskBusy('waitingApproval'), true);
  assert.equal(types.codexTaskBusy('completed'), false);
  const tabs = load('entry/src/main/ets/pages/main/MainTabConfig.ets');
  assert.deepEqual(Array.from(tabs.MAIN_TAB_ITEMS, t => t.label), ['首页', '汇总', '聊天', 'Codex', '任务', '我的']);

  const { PrivacyConsent, PRIVACY_VERSION } = load('entry/src/main/ets/utils/PrivacyConsent.ets');
  preferencesData.set('choice', 'accepted'); preferencesData.set('version', PRIVACY_VERSION);
  await PrivacyConsent.initialize({});
  assert.equal(PrivacyConsent.isAccepted(), true);
  const { CodexClient } = load('entry/src/main/ets/pages/codex/CodexClient.ets');
  const client = new CodexClient();
  client.configure({ origin: 'https://example.com', token: 'a'.repeat(43) });
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
  await PrivacyConsent.choose(false);
  assert.equal(sessionCloses, before + 1);
  resolveFetch(response);
  await assert.rejects(pending);
  assert.equal(sessionCloses, before + 1, 'session closed exactly once on privacy revocation');
  client.close();
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

  const { CodexPage } = load('entry/src/main/ets/pages/codex/CodexPage.ets');
  const page = new CodexPage(); page.followOutput = false;
  page.task = { id: 'a', revision: 10 };
  page.applyTask({ id: 'a', revision: 9 }); assert.equal(page.task.revision, 10);
  page.pendingRequestId = 'retry'; page.draft = 'pending input'; page.attachments = [{}];
  page.applyTask({ id: 'a', revision: 11, lastRequestId: 'retry', status: 'running' });
  assert.equal(page.pendingRequestId, ''); assert.equal(page.draft, ''); assert.equal(page.attachments.length, 0);
  console.log('PASS: production ArkTS endpoint/token policies, 6 tabs, RCP redirect/auth handling, privacy cancellation, Asset Store policy and task reconciliation.');
  console.log('ArkUI rendering and HarmonyOS API type checking require the full DevEco SDK.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
