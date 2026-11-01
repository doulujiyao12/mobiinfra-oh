import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, unlinkSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ensureDaemon, quitDaemon } from '../host/daemon-client.mjs';
import { VERSION } from '../host/paths.mjs';

function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-upgrade-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const base = path.join(directory, 'new-install'); mkdirSync(base);
  const layout = { base, launcher: path.join(base, 'launcher'), node: path.join(base, 'node'),
    cli: path.join(base, 'cli.mjs'), codex: path.join(base, 'codex') };
  for (const name of [layout.launcher, layout.node, layout.cli, layout.codex]) writeFileSync(name, 'test fixture');
  const current = { version: VERSION, launcher: layout.launcher, state: 'stopped' };
  const previous = { version: '1.1.0', launcher: path.join(directory, 'old-C-drive', 'launcher'), state: 'error' };
  let status = previous; const calls = []; let launches = 0; let time = 0;
  const dependencies = { locked: () => false, now: () => time, pause: async ms => { time += ms; },
    request: async (_directory, method) => {
      calls.push(method);
      if (method === 'status') { if (status) return status; throw Object.assign(new Error('No daemon'), { code: 'ENOENT' }); }
      if (method === 'quit') { status = null; return {}; }
      if (method === 'stop') return { state: 'stopped' };
      throw new Error('Unexpected method');
    },
    launch: (binary, args, options) => {
      launches++; assert.equal(binary, layout.node); assert.equal(args[0], layout.cli);
      assert.equal(options.env.CLAWMATE_CODEX_RESOURCES, layout.base);
      assert.equal(options.windowsHide, true); status = current;
      const child = new EventEmitter(); child.unref = () => {}; return child;
    }
  };
  return { directory, layout, current, previous, dependencies, calls, launches: () => launches,
    setStatus: value => { status = value; } };
}

test('an idle old installation is stopped normally and restarted from the current directory', async t => {
  const f = fixture(t); await ensureDaemon(f.directory, f.layout, f.dependencies);
  assert.deepEqual(f.calls, ['status', 'stop', 'quit', 'status', 'status']); assert.equal(f.launches(), 1);
  await ensureDaemon(f.directory, f.layout, f.dependencies); assert.equal(f.launches(), 1);
});
test('same-version services at another installation path are also replaced', async t => {
  const f = fixture(t); f.setStatus({ ...f.previous, version: VERSION });
  await ensureDaemon(f.directory, f.layout, f.dependencies); assert.equal(f.launches(), 1);
});
test('busy service refusal never quits or launches another daemon', async t => {
  const f = fixture(t); const request = f.dependencies.request;
  f.dependencies.request = async (directory, method) => {
    if (method === 'stop') throw new Error('Tasks still running');
    return request(directory, method);
  };
  await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /仍在使用中/);
  assert.equal(f.calls.includes('quit'), false); assert.equal(f.launches(), 0);
});
test('missing current files fail before stopping an existing service', async t => {
  const f = fixture(t); unlinkSync(f.layout.launcher);
  await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /安装缺少运行组件 launcher/);
  assert.equal(f.calls.length, 0); assert.equal(f.launches(), 0);
});
test('newer daemons are not automatically downgraded and unknown versions are not terminated', async t => {
  const f = fixture(t);
  for (const version of ['999.0.0', 'unknown']) {
    f.setStatus({ ...f.previous, version });
    await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /版本较新或无法识别/);
  }
  assert.equal(f.calls.includes('quit'), false); assert.equal(f.launches(), 0);
});
test('concurrent UI actions share a single restart and validate the resulting daemon identity', async t => {
  const f = fixture(t); await Promise.all([
    ensureDaemon(f.directory, f.layout, f.dependencies), ensureDaemon(f.directory, f.layout, f.dependencies)
  ]); assert.equal(f.launches(), 1); assert.equal(f.calls.filter(method => method === 'quit').length, 1);
  f.setStatus(null); const launch = f.dependencies.launch;
  f.dependencies.launch = (...args) => { const child = launch(...args); f.setStatus(f.previous); return child; };
  await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /版本或安装路径不匹配/);
});
test('an old live lock is respected and a shutdown timeout does not launch a competing daemon', async t => {
  const f = fixture(t); f.dependencies.locked = () => true;
  await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /旧后台尚未退出/);
  assert.equal(f.launches(), 0);
});

test('an unreachable live owner does not spawn another daemon on each GUI poll', async t => {
  const f = fixture(t); f.setStatus(null); f.dependencies.locked = () => true;
  await assert.rejects(ensureDaemon(f.directory, f.layout, f.dependencies), /后台进程仍在启动或无法响应/);
  assert.equal(f.launches(), 0);
});
test('quit never starts a daemon and waits for its lock to release', async t => {
  const f = fixture(t); let checks = 0; f.dependencies.locked = () => ++checks < 4;
  await quitDaemon(f.directory, f.layout, f.dependencies);
  assert.deepEqual(f.calls, ['quit']); assert.equal(f.launches(), 0); assert.equal(checks, 4);
});
test('closing with no daemon is harmless; a stuck daemon keeps the app open', async t => {
  const f = fixture(t); f.dependencies.request = async () => { throw Object.assign(new Error('No daemon'), { code: 'ENOENT' }); };
  await quitDaemon(f.directory, f.layout, f.dependencies); assert.equal(f.launches(), 0);
  f.dependencies.locked = () => true;
  await assert.rejects(quitDaemon(f.directory, f.layout, f.dependencies), /后台尚未退出，应用窗口已保留/);
});
test('close waits for an in-flight startup before sending quit', async t => {
  const f = fixture(t); f.setStatus(null); let unblock;
  const original = f.dependencies.request; let first = true;
  f.dependencies.request = async (...args) => {
    if (first) { first = false; await new Promise(resolve => { unblock = resolve; }); }
    return original(...args);
  };
  const starting = ensureDaemon(f.directory, f.layout, f.dependencies);
  const closing = quitDaemon(f.directory, f.layout, f.dependencies);
  assert.equal(f.calls.includes('quit'), false); unblock();
  await Promise.all([starting, closing]);
  assert.equal(f.calls.at(-1), 'quit'); assert.equal(f.launches(), 1);
});
