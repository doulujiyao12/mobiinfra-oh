import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { isTailscaleIPv4, discoverTailscaleSockets, readTailscaleStatus, TailscaleDiscovery } from '../host/tailscale.mjs';

const running = ip => ({ BackendState: 'Running', TailscaleIPs: [ip], Self: { Online: true, TailscaleIPs: [ip] } });

test('accepts only valid local tailnet IPv4 addresses, never peer addresses', async () => {
  for (const ip of ['100.64.0.1', '100.124.13.114', '100.127.255.254']) assert.equal(isTailscaleIPv4(ip), true);
  for (const ip of ['100.63.0.1', '100.128.0.1', '172.16.0.98', '127.0.0.1', '100.124.13.999', 'example.com', 'fd7a::1', null]) assert.equal(isTailscaleIPv4(ip), false);
  const discovery = new TailscaleDiscovery({ platform: 'linux', discover: () => ['/test.sock'], query: async () => ({
    ...running('100.124.13.114'), Peer: { other: { TailscaleIPs: ['100.100.2.3'] } } }) });
  assert.deepEqual((await discovery.refresh()).addresses, ['100.124.13.114']);
});

test('Windows and macOS never inspect proc or query the Tailscale API', async () => {
  for (const platform of ['win32', 'darwin']) {
    const discovery = new TailscaleDiscovery({ platform, discover: () => assert.fail('no discovery'), query: () => assert.fail('no query') });
    assert.equal((await discovery.refresh({ force: true })).state, 'disabled');
  }
});

test('caches and coalesces queries, but forced refresh removes stale/offline addresses', async () => {
  let now = 0; let calls = 0; let current = running('100.124.13.114');
  const discovery = new TailscaleDiscovery({ platform: 'linux', now: () => now, discover: () => ['/test.sock'],
    query: async () => { calls++; await new Promise(resolve => setImmediate(resolve)); return current; } });
  await Promise.all([discovery.refresh(), discovery.refresh(), discovery.refresh()]);
  assert.equal(calls, 1); await discovery.refresh(); assert.equal(calls, 1);
  current = { ...running('100.124.13.114'), BackendState: 'NeedsLogin' };
  assert.deepEqual((await discovery.refresh({ force: true })).addresses, []); assert.equal(calls, 2);
  current = running('100.100.1.2'); now = 6000;
  assert.deepEqual((await discovery.refresh()).addresses, ['100.100.1.2']);
  current = { ...current, Self: { ...current.Self, Online: false } };
  assert.deepEqual((await discovery.refresh({ force: true })).addresses, []);
  current = { ...running('100.100.1.2'), Self: { Online: true, Expired: true, TailscaleIPs: ['100.100.1.2'] } };
  assert.deepEqual((await discovery.refresh({ force: true })).addresses, []);
});

test('failed queries clear old addresses and return diagnostics without raw API content', async () => {
  let failure = false;
  const discovery = new TailscaleDiscovery({ platform: 'linux', discover: () => ['/test.sock'], query: async () => {
    if (failure) throw Object.assign(new Error('private-details-must-not-appear'), { code: 'EACCES' });
    return running('100.124.13.114');
  } });
  await discovery.refresh(); failure = true;
  const result = await discovery.refresh({ force: true });
  assert.deepEqual(result.addresses, []); assert.match(result.message, /无权/);
  assert.ok(!JSON.stringify(result).includes('private-details'));
});

test('does not pick a random instance when different local Tailscale nodes are active', async () => {
  const discovery = new TailscaleDiscovery({ platform: 'linux', discover: () => ['/a.sock', '/b.sock'],
    query: async socket => running(socket === '/a.sock' ? '100.124.13.114' : '100.100.1.2') });
  const result = await discovery.refresh(); assert.equal(result.state, 'ambiguous'); assert.deepEqual(result.addresses, []);
});

test('no local socket produces an actionable, nonfatal status', async () => {
  const discovery = new TailscaleDiscovery({ platform: 'linux', discover: () => [] });
  const result = await discovery.refresh(); assert.equal(result.state, 'notFound'); assert.match(result.message, /CLAWMATE_TAILSCALE_SOCKET/);
});

async function unixServer(t, handler) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'cmt-ts-'));
  const socket = path.join(dir, 'ts.sock');
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); rmSync(dir, { recursive: true, force: true }); });
  return { dir, socket };
}

test('discovers a custom socket from a tailscaled process without requiring a CLI on PATH', { skip: process.platform === 'win32' }, async t => {
  const { dir, socket } = await unixServer(t, (_req, res) => res.end('{}'));
  const procRoot = path.join(dir, 'proc'); const folder = path.join(procRoot, '42'); mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, 'comm'), 'tailscaled\n');
  writeFileSync(path.join(folder, 'cmdline'), ['tailscaled', '--auth-key=secret-not-read-or-logged', '--socket', socket, ''].join('\0'));
  assert.ok(discoverTailscaleSockets({ env: {}, procRoot }).includes(socket));
  assert.deepEqual(discoverTailscaleSockets({ env: { CLAWMATE_TAILSCALE_SOCKET: socket }, procRoot: '/missing' }), [socket]);
  assert.deepEqual(discoverTailscaleSockets({ env: { CLAWMATE_TAILSCALE_SOCKET: '/missing.sock' }, procRoot }), []);
});

test('read-only Unix API omits peers and validates HTTP, JSON, size and hard timeout', { skip: process.platform === 'win32' }, async t => {
  let mode = 'ok';
  const { socket } = await unixServer(t, (req, res) => {
    assert.equal(req.method, 'GET'); assert.equal(req.url, '/localapi/v0/status?peers=false');
    assert.equal(req.headers.host, 'local-tailscaled.sock');
    if (mode === 'timeout') return;
    if (mode === 'denied') { res.writeHead(403); res.end('private error'); return; }
    res.end(mode === 'json' ? 'not JSON' : mode === 'large' ? 'x'.repeat(4096) : JSON.stringify(running('100.124.13.114')));
  });
  assert.equal((await readTailscaleStatus(socket)).BackendState, 'Running');
  mode = 'denied'; await assert.rejects(readTailscaleStatus(socket), { code: 'EACCES' });
  mode = 'json'; await assert.rejects(readTailscaleStatus(socket), { code: 'TAILSCALE_JSON' });
  mode = 'large'; await assert.rejects(readTailscaleStatus(socket, { maxBytes: 100 }), { code: 'TAILSCALE_SIZE' });
  mode = 'timeout'; await assert.rejects(readTailscaleStatus(socket, { timeout: 50 }), { code: 'ETIMEDOUT' });
});
