import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, renameSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { ReleaseUpdater, chooseUpdate, compareVersions, assetNames, safeUpdateUrl, updateResponse,
  checksumFromText, quiesceForUpdate, startUpdateJob, UPDATE_REPOSITORY } from '../host/updates.mjs';
import { extractUpdate } from '../host/update-extract.mjs';
import { applyUpdate } from '../host/update-helper.mjs';
import { CompanionManager } from '../host/manager.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'clawmate-updates-'));
  t.after(() => rmSync(root, { recursive: true, force: true, maxRetries: 4 }));
  return root;
}
function release(version = '1.1.14', { platform = 'linux', arch = 'x64', kind = 'terminal', data = Buffer.from('release payload'), ...extra } = {}) {
  const tag = 'codex-bridge-v' + version; const name = assetNames(version, platform, arch, kind)[0];
  const asset = { name, size: data.length, state: 'uploaded', digest: 'sha256:' + hash(data), browser_download_url: `https://github.com/${UPDATE_REPOSITORY}/releases/download/${tag}/${name}` };
  return { tag_name: tag, draft: false, prerelease: false, body: 'Update notes', assets: [asset], ...extra };
}
function updaterFixture(t, options = {}) {
  const directory = fixture(t); const data = Buffer.from('release payload'); const source = release('1.1.14', { data, ...options });
  const calls = [];
  const fetcher = async (url, init) => { calls.push({ url, init }); return new Response(url.includes('api.github.com') ? JSON.stringify([source]) : data); };
  const updater = new ReleaseUpdater(directory, { platform: 'linux', arch: 'x64', kind: 'terminal', currentVersion: '1.1.13', fetcher, ...options });
  return { directory, data, source, updater, calls };
}

