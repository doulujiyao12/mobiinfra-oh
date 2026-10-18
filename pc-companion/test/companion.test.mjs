import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, existsSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import https from 'node:https';
import net from 'node:net';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { CompanionManager } from '../host/manager.mjs';
import { Settings } from '../host/settings.mjs';
import { serveControl, controlRequest, controlEndpoint } from '../host/control.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporaryDirectories = [];
const buildDir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-launcher-tests-'));
const launcher = path.join(buildDir, 'clawmate-codex' + (process.platform === 'win32' ? '.exe' : ''));
execFileSync('go', ['build', '-trimpath', '-o', launcher, '.'], { cwd: path.join(root, 'launcher'), env: { ...process.env, CGO_ENABLED: '0' } });
process.on('exit', () => {
  rmSync(buildDir, { recursive: true, force: true });
  for (const dir of temporaryDirectories) rmSync(dir, { recursive: true, force: true });
});

class Rpc extends EventEmitter {
  calls = [];
  async initialize() {}
  close() { this.emit('stopped'); }
  send() {}
  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'account/read') return { requiresOpenaiAuth: true, account: { type: 'chatgpt', email: 'test@example.invalid' } };
    if (method === 'model/list') return { data: [{ model: 'test', supportedReasoningEfforts: [] }] };
    if (method === 'thread/start') return { thread: { id: randomUUID() } };
    if (method === 'turn/start') return { turn: { id: randomUUID(), status: 'inProgress' } };
    if (method === 'account/login/start') return { type: params.type, loginId: 'login', verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'ABCD' };
    return {};
  }
}
function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-companion-test-')); mkdirSync(path.join(dir, 'project'));
  temporaryDirectories.push(dir); return dir;
}
async function freePort() {
  const server = net.createServer(); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port;
}
function request(port, ca, route, body, token) {
  return new Promise((resolve, reject) => {
    const headers = { 'Content-Type': 'application/json' }; if (token) headers.Authorization = 'Bearer ' + token;
    const req = https.request({ hostname: '127.0.0.1', port, path: route, method: body ? 'POST' : 'GET', ca, headers }, res => {
      let data = ''; res.on('data', part => { data += part; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    }); req.on('error', reject); req.end(body ? JSON.stringify(body) : undefined);
  });
}
test('desktop and CLI configure one service, generate trusted LAN pairing and revoke a phone', async t => {
  const dir = fixture(t); const manager = new CompanionManager(path.join(dir, 'private'), { launcher }, { rpcFactory: () => new Rpc() });
  await manager.initialize();
  t.after(() => manager.close());
  const port = await freePort();
  manager.configure({ name: '测试电脑', host: '127.0.0.1', port, networkMode: 'lan', workspaces: [{ name: 'Project', path: path.join(dir, 'project') }] });
  const starting = manager.start();
  await assert.rejects(manager.start(), /正在启动/);
  const started = await starting; assert.equal(started.state, 'running');
  const pairing = await manager.createPairing(`https://127.0.0.1:${port}`);
  assert.ok(pairing.qr.startsWith('data:image/png;base64,'));
  assert.ok(pairing.encoded.startsWith('CLAWMATE-CODEX-PAIR:'));
  const ca = pairing.bundle.caCertificate;
  assert.ok(ca.length < 2048);
  const paired = await request(port, ca, '/v1/pair', { code: pairing.bundle.code, deviceName: 'Phone' });
  assert.equal(paired.status, 200); const token = paired.body.token;
  assert.equal((await request(port, ca, '/v1/info', null, token)).status, 200);
  assert.equal((await request(port, ca, '/v1/pair', { code: pairing.bundle.code, deviceName: 'Phone' })).status, 401);
  const restarted = new CompanionManager(manager.settings.directory, { launcher }, { rpcFactory: () => new Rpc() });
  assert.ok(restarted.pairing.authenticates(token));
  await manager.dispatch('revoke', { id: paired.body.deviceId });
  assert.equal((await request(port, ca, '/v1/info', null, token)).status, 401);
  assert.throws(() => manager.configure({}), /先停止/);
  await manager.stop(); assert.equal(manager.state, 'stopped');
});
test('settings refuse broad credential directories and keep root tokens private', t => {
  const dir = fixture(t); const settings = new Settings(path.join(dir, 'private'));
  const input = { name: 'PC', host: '0.0.0.0', port: 8787, networkMode: 'lan', workspaces: [{ name: 'Home', path: dir }] };
  assert.throws(() => settings.update(input), /主目录/);
  assert.equal(settings.publicValue().token, undefined);
  if (process.platform !== 'win32') assert.equal(statSync(settings.filename).mode & 0o777, 0o600);
});
test('native crypto creates matching SANs and retains pairing identity when IP changes', t => {
  const dir = fixture(t);
  const create = ips => JSON.parse(execFileSync(launcher, ['--internal-certificates', dir, JSON.stringify(ips)], { encoding: 'utf8' }));
  const first = create(['192.168.1.8']); const second = create(['192.168.1.9']);
  assert.equal(first.fingerprint, second.fingerprint);
  assert.equal(first.caCertificate, second.caCertificate);
  assert.ok(second.fingerprint.length === 95);
});
test('local control uses authenticated OS IPC and rejects unsupported commands', async t => {
  const dir = fixture(t); const manager = { settings: { directory: dir }, async dispatch(method) {
    if (method === 'status') return { state: 'running' }; throw new Error('Unsupported');
  } };
  const close = await serveControl(manager, () => {}); t.after(close);
  assert.equal((await controlRequest(dir, 'status')).state, 'running');
  await assert.rejects(controlRequest(dir, 'arbitraryShell'), /Unsupported/);
  const control = JSON.parse(readFileSync(path.join(dir, 'control.json'), 'utf8'));
  if (process.platform !== 'win32') assert.equal(statSync(control.address).mode & 0o777, 0o600);
  const result = await new Promise((resolve, reject) => {
    const socket = net.createConnection(control.address); let input = '';
    socket.on('error', reject); socket.on('connect', () => socket.write(JSON.stringify({ token: 'wrong', method: 'status' }) + '\n'));
    socket.on('data', chunk => { input += chunk; }); socket.on('end', () => resolve(JSON.parse(input)));
  });
  assert.equal(result.ok, false);
});
test('staged native terminal runs without Node or npm on PATH', t => {
  const target = process.env.CLAWMATE_TEST_TARGET || `${process.platform}-${process.arch}`;
  if (target !== `${process.platform}-${process.arch}`) return t.skip('Cross-built executable requires its native architecture');
  const executable = path.join(root, 'out', target, 'resources', 'bin', 'clawmate-codex' + (process.platform === 'win32' ? '.exe' : ''));
  if (!existsSync(executable)) return t.skip('Build stage first to test the standalone distribution');
  const result = execFileSync(executable, ['--version'], { encoding: 'utf8', env: { ...process.env, PATH: '/no-system-node', NODE_OPTIONS: '--invalid-user-option' } });
  assert.equal(result.trim(), '1.1.0');
});
test('Windows control endpoint uses the correct named pipe prefix', () => {
  const slash = String.fromCharCode(92);
  const prefix = slash.repeat(2) + '.' + slash + 'pipe' + slash;
  assert.ok(controlEndpoint('/example-private-directory', 'win32').startsWith(prefix));
  assert.equal(controlEndpoint('/example-private-directory', 'win32').slice(prefix.length).includes(slash), false);
});
