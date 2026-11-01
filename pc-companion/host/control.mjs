import net from 'node:net';
import { readFileSync, mkdirSync, chmodSync, lstatSync, realpathSync, unlinkSync } from 'node:fs';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { writePrivate } from './settings.mjs';
import { acquireDaemonLock } from './process-lock.mjs';
import { installLayout } from './paths.mjs';
import { controlAddress } from './control-address.mjs';
export { acquireDaemonLock } from './process-lock.mjs';

const digest = value => createHash('sha256').update(String(value || '')).digest();
export function controlEndpoint(directory, platform = process.platform) {
  const address = controlAddress(directory, platform === 'win32' ? { platform } : {
    platform, uid: process.getuid(), temporaryDirectory: realpathSync(os.tmpdir()),
    fallbackDirectory: realpathSync('/tmp')
  });
  if (platform === 'win32') return address;
  const folder = path.dirname(address);
  mkdirSync(folder, { mode: 0o700, recursive: true });
  const stat = lstatSync(folder);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || realpathSync(folder) !== folder) {
    throw new Error('本机控制目录不安全。');
  }
  chmodSync(folder, 0o700);
  return address;
}
export async function serveControl(manager, onQuit, existingUnlock) {
  const directory = manager.settings.directory;
  const unlock = existingUnlock || acquireDaemonLock(directory, manager.layout || installLayout());
  const address = controlEndpoint(directory);
  const token = randomBytes(32).toString('base64url');
  const secret = digest(token);
  const sockets = new Set();
  if (process.platform !== 'win32') { try { unlinkSync(address); } catch (e) { if (e.code !== 'ENOENT') { unlock(); throw e; } } }
  const server = net.createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
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
  } catch (error) {
    server.close(); unlock();
    throw new Error(`创建本机控制通道失败：${address}（${error.code || 'UNKNOWN'}）：${error.message}`, { cause: error });
  }
  return async () => {
    for (const socket of sockets) socket.destroy();
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