test('versions compare numerically, prereleases sort before stable and invalid versions are refused', () => {
  assert.ok(compareVersions('1.1.10', '1.1.9') > 0); assert.ok(compareVersions('2.0.0', '1.99.99') > 0);
  assert.ok(compareVersions('1.1.14-beta.10', '1.1.14-beta.2') > 0);
  assert.ok(compareVersions('1.1.14', '1.1.14-beta') > 0); assert.equal(compareVersions('1.1.13', '1.1.13'), 0);
  assert.throws(() => compareVersions('1.01.13', '1.1.13')); assert.throws(() => compareVersions('../../tmp', '1.1.13'));
});
test('only connector releases for the correct target/channel are offered; drafts and downgrade are ignored', () => {
  const options = { platform: 'linux', arch: 'x64', kind: 'terminal', currentVersion: '1.1.13' };
  const beta = release('1.1.16-beta.1', { prerelease: true });
  const values = [release('1.1.14'), release('1.1.12'), release('1.1.99', { draft: true }), beta,
    release('1.1.15', { arch: 'arm64' }), release('1.1.19', { tag_name: 'mobile-v1.1.19' })];
  assert.equal(chooseUpdate(values, options).version, '1.1.14');
  assert.equal(chooseUpdate(values, { ...options, channel: 'preview' }).version, '1.1.16-beta.1');
  const bad = release(); bad.assets[0].browser_download_url = 'https://evil.invalid/installer';
  assert.equal(chooseUpdate([bad], options), null);
});
test('HTTPS GitHub downloads validate every redirect and never follow arbitrary hosts', async () => {
  for (const value of ['http://github.com/a', 'https://github.com.evil.invalid/a', 'https://user:secret@github.com/a', 'file:///tmp/app']) assert.throws(() => safeUpdateUrl(value));
  let calls = 0;
  await assert.rejects(updateResponse('https://github.com/start', { fetcher: async () => { calls++; return new Response(null, { status: 302, headers: { location: 'https://evil.invalid/installer' } }); } }), /不受信任/);
  assert.equal(calls, 1);
});
test('coalesces simultaneous checks but rejects conflicting operations; errors never report latest', async t => {
  const f = updaterFixture(t); let finish;
  f.updater.fetcher = () => new Promise(resolve => { finish = resolve; });
  const a = f.updater.check(); const b = f.updater.check(); await Promise.resolve();
  assert.throws(() => f.updater.configure({ autoCheck: true, channel: 'preview' }), /等待/);
  await assert.rejects(f.updater.download(), /等待/);
  finish(new Response('[]')); await Promise.all([a, b]); assert.equal(f.updater.state.phase, 'latest');
  f.updater.fetcher = async () => new Response('rate limit', { status: 403 });
  await assert.rejects(f.updater.check(), /限制/); assert.equal(f.updater.state.phase, 'error');
});
test('checks without running a daemon; downloads, hashes and restores ready state after reopening', async t => {
  const f = updaterFixture(t); await f.updater.check(); await f.updater.download();
  assert.equal(f.updater.state.phase, 'ready'); assert.equal(f.updater.state.progress, 100);
  assert.deepEqual(readFileSync(await f.updater.verifiedFile()), f.data);
  const next = new ReleaseUpdater(f.directory, f.updater.options); assert.equal(next.state.phase, 'ready');
  next.later(); assert.equal(new ReleaseUpdater(f.directory, f.updater.options).state.ignoredVersion, '1.1.14');
  writeFileSync(await next.verifiedFile(), 'tampered'); await assert.rejects(next.verifiedFile(), /缓存已变化/);
  assert.equal(next.state.phase, 'available');
});
test('SHA256SUMS fallback is exact, detects duplicates and excludes unverified releases', async t => {
  const f = updaterFixture(t); delete f.source.assets[0].digest;
  f.source.assets.push({ name: 'SHA256SUMS.txt', state: 'uploaded' });
  f.updater.fetcher = async url => new Response(url.includes('api.github.com') ? JSON.stringify([f.source]) : url.endsWith('SHA256SUMS.txt') ? hash(f.data) + '  ' + f.source.assets[0].name + '\n' : f.data);
  await f.updater.check(); await f.updater.download(); assert.equal(f.updater.state.phase, 'ready');
  assert.throws(() => checksumFromText('a'.repeat(64) + '  other.zip', 'app.zip'), /缺失/);
  assert.throws(() => checksumFromText(('a'.repeat(64) + '  app.zip\n').repeat(2), 'app.zip'), /重复/);
  const g = updaterFixture(t); delete g.source.assets[0].digest; await g.updater.check();
  await assert.rejects(g.updater.download(), /缺少 SHA256/); assert.equal(g.updater.state.phase, 'available');
});
test('range downloads resume, a full response safely restarts, and hash failures never create installable files', async t => {
  for (const ranged of [true, false]) {
    const f = updaterFixture(t); await f.updater.check(); const part = path.join(f.updater.directory, f.source.assets[0].name + '.part');
    writeFileSync(part, f.data.subarray(0, 5));
    f.updater.fetcher = async (_url, init) => {
      assert.equal(init.headers.Range, 'bytes=5-');
      return ranged ? new Response(f.data.subarray(5), { status: 206, headers: { 'content-range': `bytes 5-${f.data.length - 1}/${f.data.length}` } }) : new Response(f.data);
    };
    await f.updater.download(); assert.deepEqual(readFileSync(await f.updater.verifiedFile()), f.data);
  }
  const f = updaterFixture(t); await f.updater.check(); f.updater.fetcher = async () => new Response(Buffer.alloc(f.data.length, 1));
  await assert.rejects(f.updater.download(), /校验失败/);
  assert.equal(existsSync(path.join(f.updater.directory, f.source.assets[0].name)), false);
});
test('partial streams remain resumable; cancellation and download locks do not touch task service', async t => {
  const f = updaterFixture(t); await f.updater.check();
  f.updater.fetcher = async () => new Response(new ReadableStream({ start(controller) {
    controller.enqueue(f.data.subarray(0, 4)); setTimeout(() => controller.error(new Error('network interrupted')), 30);
  } }));
  await assert.rejects(f.updater.download(), /network interrupted/);
  const part = path.join(f.updater.directory, f.source.assets[0].name + '.part'); assert.equal(readFileSync(part).length, 4);
  writeFileSync(path.join(f.updater.directory, 'download.lock'), JSON.stringify({ pid: process.pid, nonce: 'another-window' }));
  await assert.rejects(f.updater.download(), /另一窗口/);
});
test('preferences persist, damaged updater preferences do not break connection startup, Mac is manual', async t => {
  const f = updaterFixture(t, { platform: 'darwin', kind: 'desktop' });
  f.updater.configure({ autoCheck: false, channel: 'preview' });
  const next = new ReleaseUpdater(f.directory, f.updater.options); assert.equal(next.preferences.autoCheck, false); assert.equal(next.state.canInstall, false);
  writeFileSync(next.settingsFile, '{broken'); const fallback = new ReleaseUpdater(f.directory, f.updater.options);
  assert.equal(fallback.state.phase, 'idle'); assert.match(fallback.state.error, /默认值/);
});
test('pausing a streaming download aborts promptly and leaves the update available for retry', async t => {
  const f = updaterFixture(t); await f.updater.check();
  let started;
  const ready = new Promise(resolve => { started = resolve; });
  f.updater.fetcher = async (_url, options) => new Response(new ReadableStream({ start(controller) {
    controller.enqueue(f.data.subarray(0, 3));
    options.signal.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')), { once: true });
    started();
  } }));
  const download = f.updater.download(); const rejected = assert.rejects(download);
  await ready; f.updater.cancel(); await rejected;
  assert.equal(f.updater.state.phase, 'available'); assert.match(f.updater.state.error, /已暂停/);
});
test('installation quiescence refuses active/uncertain tasks and cancels preparation if shutdown fails', async () => {
  for (const status of ['running', 'waitingApproval', 'unknown', 'releasing']) {
    const calls = [];
    await assert.rejects(quiesceForUpdate('dir', {}, async (_d, method) => { calls.push(method); return { tasks: [{ status }] }; }, async () => { throw new Error('Must not quit'); }), /任务/);
    assert.deepEqual(calls, ['status']);
  }
  const calls = [];
  await assert.rejects(quiesceForUpdate('dir', {}, async (_d, method) => { calls.push(method); return method === 'prepareUpdate' ? { wasRunning: true } : { tasks: [] }; }, async () => { throw new Error('shutdown failed'); }), /shutdown failed/);
  assert.deepEqual(calls, ['status', 'prepareUpdate', 'cancelUpdate']);
});
test('daemon update preparation freezes new actions and cancellation restores the old service', async () => {
  const fake = { state: 'running', core: { locks: new Set(), list: () => [] },
    stop: async () => { fake.state = 'stopped'; }, start: async () => { fake.state = 'running'; }, status: () => ({ state: fake.state }) };
  const call = (method, body) => CompanionManager.prototype.dispatch.call(fake, method, body);
  assert.deepEqual(await call('prepareUpdate'), { wasRunning: true }); assert.equal(fake.state, 'stopped');
  await assert.rejects(call('start'), /准备安装/); await call('cancelUpdate'); assert.equal(fake.state, 'running');
});

