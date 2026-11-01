import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, openSync, writeFileSync, closeSync, unlinkSync, mkdirSync } from 'node:fs';
import path from 'node:path';

const samePath = (a, b) => typeof a === 'string' && typeof b === 'string' &&
  (process.platform === 'win32' ? path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase() : path.resolve(a) === path.resolve(b));
export function inspectProcess(layout, pid) {
  const value = JSON.parse(execFileSync(layout.launcher, ['--internal-process-info', String(pid)],
    { encoding: 'utf8', windowsHide: true, timeout: 5000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'] }));
  if (value.pid !== pid || typeof value.running !== 'boolean' ||
      (value.running && (!value.executable || !value.started))) throw new Error('无法核对后台进程身份。');
  return value;
}
function readLock(filename) {
  try {
    const contents = readFileSync(filename, 'utf8'); const value = JSON.parse(contents);
    if (!Number.isSafeInteger(value.pid) || value.pid < 1 || value.pid > 0xffffffff) throw new Error();
    return { contents, value };
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new Error('本机进程锁损坏，程序没有覆盖它，请检查应用数据目录中的 daemon.lock。');
  }
}
function isOwner(record, probe) {
  const info = probe(record.pid);
  if (!info.running) return false;
  if (record.started && record.executable) {
    return record.started === info.started && samePath(record.executable, info.executable);
  }
  // Old versions recorded only a PID. A live Node process could still be an old
  // daemon, so keep it; an unrelated executable (e.g. conhost.exe) is a reused PID.
  return /^node(?:\.exe)?$/i.test(path.basename(info.executable));
}
export function daemonLockAlive(directory, layout, probe = pid => inspectProcess(layout, pid)) {
  const record = readLock(path.join(directory, 'daemon.lock'));
  return record ? isOwner(record.value, probe) : false;
}
export function acquireDaemonLock(directory, layout, probe = pid => inspectProcess(layout, pid)) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const filename = path.join(directory, 'daemon.lock');
  const self = probe(process.pid);
  if (!self.running) throw new Error('无法核对当前后台进程身份。');
  const contents = JSON.stringify({ pid: process.pid, started: self.started, executable: self.executable, nonce: randomUUID() });
  for (let attempt = 0; attempt < 5; attempt++) {
    let fd;
    try { fd = openSync(filename, 'wx', 0o600); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const record = readLock(filename);
      if (!record) continue;
      if (isOwner(record.value, probe)) throw new Error('PC 服务已经运行或正在启动，请稍后重试；未结束任何现有进程。');
      // Recheck before deleting so a concurrent starter's new lock is preserved.
      if (readLock(filename)?.contents === record.contents) {
        try { unlinkSync(filename); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      }
      continue;
    }
    try { writeFileSync(fd, contents); } finally { closeSync(fd); }
    return () => { if (readLock(filename)?.contents === contents) unlinkSync(filename); };
  }
  throw new Error('后台正在被另一个窗口启动，请稍后重试。');
}
