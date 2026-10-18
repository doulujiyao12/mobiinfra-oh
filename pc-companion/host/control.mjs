import net from 'node:net';
import { readFileSync, mkdirSync, chmodSync, lstatSync, realpathSync, writeFileSync, unlinkSync, openSync, closeSync } from 'node:fs';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { writePrivate } from './settings.mjs';

const digest = value => createHash('sha256').update(String(value || '')).digest();
export function controlEndpoint(directory, platform = process.platform) {
  const hash = createHash('sha256').update(directory).digest('hex').slice(0, 20);
  if (platform === 'win32') return `\\\\.\\pipe\\clawmate-codex-${hash}`;
  const folder = path.join(realpathSync(os.tmpdir()), `clawmate-codex-${process.getuid()}-${hash}`);
  mkdirSync(folder, { mode: 0o700, recursive: true });
  const stat = lstatSync(folder);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || realpathSync(folder) !== folder) {
    throw new Error('本机控制目录不安全。');
  }
  chmodSync(folder, 0o700);
  return path.join(folder, 'control.sock');
}
function acquireLock(directory) {
  const filename = path.join(directory, 'daemon.lock');
  try {
    const fd = openSync(filename, 'wx', 0o600); writeFileSync(fd, JSON.stringify({ pid: process.pid })); closeSync(fd);
    return () => { try { unlinkSync(filename); } catch {} };
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let pid;
    try { pid = JSON.parse(readFileSync(filename, 'utf8')).pid; } catch { throw new Error('本机进程锁损坏，请检查 PC 应用状态。'); }
    if (!Number.isInteger(pid) || pid < 1) throw new Error('本机进程锁无效。');
    try { process.kill(pid, 0); }
    catch (e) {
      if (e.code === 'ESRCH') { unlinkSync(filename); return acquireLock(directory); }
      throw e;
    }
    throw new Error('PC 服务已经运行，请使用 status、stop 或桌面控制界面。');
  }
}
export function acquireDaemonLock(directory) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  return acquireLock(directory);
}

export async function serveControl(manager, onQuit, existingUnlock) {
  const directory = manager.settings.directory;
  const unlock = existingUnlock || acquireLock(directory);
  const address = controlEndpoint(directory);
  const token = randomBytes(32).toString('base64url');
  const secret = digest(token);
  if (process.platform !== 'win32') { try { unlinkSync(address); } catch (e) { if (e.code !== 'ENOENT') { unlock(); throw e; } } }
  const server = net.createServer(socket => {
    socket.setEncoding('utf8');
    socket.setTimeout(60000, () => socket.destroy());
    let input = ''; let answered = false;
    socket.on('error', () => {});
    socket.on('data', async chunk => {
      if (answered) return;
      input += chunk;
      if (Buffer.byteLength(input) > 64000) return socket.destroy();
      if (!input.includes('\n')) return;
      answered = true;
      try {
        const request = JSON.parse(input.slice(0, input.indexOf('\n')));
        if (!timingSafeEqual(digest(request.token), secret)) throw new Error('本机控制鉴权失败。');
        if (request.method === 'quit') {
          socket.end(JSON.stringify({ ok: true, result: { stopped: true } }) + '\n');
          setImmediate(onQuit); return;
        }
        const result = await manager.dispatch(request.method, request.body);
        socket.end(JSON.stringify({ ok: true, result }) + '\n');
      } catch (error) { socket.end(JSON.stringify({ ok: false, error: error.message }) + '\n'); }
    });
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(address, resolve); });
    if (process.platform !== 'win32') chmodSync(address, 0o600);
    writePrivate(path.join(directory, 'control.json'), { address, token, pid: process.pid });
  } catch (error) { server.close(); unlock(); throw error; }
  return async () => {
    await new Promise(resolve => server.close(resolve));
    try { unlinkSync(path.join(directory, 'control.json')); } catch {}
    unlock();
  };
}

export async function controlRequest(directory, method, body = {}) {
  const control = JSON.parse(readFileSync(path.join(directory, 'control.json'), 'utf8'));
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(control.address);
    socket.setEncoding('utf8');
    let input = ''; let settled = false;
    const fail = error => { if (!settled) { settled = true; socket.destroy(); reject(error); } };
    socket.setTimeout(55000, () => fail(new Error('本机服务响应超时。')));
    socket.on('error', fail);
    socket.on('connect', () => socket.write(JSON.stringify({ token: control.token, method, body }) + '\n'));
    socket.on('data', chunk => {
      input += chunk;
      if (Buffer.byteLength(input) > 8 * 1024 * 1024) return fail(new Error('本机服务响应过大。'));
      if (!input.includes('\n')) return;
      try {
        const response = JSON.parse(input.slice(0, input.indexOf('\n')));
        if (!response.ok) return fail(new Error(response.error));
        settled = true; socket.destroy(); resolve(response.result);
      } catch (error) { fail(error); }
    });
    socket.on('end', () => { if (!settled) fail(new Error('本机服务连接提前结束。')); });
  });
}
