import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, unlinkSync, rmdirSync } from 'node:fs';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { DaemonRpc } from '../../bridge/codex/daemon-rpc.mjs';
import { validatedDaemonSocket } from '../../bridge/codex/daemon-discovery.mjs';
import { acceptDesktopConnections } from '../../bridge/codex/desktop-relay.mjs';
import { writePrivate } from './settings.mjs';

const statePath = directory => path.join(directory, 'share', 'active.json');
// Electron takes its single-instance lock before some desktop builds apply the
// profile override. Use the same explicit profile for both when one was supplied.
export function desktopLaunchArgs(env = process.env) {
  const profile = env.CODEX_ELECTRON_USER_DATA_PATH;
  return profile && path.isAbsolute(profile) ? ['--user-data-dir=' + profile] : [];
}
export function sharedDesktopState(directory) {
  try {
    const state = JSON.parse(readFileSync(statePath(directory), 'utf8'));
    if (!/^[a-f0-9]{12}$/.test(state.id) || !Number.isSafeInteger(state.pid) || state.pid < 1) return null;
    return { ...state, socket: path.join(directory, 'share', state.id, 's') };
  } catch { return null; }
}

// The desktop can use a WebSocket URL. Only its process receives this random URL.
// Keep the actual App Server on an ACL-protected native socket, also used by the phone bridge.
export async function prepareSharedDesktop(directory, cli, environment = process.env) {
  const id = randomBytes(6).toString('hex');
  const socket = path.join(directory, 'share', id, 's');
  if (Buffer.byteLength(socket) >= 104) throw new Error('连接器数据路径过长，无法创建系统共享套接字。');
  mkdirSync(path.dirname(path.dirname(socket)), { recursive: true, mode: 0o700 });
  const backend = spawn(cli, ['app-server', '--listen', 'unix://' + socket], {
    env: environment, stdio: 'ignore', windowsHide: true
  });
  let backendError;
  backend.once('error', error => { backendError = error; });
  const secretPath = '/' + randomBytes(32).toString('hex');
  const relay = http.createServer((_req, res) => { res.writeHead(404); res.end(); });
  relay.headersTimeout = 5000;
  const sockets = new Set();
  relay.on('connection', connection => { sockets.add(connection); connection.once('close', () => sockets.delete(connection)); });
  let connected;
  const accepted = new Promise(resolve => { connected = resolve; });
  acceptDesktopConnections(relay, secretPath, socket, { command:cli, environment }, connected);
  let closed = false;
  function close() {
    if (closed) return; closed = true;
    for (const client of sockets) client.destroy();
    relay.close();
    if (backend.exitCode === null && !backend.killed) backend.kill();
    if (sharedDesktopState(directory)?.id === id) { try { unlinkSync(statePath(directory)); } catch {} }
  }
  backend.once('close', () => {
    close();
    // Only discard this worker's own endpoint, after its listener has exited.
    try { unlinkSync(socket); } catch {}
    try { rmdirSync(path.dirname(socket)); } catch {}
  });
  try {
    const deadline = Date.now() + 12000;
    let verified = false;
    while (!closed && !backendError && Date.now() < deadline) {
      if (existsSync(path.dirname(socket)) && await validatedDaemonSocket(socket)) {
        const probe = new DaemonRpc(socket, { proxy: { command: cli, environment } });
        try { await probe.initialize(); await probe.request('thread/loaded/list', { limit: 1 }); verified = true; break; }
        finally { probe.close(); }
      }
      await delay(150);
    }
    if (!verified) throw new Error('当前 Codex 无法建立经过验证的共享后台。');
    await new Promise((resolve, reject) => { relay.once('error', reject); relay.listen(0, '127.0.0.1', resolve); });
    return { url: 'ws://127.0.0.1:' + relay.address().port + secretPath, accepted, close,
      activate(pid) { if (closed) throw new Error('共享后台已退出。'); writePrivate(statePath(directory), { id, pid }); } };
  } catch (error) { close(); throw error; }
}

// Runs outside the companion UI so hiding or quitting ClawMate cannot unplug an active desktop.
export async function sharedDesktopWorker(directory, cli) {
  if (!process.send || !cli) throw new Error('需要由连接器启动共享桌面。');
  let transport, desktop;
  const abandon = () => { if (!desktop) transport?.close(); };
  process.once('disconnect', abandon);
  try {
    transport = await prepareSharedDesktop(directory, cli);
    if (!process.connected) { transport.close(); return; }
    const timer = setTimeout(() => { abandon(); if (process.connected) process.disconnect(); }, 90000);
    timer.unref();
    process.once('message', async ({ executable }) => {
      clearTimeout(timer);
      if (!executable) { transport.close(); process.disconnect(); return; }
      try {
        const env = { ...process.env, CODEX_APP_SERVER_WS_URL: transport.url };
        delete env.CODEX_APP_SERVER_FORCE_CLI;
        desktop = spawn(executable, desktopLaunchArgs(env), { env, detached: true, stdio: 'ignore', cwd: path.dirname(executable) });
        const exited = new Promise(resolve => desktop.once('exit', () => { transport.close(); resolve(false); }));
        await new Promise((resolve, reject) => { desktop.once('spawn', resolve); desktop.once('error', reject); });
        if (process.connected) process.send({ kind: 'launched' });
        if (!await Promise.race([transport.accepted.then(() => true), exited])) throw new Error('桌面已退出。');
        transport.activate(desktop.pid);
        if (process.connected) { process.send({ kind: 'connected' }, () => { if (process.connected) process.disconnect(); }); }
      } catch (error) {
        transport.close();
        if (process.connected) { process.send({kind:'error', message:'共享启动未完成：' + error.message}, () => { if (process.connected) process.disconnect(); }); }
      }
    });
    process.send({ kind: 'ready' });
  } catch (error) {
    if (process.connected) process.send({ kind: 'error', message: error.message }, () => process.disconnect());
  }
}
