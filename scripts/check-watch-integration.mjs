// Static integration checks only: no Hvigor build, signing, installation or device access.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const home = process.env.DEVECO_HOME;
assert.ok(home, 'Set DEVECO_HOME to your DevEco Studio directory.');
const require = createRequire(import.meta.url);
const ts = require(path.join(home, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
function config(name) {
  const result = ts.parseConfigFileTextToJson(name, read(name));
  assert.ok(!result.error, `${name}: configuration syntax error`);
  return result.config;
}
function source(name) {
  const file = ts.createSourceFile(name, read(name), ts.ScriptTarget.Latest, true);
  assert.equal(file.parseDiagnostics.length, 0, `${name}: source syntax error`);
}

const app = config('AppScope/app.json5').app;
const profile = config('build-profile.json5');
const example = config('build-profile.example.json5');
const expected = new Map([['entry', ['phone']], ['watch_entry', ['wearable']], ['phonebridge', ['phone', 'tablet']]]);
assert.equal(new Set(profile.modules.map(module => module.name)).size, profile.modules.length, 'Duplicate module names');
for (const [name, devices] of expected) {
  const registered = profile.modules.find(module => module.name === name);
  assert.ok(registered, `${name}: missing in local build profile`);
  assert.equal(registered.srcPath, `./${name}`);
  assert.ok(registered.targets.some(target => target.name === 'default' && target.applyToProducts.includes('default')));
  const module = config(`${name}/src/main/module.json5`).module;
  assert.equal(module.name, name);
  assert.deepEqual(module.deviceTypes, devices, `${name}: incorrect device scope`);
  assert.equal(module.type, name === 'phonebridge' ? 'har' : 'entry');
  assert.ok(fs.existsSync(path.join(root, name, 'hvigorfile.ts')));
  const fromExample = example.modules.find(module => module.name === name);
  assert.deepEqual(fromExample, registered, `${name}: unsigned example is out of date`);
}
assert.deepEqual(example.app.signingConfigs, [], 'Example must contain no signing material');
assert.ok(example.app.products.every(product => !product.signingConfig));
const dependencies = config('entry/oh-package.json5').dependencies;
assert.equal(dependencies['@clawmate/watch-bridge'], 'file:../phonebridge');
assert.ok(dependencies['sherpa_onnx'] && dependencies['libentry.so'], 'Phone native dependencies must be retained');
assert.deepEqual(Object.keys(config('watch_entry/oh-package.json5').dependencies), ['libvoicevad.so']);
assert.equal(config('phonebridge/oh-package.json5').name, '@clawmate/watch-bridge');

const entry = config('entry/src/main/module.json5').module;
const watch = config('watch_entry/src/main/module.json5').module;
const clientId = entry.metadata.find(item => item.name === 'client_id').value;
const peer = read('watch_entry/src/main/ets/config/PhonePeer.ts');
const phoneId = peer.match(/PHONE_APP_ID:\s*string\s*=\s*'([0-9]+)'/)[1];
assert.equal(phoneId, clientId, 'Watch must address the existing phone AGC application');
assert.match(peer, /WATCH_APP_ID:\s*string\s*=\s*PHONE_APP_ID/);
for (const name of ['PHONE_BUNDLE_NAME', 'WATCH_BUNDLE_NAME']) {
  assert.equal(peer.match(new RegExp(`${name}:\\s*string\\s*=\\s*'([^']+)'`))[1], app.bundleName);
}
const client = read('phonebridge/src/main/ets/WatchRecordingClient.ets');
assert.equal(client.match(/watchAppId:\s*string\s*=\s*'([0-9]+)'/)[1], clientId);
assert.equal(client.match(/watchBundleName:\s*string\s*=\s*'([^']+)'/)[1], app.bundleName);
const facade = read('entry/src/main/ets/utils/recording/WatchRecordingClient.ets');
assert.match(facade, /from '@clawmate\/watch-bridge'/);
assert.ok(!facade.includes('class WatchRecordingClient'), 'Do not maintain a second phone client implementation');
for (const name of ['WatchRecordingClient', 'WatchRecording', 'WatchRecordingPage', 'DownloadedRecording', 'watchConnectionMessage']) {
  assert.ok(read('phonebridge/Index.ets').includes(name), `Missing HAR export: ${name}`);
  assert.ok(facade.includes(name), `Missing compatibility export: ${name}`);
}

const watchProfile = config('watch_entry/build-profile.json5');
const workers = watchProfile.buildOption.sourceOption.workers;
const loads = [
  ['watch_entry/src/main/ets/services/RecorderController.ets', 'RecorderWorker.ets'],
  ['watch_entry/src/main/ets/services/SyncStoreClient.ets', 'SyncWorker.ets']
];
for (const [controller, filename] of loads) {
  assert.ok(read(controller).includes(`'watch_entry/ets/workers/${filename}'`), `Wrong Worker module prefix: ${controller}`);
  assert.ok(!read(controller).includes("'entry/ets/workers/"));
  const worker = `./src/main/ets/workers/${filename}`;
  assert.ok(workers.includes(worker));
  assert.ok(fs.existsSync(path.join(root, 'watch_entry', worker)));
}
assert.ok(!read('watch_entry/src/main/cpp/CMakeLists.txt').includes('MNN'));
assert.ok(read('entry/src/main/cpp/CMakeLists.txt').includes('MNN'));
const strings = config('watch_entry/src/main/resources/base/element/string.json').string;
const phoneStrings = config('entry/src/main/resources/base/element/string.json').string;
assert.equal(strings.find(item => item.name === 'watch_app_name').value,
  phoneStrings.find(item => item.name === 'EntryAbility_label').value);
assert.equal(config('AppScope/resources/base/element/string.json').string.find(item => item.name === 'app_name').value,
  strings.find(item => item.name === 'watch_app_name').value);
assert.equal(watch.abilities[0].label, '$string:watch_app_name');
assert.ok(fs.existsSync(path.join(root, 'watch_entry/src/main/resources/base/media/watch_app_icon.png')));
assert.ok(!strings.find(item => item.name === 'microphone_reason').value.includes('仅保存在手表'));
assert.deepEqual(watch.abilities[0].backgroundModes, ['audioRecording', 'dataTransfer']);
for (const [name, module] of [['ClawMate_Phone', 'entry'], ['ClawMate_Watch', 'watch_entry']]) {
  const run = read(`.run/${name}.run.xml`);
  assert.ok(run.includes('type="OhosDebugTask"'));
  assert.ok(run.includes(`<MODULE_NAME>${module}</MODULE_NAME>`));
  assert.ok(run.includes('<DEPLOY_MULTI_HAP>false</DEPLOY_MULTI_HAP>'));
  assert.ok(run.includes('<ALL_MODULES>false</ALL_MODULES>'));
}

const changedSources = [
  'entry/src/main/ets/utils/recording/WatchRecordingClient.ets',
  'phonebridge/Index.ets', 'phonebridge/src/main/ets/WatchRecordingClient.ets',
  'watch_entry/src/main/ets/config/PhonePeer.ts',
  ...loads.map(item => item[0])
];
changedSources.forEach(source);
// Inspect only the public app identifier embedded in a local Profile. Never print
// its path, signing passwords, certificate content or the full build profile.
for (const signing of profile.app.signingConfigs ?? []) {
  const filename = signing.material?.profile;
  if (filename && fs.existsSync(filename)) {
    const identifier = fs.readFileSync(filename).toString('utf8').match(/"app-identifier"\s*:\s*"([^"]+)"/);
    if (identifier) { assert.equal(identifier[1], clientId, 'Local signing Profile belongs to a different AGC application'); }
  }
}
console.log('PASS: module registration, device scopes, HAR exports/dependency, app identity, Workers, resources, native isolation, run configurations and source syntax.');
console.log('Static checks only; no build, signing, installation or device communication was performed.');
