import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtempSync, mkdirSync, readFileSync, existsSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { controlAddress } from '../host/control-address.mjs';
import { serveControl, controlRequest } from '../host/control.mjs';

const directory = '/Users/example/Library/Application Support/ClawMateCodex';
const macTmp = '/private/var/folders/ab/0123456789abcdefghijklmnopqrst/T';
const options = { platform: 'darwin', uid: 501, temporaryDirectory: macTmp, fallbackDirectory: '/private/tmp' };

test('macOS long canonical temporary path falls back before bind/chmod can use a truncated socket name', () => {
  const oldPath = `${macTmp}/clawmate-codex-501-${'a'.repeat(20)}/control.sock`;
  assert.ok(Buffer.byteLength(oldPath) > 103);
  const address = controlAddress(directory, options);
  assert.ok(address.startsWith('/private/tmp/clawmate-codex-501-'));
  assert.ok(address.endsWith('/control.sock'));
  assert.ok(Buffer.byteLength(address) <= 103);
});

test('short Unix paths retain their existing endpoint and do not migrate Linux unnecessarily', () => {
  for (const platform of ['darwin', 'linux']) {
    const address = controlAddress(directory, { ...options, platform, temporaryDirectory: '/tmp' });
    assert.match(address, /^\/tmp\/clawmate-codex-501-[a-f0-9]{20}\/control\.sock$/);
  }
});

test('Unix limit is checked in UTF-8 bytes rather than character count', () => {
  const temporaryDirectory = '/' + '测'.repeat(20);
  const address = controlAddress(directory, { ...options, temporaryDirectory });
  assert.ok(address.startsWith('/private/tmp/'));
});

test('unsupported long roots fail explicitly rather than accepting an unbindable path', () => {
  assert.throws(() => controlAddress(directory, { ...options, fallbackDirectory: '/' + 'x'.repeat(110) }), /103 字节上限/);
});

test('control channel remains deterministic per user and per data directory', () => {
  assert.equal(controlAddress(directory, options), controlAddress(directory, { ...options }));
  assert.notEqual(controlAddress(directory, options), controlAddress(directory + '-other', options));
  assert.notEqual(controlAddress(directory, options), controlAddress(directory, { ...options, uid: 502 }));
});

test('Windows retains its named pipe without touching Unix temporary paths', () => {
  assert.match(controlAddress(directory, { platform: 'win32' }), /^\\\\\.\\pipe\\clawmate-codex-[a-f0-9]{20}$/);
});

test('local control server publishes a working endpoint, rejects a wrong token, and removes its descriptor on close', async t => {
  const scratch = fileURLToPath(new URL('../../.codex-tmp/', import.meta.url));
  mkdirSync(scratch, { recursive: true });
  const dataDir = mkdtempSync(path.join(scratch, 'clawmate-control-test-'));
  t.after(() => rmSync(dataDir, { recursive: true, force: true }));
  let unlocks = 0;
  const close = await serveControl({ settings: { directory: dataDir },
    dispatch: async method => ({ state: method === 'status' ? 'stopped' : 'unknown' }) }, () => {}, () => { unlocks++; });
  t.after(() => unlocks ? undefined : close());
  const descriptor = path.join(dataDir, 'control.json');
  const control = JSON.parse(readFileSync(descriptor, 'utf8'));
  if (process.platform !== 'win32') {
    assert.ok(Buffer.byteLength(control.address) <= (process.platform === 'darwin' ? 103 : 107));
    assert.equal(statSync(path.dirname(control.address)).mode & 0o777, 0o700);
    assert.equal(statSync(control.address).mode & 0o777, 0o600);
  }
  assert.equal((await controlRequest(dataDir, 'status')).state, 'stopped');
  const rejected = await new Promise((resolve, reject) => {
    const socket = net.createConnection(control.address);
    socket.setEncoding('utf8'); let response = '';
    socket.on('error', reject);
    socket.setTimeout(3000, () => { socket.destroy(); reject(new Error('fixture request timed out')); });
    socket.on('connect', () => socket.write(JSON.stringify({ token: 'wrong', method: 'status' }) + '\n'));
    socket.on('data', chunk => { response += chunk; });
    socket.on('end', () => { socket.destroy(); resolve(JSON.parse(response)); });
  });
  assert.equal(rejected.ok, false);
  await close();
  assert.equal(unlocks, 1);
  assert.equal(existsSync(descriptor), false);
});
