import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { acquireDaemonLock, daemonLockAlive } from '../host/process-lock.mjs';

function fixture(t) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-lock-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'daemon.lock');
  const self = { pid: process.pid, running: true, started: 'current-start', executable: process.execPath };
  let owner = { pid: 12345, running: true, started: 'old-start', executable: path.join(directory, 'node.exe') };
  const probe = pid => pid === process.pid ? self : owner;
  return { directory, filename, self, probe, setOwner: value => { owner = value; } };
}
test('legacy PID reused by an unrelated process is recovered without killing that process', t => {
  const f = fixture(t); writeFileSync(f.filename, JSON.stringify({ pid: 12345 }));
  f.setOwner({ pid: 12345, running: true, started: 'reused-start', executable: 'C:/Windows/system32/conhost.exe' });
  assert.equal(daemonLockAlive(f.directory, {}, f.probe), false);
  const release = acquireDaemonLock(f.directory, {}, f.probe);
  const current = JSON.parse(readFileSync(f.filename));
  assert.equal(current.pid, process.pid); assert.equal(current.started, f.self.started); assert.ok(current.nonce);
  release(); assert.equal(existsSync(f.filename), false);
});
test('a live legacy Node owner is preserved, even when IPC is unavailable', t => {
  const f = fixture(t); const original = JSON.stringify({ pid: 12345 }); writeFileSync(f.filename, original);
  assert.equal(daemonLockAlive(f.directory, {}, f.probe), true);
  assert.throws(() => acquireDaemonLock(f.directory, {}, f.probe), /已经运行或正在启动/);
  assert.equal(readFileSync(f.filename, 'utf8'), original);
});
test('matching executable with a different creation time is a reused PID, not the owner', t => {
  const f = fixture(t); writeFileSync(f.filename, JSON.stringify({ pid: 12345, executable: '/runtime/node.exe', started: 'first-start' }));
  f.setOwner({ pid: 12345, running: true, executable: '/runtime/node.exe', started: 'second-start' });
  const release = acquireDaemonLock(f.directory, {}, f.probe); release();
});
test('live exact identities, access denial, and corrupt locks fail without deleting data', t => {
  const f = fixture(t); writeFileSync(f.filename, JSON.stringify(f.self));
  assert.throws(() => acquireDaemonLock(f.directory, {}, f.probe), /已经运行或正在启动/);
  assert.throws(() => daemonLockAlive(f.directory, {}, () => { throw new Error('Access denied'); }), /Access denied/);
  assert.equal(existsSync(f.filename), true);
  writeFileSync(f.filename, '{corrupt');
  assert.throws(() => acquireDaemonLock(f.directory, {}, f.probe), /进程锁损坏/);
  assert.equal(readFileSync(f.filename, 'utf8'), '{corrupt');
});
test('dead owners are recoverable; an old release callback cannot delete a replacement lock', t => {
  const f = fixture(t); writeFileSync(f.filename, JSON.stringify({ pid: 12345 })); f.setOwner({ pid: 12345, running: false });
  const release = acquireDaemonLock(f.directory, {}, f.probe);
  const replacement = JSON.stringify({ pid: 12345, nonce: 'replacement' }); writeFileSync(f.filename, replacement);
  release(); assert.equal(readFileSync(f.filename, 'utf8'), replacement);
});
