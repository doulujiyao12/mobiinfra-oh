import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const thread = '12345678-1234-1234-1234-123456789abc';
const home = '/Users/example/Codex profile';
const bundle = '/Applications/ChatGPT.app';
const executable = bundle + '/Contents/Resources/codex';
const main = bundle + '/Contents/MacOS/ChatGPT';
const socket = home + '/app-server-control/app-server-control.sock';

// Emulate macOS commands and App Server responses while running the actual
// discovery, profile validation, confirmation and restart sequence.
function fixture() {
  const state = { running: true, shared: false, multiple: false, home, supported: true, threads: [thread] };
  const commands = [];
  const context = vm.createContext({
    path: path.posix, os: { homedir: () => '/Users/example' }, process: { env: {}, getuid: () => 501 },
    promisify: operation => operation,
    realpathSync: filename => filename,
    accessSync() {}, constants: { X_OK: 1, R_OK: 4 },
    lstatSync() { if (!state.shared) throw Object.assign(new Error('missing'), { code: 'ENOENT' }); return {}; },
    MAC_CODEX_BUNDLE_ID: 'com.openai.codex',
    macCodexDesktopBundles: () => [{ bundle, executable }],
    discoverDaemons: async profile => {
      assert.equal(profile.CODEX_HOME, home);
      return state.shared ? [socket] : [];
    },
    execFile: async (command, args) => {
      commands.push([command, args]);
      if (command === '/bin/ps' && args[0] === 'eww') {
        return { stdout: main + ' CODEX_HOME=' + state.home + ' OTHER=value' };
      }
      if (command === '/bin/ps') {
        return { stdout: state.running ? '100 1 501 ' + main + '\n101 100 501 ' + executable +
          (state.multiple ? '\n200 1 501 ' + main : '') : '' };
      }
      if (command === '/usr/bin/mdfind') return { stdout: bundle + '\0' };
      if (command === '/usr/bin/plutil') return { stdout: args[1] === 'CFBundleIdentifier' ? 'com.openai.codex' : 'ChatGPT' };
      if (command === executable) return { stdout: state.supported ? '--listen unix://' : 'unsupported' };
      if (command === '/usr/sbin/lsof') return { stdout: 'n' + socket };
      if (command === '/usr/bin/osascript') {
        assert.equal(args.at(-1), '100');
        state.running = false;
        return {};
      }
      if (command === '/usr/bin/open' && args[0] === '--help') return { stdout: '--env' };
      if (command === '/usr/bin/open') { state.running = true; state.shared = true; return {}; }
      throw new Error('Unexpected command ' + command);
    },
    DaemonRpc: class {
      constructor(filename) { assert.equal(filename, socket); }
      async initialize() {}
      async request(method) {
        assert.equal(method, 'thread/loaded/list');
        return { data: state.threads };
      }
      close() {}
    },
    delay: async () => {}, console
  });
  const source = readFileSync(new URL('../desktop/macos-sharing.mjs', import.meta.url), 'utf8')
    .replace(/^import .+;\r?$/gm, '').replace('export class MacDesktopSharing', 'class MacDesktopSharing');
  vm.runInContext(source + '\nglobalThis.Controller = MacDesktopSharing;', context);
  const controller = new context.Controller({ base: '/clawmate/resources', node: '/clawmate/resources/runtime/node' });
  return { controller, state, commands, profile: { executable, home } };
}

test('Mac normally exits the identified app, opens the selected original session and verifies its backend', async () => {
  const { controller, commands, profile } = fixture();
  const status = await controller.status(profile);
  assert.equal(status.state, 'restart');
  let consented = false;
  const result = await controller.restart(profile, thread, async running => {
    assert.equal(running, true); consented = true; return true;
  });
  assert.equal(consented, true);
  assert.equal(result.state, 'ready');
  const quit = commands.findIndex(([command]) => command === '/usr/bin/osascript');
  const opened = commands.findIndex(([command, args]) => command === '/usr/bin/open' && args[0] !== '--help');
  assert.ok(quit >= 0 && opened > quit);
  const args = commands[opened][1];
  assert.ok(args.includes('CODEX_HOME=' + home));
  assert.ok(args.includes('CODEX_CLI_PATH=/clawmate/resources/bin/codex-shared-desktop'));
  assert.ok(args.includes('CLAWMATE_DESKTOP_CODEX_EXECUTABLE=' + executable));
  assert.ok(args.includes('codex://threads/' + thread));
  assert.equal((await controller.status(profile)).state, 'ready');
  assert.equal(controller.progress, null);
});

test('Mac starts a closed desktop and respects cancellation without sending quit or open requests', async () => {
  const { controller, state, commands, profile } = fixture();
  assert.equal((await controller.restart(profile, null, async () => false)).state, 'restart');
  assert.ok(!commands.some(([command, args]) => command === '/usr/bin/osascript' || command === '/usr/bin/open' && args[0] !== '--help'));
  state.running = false;
  assert.equal((await controller.restart(profile, null, async running => { assert.equal(running, false); return true; })).state, 'ready');
  assert.ok(!commands.some(([command]) => command === '/usr/bin/osascript'));
});

test('Mac refuses another profile, multiple desktops, unsupported CLI and an unrelated control socket', async () => {
  for (const scenario of ['profile', 'multiple', 'unsupported', 'socket']) {
    const { controller, state, commands, profile } = fixture();
    if (scenario === 'profile') state.home = '/Users/example/different-profile';
    if (scenario === 'multiple') state.multiple = true;
    if (scenario === 'unsupported') state.supported = false;
    if (scenario === 'socket') { state.shared = true; state.running = false; }
    await assert.rejects(controller.restart(profile, null, async () => true));
    assert.ok(!commands.some(([command, args]) => command === '/usr/bin/osascript' || command === '/usr/bin/open' && args[0] !== '--help'), scenario);
    assert.equal(controller.progress, null);
  }
});
