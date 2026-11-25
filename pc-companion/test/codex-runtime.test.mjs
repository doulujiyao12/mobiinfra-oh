import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findCodexRuntime, resolveCodexSelection } from '../host/codex-runtime.mjs';
import { CompanionManager } from '../host/manager.mjs';

test('Windows prefers the installed desktop and discovers its new location after an update', () => {
  const first = 'C:\\WindowsApps\\Codex-first';
  const second = 'C:\\WindowsApps\\Codex-second';
  const desktop = folder => path.win32.join(folder, 'app', 'resources', 'codex.exe');
  const files = new Set([desktop(first), desktop(second), 'C:\\tools\\codex.exe']);
  let installed = first;
  const settings = { platform: 'win32', arch: 'x64', home: 'C:\\Users\\test', env: { Path: 'C:\\tools' },
    desktopLocations: () => [installed], resolve: file => files.has(file) ? file : null };
  assert.equal(findCodexRuntime(settings), desktop(first));
  installed = second;
  assert.equal(findCodexRuntime(settings), desktop(second));
  files.delete(desktop(second));
  assert.equal(findCodexRuntime(settings), 'C:\\tools\\codex.exe');
});

test('Windows finds npm native Codex without executing a .cmd shim', () => {
  const cli = 'C:\\npm\\node_modules\\@openai\\codex-win32-x64\\vendor\\x86_64-pc-windows-msvc\\bin\\codex.exe';
  assert.equal(findCodexRuntime({ platform: 'win32', arch: 'x64', home: 'C:\\Users\\test',
    desktopLocations: () => [], env: { PATH: 'C:\\npm' }, resolve: file => file === cli ? file : null }), cli);
});

test('Windows recognizes the desktop on PATH if app registration is unavailable', () => {
  const resources = 'C:\\Program Files\\WindowsApps\\OpenAI.Codex_1_x64\\app\\resources';
  const desktop = path.win32.join(resources, 'codex.exe');
  const files = new Set([desktop, 'C:\\tools\\codex.exe']);
  const env = { PATH: 'C:\\tools;' + resources };
  const options = { platform: 'win32', env, home: 'C:\\Users\\test', desktopLocations: () => [],
    resolve: file => files.has(file) ? file : null };
  assert.equal(findCodexRuntime(options), desktop);
  files.delete(desktop);
  assert.equal(findCodexRuntime(options), 'C:\\tools\\codex.exe');
});

test('macOS bundle discovery, executable override and rejection of legacy bundled Codex', () => {
  const mac = '/Applications/Codex.app/Contents/Resources/codex';
  const legacy = '/tmp/clawmate/runtime/bin/codex';
  const standalone = '/opt/codex/bin/codex';
  const resolve = file => [mac, legacy, standalone].includes(file) ? file : null;
  assert.equal(findCodexRuntime({ platform: 'darwin', env: { PATH: '/opt/codex/bin' }, resolve }), mac);
  const config = { platform: 'linux', home: '/tmp/test', resolve, resources: '/tmp/clawmate' };
  assert.equal(findCodexRuntime({ ...config, env: { CLAWMATE_CODEX_EXECUTABLE: standalone } }), standalone);
  for (const invalid of [legacy, 'codex', '/wrong/codex']) {
    assert.throws(() => findCodexRuntime({ ...config, env: { CLAWMATE_CODEX_EXECUTABLE: invalid } }), { code: 'CODEX_NOT_FOUND' });
  }
  assert.throws(() => findCodexRuntime({ ...config, env: { PATH: '/tmp/clawmate/runtime/bin:.' } }), { code: 'CODEX_NOT_FOUND' });
});

test('macOS prefers ChatGPT desktop over legacy Codex and CLI', () => {
  const chatgpt = '/Users/test/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex';
  const legacy = '/Applications/Codex.app/Contents/Resources/codex';
  const cli = '/opt/codex/bin/codex';
  const files = new Set([chatgpt, legacy, cli]);
  const options = { platform: 'darwin', home: '/Users/test', env: { PATH: '/opt/codex/bin' },
    resolve: filename => files.has(filename) ? filename : null };
  assert.equal(findCodexRuntime(options), chatgpt);
  assert.equal(findCodexRuntime({ ...options, preferredExecutable: cli }), cli);
  files.delete(chatgpt);
  assert.equal(findCodexRuntime(options), legacy);
});