function tar(entries) {
  const blocks = [];
  for (const { name, data = '', type = '0', mode = 0o755 } of entries) {
    const body = Buffer.from(data); const header = Buffer.alloc(512);
    header.write(name); const oct = (n, offset, length) => header.write(n.toString(8).padStart(length - 1, '0') + '\0', offset, length, 'ascii');
    oct(mode, 100, 8); oct(0, 108, 8); oct(0, 116, 8); oct(body.length, 124, 12); oct(0, 136, 12);
    header.fill(32, 148, 156); header[156] = type.charCodeAt(0); header.write('ustar\0', 257);
    oct(header.reduce((sum, byte) => sum + byte, 0), 148, 8);
    blocks.push(header, body, Buffer.alloc((512 - body.length % 512) % 512));
  }
  return gzipSync(Buffer.concat([...blocks, Buffer.alloc(1024)]));
}
test('safe archive extraction refuses traversal, links, duplicate files and unsupported PAX records', async t => {
  for (const entries of [[{ name: '../escape' }], [{ name: '/escape' }], [{ name: 'link', type: '2' }],
    [{ name: 'same', data: '1' }, { name: 'same', data: '2' }], [{ name: 'PaxHeader', type: 'x', data: '24 linkpath=../../escape\n' }]]) {
    const root = fixture(t); const filename = path.join(root, 'archive.tar.gz'); writeFileSync(filename, tar(entries));
    const output = path.join(root, 'stage'); mkdirSync(output);
    await assert.rejects(extractUpdate(filename, output, 'terminal'));
    assert.equal(existsSync(path.join(root, 'escape')), false);
  }
  const root = fixture(t); const filename = path.join(root, 'valid.tar.gz'); writeFileSync(filename, tar([{ name: 'bin/app', data: 'binary' }]));
  const output = path.join(root, 'stage'); mkdirSync(output); assert.equal(await extractUpdate(filename, output, 'terminal'), 1);
  assert.equal(readFileSync(path.join(output, 'bin/app'), 'utf8'), 'binary');
});
function installFixture(t, platform = 'linux') {
  const root = fixture(t); const installRoot = path.join(root, 'connector'); mkdirSync(path.join(installRoot, platform === 'win32' ? 'resources/host' : 'host'), { recursive: true });
  writeFileSync(path.join(installRoot, platform === 'win32' ? 'resources/host/cli.mjs' : 'host/cli.mjs'), 'old-version');
  const dataDir = path.join(root, 'private'); const folder = path.join(dataDir, 'updates/install-fixture'); mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(dataDir, 'pairing-preserve'), 'private data'); writeFileSync(path.join(dataDir, 'update-resume.json'), JSON.stringify({ version: '1.1.14', wasRunning: true }));
  const archive = path.join(dataDir, 'updates', platform === 'linux' ? 'app.tar.gz' : 'app.exe');
  const data = platform === 'linux' ? tar(['host/cli.mjs', 'bin/clawmate-codex', 'runtime/node', 'runtime/bin/codex'].map(name => ({ name, data: 'new-version' }))) : Buffer.from('MZinstaller');
  writeFileSync(archive, data);
  return { root, job: { version: '1.1.14', platform, kind: platform === 'linux' ? 'terminal' : 'desktop', installRoot, dataDir, folder, archive, size: data.length, sha256: hash(data), parentPid: process.pid } };
}
test('Linux replaces only the installation, keeps a rollback copy, preserves pairing and restores service', async t => {
  const { job } = installFixture(t); const calls = [];
  await applyUpdate(job, { parentAlive: () => false, run: (cmd, args) => { calls.push({ cmd, args }); return args.includes('--version') ? job.version : ''; } });
  assert.equal(readFileSync(path.join(job.installRoot, 'host/cli.mjs'), 'utf8'), 'new-version');
  assert.equal(readFileSync(path.join(job.dataDir, 'pairing-preserve'), 'utf8'), 'private data');
  const result = JSON.parse(readFileSync(path.join(job.dataDir, 'updates/install-result.json'), 'utf8'));
  assert.equal(result.status, 'completed'); assert.equal(readFileSync(path.join(result.backup, 'host/cli.mjs'), 'utf8'), 'old-version');
  assert.equal(calls[1].args.at(-1), 'start');
});
test('Linux swap failure rolls back and an invalid new runtime never replaces the old one', async t => {
  for (const failure of ['swap', 'version']) {
    const { job } = installFixture(t); let moves = 0;
    await assert.rejects(applyUpdate(job, { parentAlive: () => false, run: () => failure === 'version' ? 'wrong-version' : job.version,
      move: (a, b) => { if (++moves === 2 && failure === 'swap') throw new Error('swap failure'); renameSync(a, b); } }));
    assert.equal(readFileSync(path.join(job.installRoot, 'host/cli.mjs'), 'utf8'), 'old-version');
  }
});
test('Windows uses the confirmed NSIS update flags and preserves the original install directory', async t => {
  const { job } = installFixture(t, 'win32'); let sent;
  await applyUpdate(job, { parentAlive: () => false, launch: (filename, args) => {
    sent = { filename, args }; const child = new EventEmitter(); queueMicrotask(() => child.emit('exit', 0)); return child;
  } });
  assert.equal(sent.filename, job.archive); assert.deepEqual(sent.args, ['--updated', '/S', '--force-run', '/D=' + job.installRoot]);
});
test('helper launch records only restore intent, uses a detached owned process and never changes pairing', async t => {
  const { job } = installFixture(t); const prepared = { job, node: '/owned/node', helper: '/owned/helper', jobFile: '/owned/job.json' };
  await startUpdateJob(prepared, true, (_filename, _args, options) => {
    assert.equal(options.detached, true); assert.equal(options.windowsHide, true);
    const child = new EventEmitter(); child.unref = () => {}; queueMicrotask(() => child.emit('spawn')); return child;
  });
  assert.deepEqual(JSON.parse(readFileSync(path.join(job.dataDir, 'update-resume.json'), 'utf8')), { version: job.version, wasRunning: true });
  assert.equal(readFileSync(path.join(job.dataDir, 'pairing-preserve'), 'utf8'), 'private data');
});
