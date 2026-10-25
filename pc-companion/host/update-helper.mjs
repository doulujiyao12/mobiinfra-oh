import { readFileSync, statSync, realpathSync, renameSync, mkdtempSync, writeFileSync, mkdirSync, chmodSync, lstatSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { extractUpdate } from './update-extract.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function digest(filename) { const hash = createHash('sha256'); for await (const block of createReadStream(filename)) hash.update(block); return hash.digest('hex'); }
function saveResult(job, status, message, backup = '') {
  writeFileSync(path.join(job.dataDir, 'updates', 'install-result.json'), JSON.stringify({ version: job.version, status, message, backup, time: Date.now() }) + '\n', { mode: 0o600 });
}
export async function applyUpdate(job, dependencies = {}) {
  const launch = dependencies.launch || spawn; const run = dependencies.run || execFileSync;
  const move = dependencies.move || renameSync;
  const alive = dependencies.parentAlive || (pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } });
  if (!['linux', 'win32'].includes(job.platform) || !['desktop', 'terminal'].includes(job.kind) || !/^[\d]+\.[\d]+\.[\d]+(?:-[a-zA-Z0-9.-]+)?$/.test(job.version) ||
      !/^[a-f\d]{64}$/.test(job.sha256) || !Number.isSafeInteger(job.parentPid) || job.parentPid < 1) throw new Error('更新任务无效');
  const root = realpathSync(job.installRoot); const data = realpathSync(job.dataDir); const folder = realpathSync(job.folder);
  if (root !== path.resolve(job.installRoot) || data !== path.resolve(job.dataDir) || path.dirname(folder) !== path.join(data, 'updates') ||
      !path.basename(folder).startsWith('install-') || path.dirname(path.resolve(job.archive)) !== path.join(data, 'updates')) throw new Error('更新目录校验失败');
  const relative = path.relative(root, data);
  if (root === path.parse(root).root || !relative || relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative)) throw new Error('更新不能覆盖应用数据目录');
  if (statSync(job.archive).size !== job.size || await digest(job.archive) !== job.sha256) throw new Error('安装前文件校验失败');
  const liveResources = job.kind === 'desktop' ? path.join(root, 'resources') : root;
  if (!statSync(path.join(liveResources, 'host', 'cli.mjs')).isFile()) throw new Error('当前安装目录无效');
  const deadline = Date.now() + 120000;
  while (true) {
    if (!alive(job.parentPid)) break;
    if (Date.now() >= deadline) throw new Error('旧应用尚未退出，已取消安装；请重新打开应用后重试');
    await pause(250);
  }
  const env = { ...process.env, CLAWMATE_CODEX_DATA_DIR: data }; delete env.NODE_OPTIONS; delete env.NODE_PATH; delete env.CLAWMATE_CODEX_RESOURCES;
  if (job.platform === 'win32') {
    if (job.kind !== 'desktop' || path.extname(job.archive) !== '.exe') throw new Error('Windows 终端包需手动替换');
    await new Promise((resolve, reject) => {
      const child = launch(job.archive, ['--updated', '/S', '--force-run', `/D=${root}`], { windowsHide: true, stdio: 'ignore', env });
      child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(new Error(`安装器退出（${code}），可手动打开下载文件重试`)));
    });
    saveResult(job, 'completed', '安装器已完成更新'); return;
  }
  const parent = path.dirname(root);
  if (lstatSync(root).isSymbolicLink()) throw new Error('请更新实际安装目录，不能替换目录链接');
  const stage = mkdtempSync(path.join(parent, '.clawmate-stage-'));
  await extractUpdate(job.archive, stage, job.kind);
  const resources = job.kind === 'desktop' ? path.join(stage, 'resources') : stage;
  for (const name of ['bin/clawmate-codex', 'runtime/node', 'runtime/bin/codex', 'host/cli.mjs']) {
    if (!statSync(path.join(resources, name)).isFile()) throw new Error('新版本缺少必要运行组件');
  }
  const reported = run(path.join(resources, 'runtime/node'), [path.join(resources, 'host/cli.mjs'), '--version'], {
    env: { ...env, CLAWMATE_CODEX_RESOURCES: resources }, encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  if (reported !== job.version) throw new Error('新版本运行检查失败，保留旧安装');
  const backup = path.join(parent, `.clawmate-backup-${Date.now()}-${path.basename(stage).slice(-6)}`);
  move(root, backup);
  try { move(stage, root); }
  catch (error) { move(backup, root); throw error; }
  let warning = '';
  try {
    const installed = job.kind === 'desktop' ? path.join(root, 'resources') : root;
    const marker = JSON.parse(readFileSync(path.join(data, 'update-resume.json'), 'utf8'));
    if (marker.wasRunning) run(path.join(installed, 'runtime/node'), [path.join(installed, 'host/cli.mjs'), 'start'], {
      env: { ...env, CLAWMATE_CODEX_RESOURCES: installed }, encoding: 'utf8', timeout: 90000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) {
    // The new program is valid; failed network/login/service startup must not
    // roll back files underneath a process that may have started successfully.
    warning = '程序已更新，连接服务需手动启动：' + error.message;
  }
  if (job.kind === 'desktop') {
    try {
      const child = launch(path.join(root, 'clawmate-codex-desktop'), [], { detached: true, stdio: 'ignore', env });
      await new Promise((resolve, reject) => { child.once('error', reject); child.once('spawn', () => { child.unref(); resolve(); }); });
    } catch (error) { warning = '程序已更新，应用需手动打开：' + error.message; }
  }
  saveResult(job, 'completed', warning || '更新完成；旧安装保留在回滚目录', backup);
}
async function main() {
  const filename = process.argv[2]; if (!filename || path.basename(filename) !== 'job.json') throw new Error('缺少更新任务文件');
  const job = JSON.parse(readFileSync(filename, 'utf8'));
  if (realpathSync(path.dirname(filename)) !== realpathSync(job.folder)) throw new Error('更新任务位置无效');
  try { saveResult(job, 'installing', '正在校验并安装更新'); await applyUpdate(job); }
  catch (error) { saveResult(job, 'failed', error.message); console.error('安装更新失败：' + error.message); process.exitCode = 1; }
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main().catch(() => { process.exitCode = 1; });