test('macOS finds an indexed desktop bundle with a custom name before falling back to CLI', () => {
  const bundle = '/Applications/ChatGPT Work.app';
  const codex = bundle + '/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex';
  const cli = '/opt/homebrew/bin/codex';
  assert.equal(findCodexRuntime({ platform: 'darwin', env: { PATH: '/opt/homebrew/bin' },
    macLocations: () => [bundle], resolve: file => [codex, cli].includes(file) ? file : null }), codex);
});

test('macOS file picker can select the desktop app bundle without entering it', t => {
  // The same resolver is called by the daemon for both Electron selections and explicit paths.
  if (process.platform === 'win32') return t.skip('The macOS resolver uses POSIX executable paths');
  const root = mkdtempSync(path.join(os.tmpdir(), 'clawmate-codex-app-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const chatgpt = path.join(root, 'ChatGPT.app');
  const legacy = path.join(root, 'Codex.app');
  const modernExecutable = path.join(chatgpt, 'Contents', 'Resources', 'codex-cli', 'CodexCLI.app', 'Contents', 'MacOS', 'codex');
  const legacyExecutable = path.join(legacy, 'Contents', 'Resources', 'codex');
  for (const executable of [modernExecutable, legacyExecutable]) {
    mkdirSync(path.dirname(executable), { recursive: true });
    writeFileSync(executable, 'fixture', { mode: 0o700 });
  }
  assert.equal(resolveCodexSelection(chatgpt, undefined, 'darwin'), modernExecutable);
  assert.equal(resolveCodexSelection(legacy, undefined, 'darwin'), legacyExecutable);
  assert.throws(() => resolveCodexSelection(chatgpt, root, 'darwin'), /已安装的 Codex/);
  assert.throws(() => resolveCodexSelection(path.join(root, 'ChatGPT Classic.app'), undefined, 'darwin'), /已安装的 Codex/);
});

test('macOS and Linux discover CLI-only installations with application and terminal PATHs', () => {
  for (const [platform, env, cli] of [
    ['darwin', { PATH: '/usr/bin' }, '/opt/homebrew/bin/codex'],
    ['darwin', { PATH: '/opt/npm/bin:/usr/bin' }, '/opt/npm/bin/codex'],
    ['linux', { PATH: '/usr/bin' }, '/home/test/.local/bin/codex'],
    ['linux', { PATH: '/opt/npm/bin:/usr/bin' }, '/opt/npm/bin/codex']
  ]) {
    assert.equal(findCodexRuntime({ platform, home: '/home/test', env, macLocations: () => [],
      resolve: file => file === cli ? file : null }), cli);
  }
});

test('a saved selection follows its executable link and falls back to discovery when removed', () => {
  const selected = '/opt/custom/bin/codex';
  const automatic = '/usr/local/bin/codex';
  let target = '/opt/custom/first/codex';
  const options = { platform: 'linux', home: '/home/test', env: { PATH: '/usr/local/bin' }, preferredExecutable: selected,
    resolve: filename => filename === selected ? target : filename === automatic ? automatic : null };
  assert.equal(findCodexRuntime(options), target);
  target = '/opt/custom/updated/codex';
  assert.equal(findCodexRuntime(options), target);
  target = null;
  assert.equal(findCodexRuntime(options), automatic);
});

test('local management remains available without Codex and an explicit action retries discovery', async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-external-codex-'));
  const tailscale = { refresh: async () => {}, status: () => ({ addresses: [] }) };
  let executable = '';
  let discoveries = 0;
  const manager = new CompanionManager(directory, { launcher: '/clawmate/launcher' }, { tailscale, rpcFactory() {
    discoveries++;
    if (!executable) throw new Error('未找到本机 Codex');
    const rpc = new EventEmitter();
    rpc.command = executable;
    rpc.initialize = async () => {};
    rpc.close = () => {};
    rpc.request = async method => method === 'account/read' ? { account: null } : { type: 'chatgpt' };
    return rpc;
  } });
  t.after(async () => { await manager.close(); rmSync(directory, { recursive: true, force: true }); });
  await manager.initialize();
  assert.match((await manager.dispatch('status')).runtimeError, /未找到本机 Codex/);
  assert.equal(discoveries, 1, 'status polling does not repeat program discovery');
  executable = '/installed/codex';
  await manager.login();
  assert.equal(discoveries, 2);
  assert.equal(manager.status().runtimeError, '');
  assert.equal(manager.status().codexExecutable, executable);
});

test('local management can save and clear a valid Codex selection without restarting the bridge app', async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-custom-codex-'));
  const tailscale = { refresh: async () => {}, status: () => ({ addresses: [] }) };
  const executable = path.join(directory, process.platform === 'win32' ? 'codex.exe' : 'codex');
  writeFileSync(executable, 'fixture', { mode: 0o700 });
  let closed = 0;
  const manager = new CompanionManager(directory, { launcher: '/clawmate/launcher' }, { tailscale, rpcFactory() {
    const rpc = new EventEmitter();
    rpc.command = manager.settings.value.codexExecutable || '/auto/codex';
    rpc.initialize = async () => {};
    rpc.request = async () => ({ account: null });
    rpc.close = () => { closed++; };
    return rpc;
  } });
  t.after(async () => { await manager.close(); rmSync(directory, { recursive: true, force: true }); });
  await manager.initialize();
  await assert.rejects(manager.dispatch('selectCodexExecutable', { filename: 'missing' }), /已安装的 Codex/);
  manager.state = 'running';
  await assert.rejects(manager.dispatch('selectCodexExecutable', { filename: executable }), /请先停止手机连接服务/);
  assert.equal(closed, 0);
  manager.state = 'error';
  const selected = await manager.dispatch('selectCodexExecutable', { filename: executable });
  assert.equal(selected.state, 'stopped');
  assert.equal(selected.codexExecutable, executable);
  assert.equal(selected.hasCustomCodex, true);
  assert.equal(JSON.parse(readFileSync(manager.settings.filename, 'utf8')).codexExecutable, executable);
  const automatic = await manager.dispatch('selectCodexExecutable', { filename: '' });
  assert.equal(automatic.hasCustomCodex, false);
  assert.equal(automatic.codexExecutable, '/auto/codex');
  assert.equal(closed, 2);
});

