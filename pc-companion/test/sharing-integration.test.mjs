import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, createReadStream } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';
import { DesktopLifecycle } from '../desktop/lifecycle.mjs';

const thread = '12345678-1234-1234-1234-123456789abc';

// Run the real Electron entry point with local application and OS operations replaced.
// Registering the same IPC channel twice must fail just as it does in Electron.
function desktop(platform) {
  const file = new URL('../desktop/main.mjs', import.meta.url);
  const handlers = new Map();
  const calls = [];
  const profile = { executable: '/installed/codex', home: '/profiles/codex home' };
  const state = { consent: true, tasks: [{ id: thread, sharedThread: true, status: 'idle' }], shared: false };
  const webContents = { mainFrame: { url: new URL('../desktop/ui/index.html', import.meta.url).href } };
  const event = { sender: webContents, senderFrame: webContents.mainFrame };
  const context = vm.createContext({
    process: { platform, resourcesPath: '/clawmate/resources' }, path, fileURLToPath, pathToFileURL,
    dataDirectory: () => '/clawmate/data',
    desktopLayout: () => ({ base: '/clawmate/resources' }),
    DesktopLifecycle,
    app: { getAppPath: () => '/clawmate/app', requestSingleInstanceLock: () => false, quit() {} },
    ipcMain: { handle(name, handler) { assert.ok(!handlers.has(name), 'duplicate IPC ' + name); handlers.set(name, handler); } },
    dialog: { async showMessageBox(_window, options) { calls.push(['confirm', options]); return { response: state.consent ? 1 : 0 }; } },
    ensureDaemon: async () => { calls.push(['daemon']); },
    controlRequest: async () => ({ codexExecutable: profile.executable, codexHome: profile.home, tasks: state.tasks }),
    createRequire: () => () => ({ createReadStream }),
    probeSharing: async () => {
      calls.push(['windows-status']);
      return { state: state.shared ? 'shared' : 'private', text: 'Windows status' };
    },
    switchDesktop: async options => {
      calls.push(['windows-start']);
      if (!await options.consent('private')) return '已取消。';
      await options.idle();
      if (state.pause) await state.pause;
      state.shared = true;
      return 'Windows shared';
    },
    MacDesktopSharing: class {
      constructor() { assert.equal(platform, 'darwin'); }
      async status(value) { calls.push(['mac-status', value]); return { state: 'restart', message: 'Mac status', canStart: true }; }
      async restart(value, id, confirm) {
        calls.push(['mac-start', value, id]);
        if (!await confirm(true)) return { state: 'restart', message: 'Mac status', canStart: true };
        if (state.pause) await state.pause;
        return { state: 'ready', message: 'Mac shared', canStart: false };
      }
    },
    testWindow: { webContents },
    testUpdater: { state: { canInstall: true } },
    console
  });
  const source = readFileSync(file, 'utf8').replace(/^import .+;\r?$/gm, '')
    .replaceAll('import.meta.url', JSON.stringify(file.href));
  vm.runInContext(source, context, { filename: fileURLToPath(file) });
  vm.runInContext('window = testWindow; updater = testUpdater;', context);
  return { calls, state, context, handlers, invoke: (method, id) => handlers.get('companion:desktopSharing')(event, method, id), event };
}

for (const platform of ['win32', 'darwin', 'linux']) {
  test(platform + ' registers one sharing handler and uses its own transport', async () => {
    const fixture = desktop(platform);
    const status = await fixture.invoke('status');
    if (platform === 'linux') {
      assert.equal(status, null);
      assert.equal(fixture.calls.length, 0);
      return;
    }
    assert.equal(status.platform, platform);
    assert.equal(status.canStart, true);
    const result = await fixture.invoke('start', platform === 'darwin' ? thread : null);
    assert.equal(result.state, platform === 'darwin' ? 'ready' : 'shared');
    const commands = fixture.calls.map(call => call[0]);
    assert.ok(commands.includes(platform === 'darwin' ? 'mac-start' : 'windows-start'));
    assert.ok(!commands.includes(platform === 'darwin' ? 'windows-start' : 'mac-start'));
    if (platform === 'darwin') {
      const call = fixture.calls.find(call => call[0] === 'mac-start');
      assert.equal(call[1].home, '/profiles/codex home');
      assert.equal(call[1].executable, '/installed/codex');
      assert.equal(call[2], thread);
    }
  });
}

