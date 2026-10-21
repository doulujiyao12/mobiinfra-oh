import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, existsSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { ensureDaemon, quitDaemon } from '../host/daemon-client.mjs';
import { daemonLockAlive, inspectProcess } from '../host/process-lock.mjs';
import { controlRequest } from '../host/control.mjs';
import { installLayout, VERSION } from '../host/paths.mjs';

test('packaged Windows daemon recovers a reused legacy PID and fully quits without touching its new owner', { timeout: 90000 }, async t => {
  if (process.platform !== 'win32') return t.skip('Windows PID-reuse regression');
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const layout = installLayout(path.join(root, 'out/win32-x64/resources'));
  if (!existsSync(layout.cli)) return t.skip('Stage Windows runtime first');
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clawmate-native-daemon-'));
  mkdirSync(path.join(directory, 'isolated-codex-home'));
  const owner = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120'],
    { windowsHide: true, stdio: 'ignore' });
  let daemon;
  t.after(async () => {
    if (daemon && daemon.exitCode === null) await quitDaemon(directory, layout).catch(() => {});
    owner.kill(); if (daemon && daemon.exitCode === null) { daemon.kill(); await once(daemon, 'exit').catch(() => {}); }
    rmSync(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  });
  await once(owner, 'spawn');
  writeFileSync(path.join(directory, 'daemon.lock'), JSON.stringify({ pid: owner.pid }));
  assert.equal(daemonLockAlive(directory, layout), false);
  const dependencies = { launch: (command, args, options) => {
    daemon = spawn(command, args, { ...options, env: { ...options.env, CODEX_HOME: path.join(directory, 'isolated-codex-home'),
      NODE_OPTIONS: '', NODE_PATH: '' } }); return daemon;
  } };
  try { await ensureDaemon(directory, layout, dependencies); }
  catch (error) { throw new Error(error.message + '\nIsolated fixture log:\n' + readFileSync(path.join(directory, 'daemon.log'), 'utf8')); }
  const status = await controlRequest(directory, 'status');
  assert.equal(status.version, VERSION); assert.equal(status.state, 'stopped'); assert.equal(status.account, null);
  const record = JSON.parse(readFileSync(path.join(directory, 'daemon.lock')));
  assert.equal(record.pid, daemon.pid); assert.ok(record.started); assert.equal(daemonLockAlive(directory, layout), true);
  await quitDaemon(directory, layout);
  if (daemon.exitCode === null) await once(daemon, 'exit');
  assert.equal(daemon.exitCode, 0); assert.equal(existsSync(path.join(directory, 'daemon.lock')), false);
  assert.equal(inspectProcess(layout, owner.pid).running, true);
  await quitDaemon(directory, layout); // Already stopped: never starts a new service.
});