test('start restores the same port after Codex exits and a failed recovery can be retried', async t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-runtime-recovery-'));
  const workspace = path.join(directory, 'project');
  mkdirSync(workspace);
  const tailscale = { refresh: async () => {}, status: () => ({ addresses: [] }) };
  let unavailable = false;
  let launches = 0;
  const manager = new CompanionManager(path.join(directory, 'state'), { launcher: '/clawmate/launcher' }, { tailscale, rpcFactory() {
    launches++;
    if (unavailable) throw new Error('fixture: Codex is temporarily unavailable');
    const rpc = new EventEmitter();
    rpc.initialize = async () => {};
    rpc.close = () => { rpc.closed = true; rpc.emit('stopped', 'exit code 1'); };
    rpc.request = async method => {
      if (method === 'account/read') return { account: { type: 'chatgpt' } };
      assert.equal(method, 'model/list');
      return { data: [{ model: 'test', supportedReasoningEfforts: [] }] };
    };
    return rpc;
  } });
  t.after(async () => { await manager.close(); rmSync(directory, { recursive: true, force: true }); });
  // A loopback-only HTTP fixture tests the listener without a certificate toolchain.
  Object.assign(manager.settings.value, { networkMode: 'public', host: '127.0.0.1', port: 0,
    workspaces: [{ id: 'project', name: 'Fixture', path: workspace }] });
  assert.equal((await manager.start()).state, 'running');
  assert.equal((await manager.start()).state, 'running');
  assert.equal(launches, 1, 'a healthy start is idempotent');
  const oldServer = manager.server;
  manager.settings.value.port = oldServer.address().port;
  const client = { headers: { Authorization: 'Bearer ' + manager.settings.value.token } };
  const info = `http://127.0.0.1:${manager.settings.value.port}/v1/info`;
  manager.rpc.close();
  assert.equal(manager.status().state, 'error');
  assert.equal(manager.status().listening, true);
  let response = await fetch(info, client);
  assert.equal(response.status, 503);
  await response.text();

  manager.core.locks.add('finishing');
  await assert.rejects(manager.start(), /仍有任务/);
  await assert.rejects(manager.stop(), /仍有任务/);
  assert.equal(manager.server, oldServer);
  assert.equal(manager.core.ready, false);
  manager.core.locks.delete('finishing');

  const restarted = await manager.start();
  assert.equal(restarted.state, 'running');
  assert.equal(restarted.listening, true);
  assert.equal(restarted.runtimeError, '');
  assert.equal(oldServer.listening, false);
  response = await fetch(info, client);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).ready, true);

  manager.rpc.close();
  unavailable = true;
  await assert.rejects(manager.start(), /temporarily unavailable/);
  assert.equal(manager.status().listening, false);
  assert.equal(manager.status().state, 'error');
  unavailable = false;
  assert.equal((await manager.start()).state, 'running');
  assert.equal(launches, 4);
});
