import { spawn } from 'node:child_process';
import { mkdirSync, openSync, closeSync } from 'node:fs';
import path from 'node:path';
import { controlRequest } from './control.mjs';

export async function ensureDaemon(directory, layout) {
  try { await controlRequest(directory, 'status'); return; } catch (error) {
    if (!['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code)) throw error;
  }
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const log = openSync(path.join(directory, 'daemon.log'), 'a', 0o600);
  const child = spawn(layout.node, [layout.cli, 'daemon'], { detached: true, windowsHide: true,
    stdio: ['ignore', log, log], env: { ...process.env, CLAWMATE_CODEX_DATA_DIR: directory, CLAWMATE_CODEX_RESOURCES: layout.base } });
  let failure; child.once('error', error => { failure = error; }); child.unref(); closeSync(log);
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (failure) throw new Error('无法启动内置运行组件：' + failure.message);
    try { await controlRequest(directory, 'status'); return; }
    catch (error) { if (!['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code)) throw error; }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  throw new Error('PC 服务未能启动，请查看应用数据目录中的 daemon.log。');
}