for (const platform of ['win32', 'darwin']) {
  test(platform + ' respects cancellation, active tasks, concurrent restarts and updates', async () => {
    const fixture = desktop(platform);
    fixture.state.consent = false;
    assert.ok(['private', 'restart'].includes((await fixture.invoke('start')).state));
    fixture.state.consent = true;
    fixture.state.tasks = [{ status: 'running' }];
    await assert.rejects(fixture.invoke('start'), /任务正在执行/);
    fixture.state.tasks = [];
    let finish;
    fixture.state.pause = new Promise(resolve => { finish = resolve; });
    const pending = fixture.invoke('start');
    await new Promise(resolve => setImmediate(resolve));
    await assert.rejects(fixture.invoke('start'), /无法切换/);
    await assert.rejects(fixture.handlers.get('companion:updates')(fixture.event, 'install'), /切换桌面共享/);
    finish();
    await pending;
  });
}

test('Mac rejects invalid or unknown original threads before requesting a restart', async () => {
  const fixture = desktop('darwin');
  await assert.rejects(fixture.invoke('start', 'bad-thread'), /无效/);
  await assert.rejects(fixture.invoke('start', '87654321-4321-4321-4321-cba987654321'), /重新选择/);
  assert.ok(!fixture.calls.some(call => call[0] === 'mac-start'));
});

function renderer(platform) {
  const html = readFileSync(new URL('../desktop/ui/index.html', import.meta.url), 'utf8');
  const ids = [...html.matchAll(/id="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  const node = () => ({
    value: '', hidden: true, handlers: {}, classList: { toggle() {} },
    addEventListener(name, action) { this.handlers[name] = action; },
    replaceChildren(...items) { this.children = items; },
    append() {}
  });
  const nodes = new Map(ids.map(id => [id, node()]));
  const calls = [];
  const status = platform === 'darwin' ? { state: 'restart', message: 'Mac status', canStart: true } :
    { state: 'private', message: 'Windows status', canStart: true };
  const snapshot = { version: '1.1.17', state: 'stopped', config: { workspaces: [] },
    devices: [], origins: [], tasks: [{ id: thread, title: 'Original session', sharedThread: true }] };
  const source = readFileSync(new URL('../desktop/ui/renderer.js', import.meta.url), 'utf8');
  vm.runInNewContext(source, {
    document: { getElementById(id) { assert.ok(nodes.has(id), id); return nodes.get(id); },
      querySelector: node, querySelectorAll: () => [], createElement: node },
    window: { addEventListener() {}, companion: {
      call: async () => snapshot, onUpdate() {}, updates: () => new Promise(() => {}),
      desktopSharing: async (method, id) => {
        calls.push([method, id]);
        if (platform === 'linux') return null;
        return { platform, ...status, ...(method === 'start' ? {
          state: platform === 'darwin' ? 'ready' : 'shared', message: 'Shared', canStart: false
        } : {}) };
      }
    } },
    Option: function(text, value) { this.text = text; this.value = value; },
    setInterval() {}, console
  });
  return { nodes, calls };
}

for (const platform of ['win32', 'darwin', 'linux']) {
  test(platform + ' displays the shared UI and sends the appropriate restart request', async () => {
    const { nodes, calls } = renderer(platform);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(nodes.get('desktopSharing').hidden, platform === 'linux');
    if (platform === 'linux') return;
    assert.equal(nodes.get('sharingThreadField').hidden, platform !== 'darwin');
    assert.equal(nodes.get('startSharing').hidden, false);
    nodes.get('sharingThread').value = thread;
    await nodes.get('startSharing').handlers.click();
    assert.equal(calls.find(call => call[0] === 'start')[1], platform === 'darwin' ? thread : null);
    assert.equal(nodes.get('notice').textContent, 'Shared');
    assert.equal(nodes.get('startSharing').hidden, true);
    assert.equal(nodes.get('startSharing').disabled, false);
  });
}
