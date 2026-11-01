import { spawn } from 'node:child_process';
import { mkdirSync, openSync, closeSync, statSync } from 'node:fs';
import path from 'node:path';
import { controlRequest } from './control.mjs';
import { VERSION } from './paths.mjs';
import { daemonLockAlive } from './process-lock.mjs';

const pending = new Map();
const gone = error => ['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code);
const samePath = (a, b) => typeof a === 'string' && typeof b === 'string' &&
  (process.platform === 'win32' ? path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase() : path.resolve(a) === path.resolve(b));
const matches = (status, layout) => status.version === VERSION && samePath(status.launcher, layout.launcher);
const newer = version => {
  if (!/^\d+\.\d+\.\d+$/.test(version || '')) return null;
  const current = VERSION.split('.').map(Number); const installed = version.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (current[i] !== installed[i]) return installed[i] > current[i];
  return false;
};
function validateInstallation(layout) {
  for (const filename of [layout.node, layout.cli, layout.launcher, layout.codex]) {
    try { if (!statSync(filename).isFile()) throw new Error('not a file'); }
    catch { throw new Error('当前安装缺少运行组件 ' + path.basename(filename) + '，请重新安装完整的 ClawMate Codex。'); }
  }
}
export async function ensureDaemon(directory, layout, dependencies = {}) {
  // GUI polling and multiple IPC actions must share the same upgrade/start operation.
  const key = path.resolve(directory);
  let operation = pending.get(key);
  if (!operation) {
    operation = startCompatibleDaemon(directory, layout, dependencies); pending.set(key, operation);
  }
  try { await operation; } finally { if (pending.get(key) === operation) pending.delete(key); }
}

async function startCompatibleDaemon(directory, layout, dependencies) {
  const request = dependencies.request || controlRequest;
  const launch = dependencies.launch || spawn;
  const pause = dependencies.pause || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const now = dependencies.now || Date.now;
  const locked = dependencies.locked || (() => daemonLockAlive(directory, layout));
  validateInstallation(layout);
  let previous;
  try { previous = await request(directory, 'status'); } catch (error) { if (!gone(error)) throw error; }
  if (previous) {
    if (matches(previous, layout)) return;
    if (newer(previous.version) !== false) throw new Error('后台服务版本较新或无法识别，请使用与后台匹配的新版 ClawMate Codex。');
    // stop() is authoritative: it disables new work and refuses active tasks/approvals.
    try { await request(directory, 'stop'); }
    catch { throw new Error('旧安装的后台仍在使用中，请先停止任务或等待操作完成，再重新打开当前版本。'); }
    try { await request(directory, 'quit'); } catch (error) { if (!gone(error)) throw error; }
    const shutdownDeadline = now() + 15000;
    let released = false;
    while (now() < shutdownDeadline) {
      try {
        const status = await request(directory, 'status');
        if (matches(status, layout)) return;
      } catch (error) {
        if (!gone(error)) throw error;
        if (!locked()) { released = true; break; }
      }
      await pause(100);
    }
    if (!released) throw new Error('旧后台尚未退出，请稍后重试；当前任务和配置没有被删除。');
  }
  // An unresponsive live owner must not trigger a new failing process on every
  // UI refresh. A stale/reused PID is safe to recover inside acquireDaemonLock.
  if (locked()) throw new Error('后台进程仍在启动或无法响应，请稍后重试并查看 ' + path.join(directory, 'daemon.log') + '；未结束现有进程。');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const log = openSync(path.join(directory, 'daemon.log'), 'a', 0o600);
  let child;
  try {
    child = launch(layout.node, [layout.cli, 'daemon'], { detached: true, windowsHide: true,
      stdio: ['ignore', log, log], env: { ...process.env, CLAWMATE_CODEX_DATA_DIR: directory, CLAWMATE_CODEX_RESOURCES: layout.base } });
  } finally { closeSync(log); }
  let failure; child.once('error', error => { failure = error; }); child.unref();
  child.once('exit', code => { failure = new Error('后台进程已退出（' + code + '），请查看 ' + path.join(directory, 'daemon.log') + '。'); });
  const deadline = now() + 60000;
  while (now() < deadline) {
    if (failure) throw new Error('无法启动内置运行组件：' + failure.message);
    try {
      const status = await request(directory, 'status');
      if (!matches(status, layout)) throw new Error('后台版本或安装路径不匹配，请退出旧安装后重试。');
      return;
    } catch (error) { if (!gone(error)) throw error; }
    await pause(250);
  }
  throw new Error('PC 服务未能启动，请查看应用数据目录中的 daemon.log。');
}

// Never call ensureDaemon here: exiting an already-stopped app must not start it.
export async function quitDaemon(directory, layout, dependencies = {}) {
  const request = dependencies.request || controlRequest;
  const pause = dependencies.pause || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const now = dependencies.now || Date.now;
  const locked = dependencies.locked || (() => daemonLockAlive(directory, layout));
  await pending.get(path.resolve(directory))?.catch(() => {});
  try { await request(directory, 'quit'); } catch (error) { if (!gone(error)) throw error; }
  const deadline = now() + 15000;
  while (locked()) {
    if (now() >= deadline) throw new Error('后台尚未退出，应用窗口已保留。请查看 ' + path.join(directory, 'daemon.log') + '。');
    await pause(100);
  }
}
