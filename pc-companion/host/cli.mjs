import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { CompanionManager } from './manager.mjs';
import { Settings, writePrivate } from './settings.mjs';
import { dataDirectory, installLayout, VERSION } from './paths.mjs';
import { controlRequest, serveControl, acquireDaemonLock } from './control.mjs';
import { ensureDaemon, quitDaemon } from './daemon-client.mjs';
import { ReleaseUpdater, quiesceForUpdate, startUpdateJob } from './updates.mjs';

const HELP = `ClawMate Codex ${VERSION}
无需 Node.js、npm 或源码。桌面安装程序已内置相同命令行工具。

clawmate-codex setup                 交互配置电脑名称、项目和监听端口
clawmate-codex setup --project PATH  配置项目（可用于无桌面的服务器）
clawmate-codex login                 使用设备验证码登录 Codex
clawmate-codex start                 后台启动手机连接服务
clawmate-codex serve                 在当前终端运行服务（需已配置并登录）
clawmate-codex status                查看状态、项目和连接地址
clawmate-codex pair --output FILE    导出 5 分钟内有效的一次性手机配对文件
clawmate-codex devices               查看已配对设备
clawmate-codex revoke DEVICE_ID      撤销设备连接权限
clawmate-codex stop                  停止接受手机连接（有运行任务时拒绝停止）
clawmate-codex quit                  退出 PC 服务，会中断正在执行的任务
clawmate-codex reset-pairing --confirm 重置所有设备与本机配对证书（需要先 stop）
clawmate-codex check-update          检查 GitHub 上的连接器新版本
clawmate-codex update                下载、校验并更新（Linux 可自动替换并恢复连接）
clawmate-codex update --yes          无交互确认更新；--download-only 只下载
clawmate-codex --version             显示版本

可选：--origin https://IP:PORT 选择配对地址；setup --config FILE 导入公网 TLS 配置。
配置和登录凭据仅保存在本机，不需要编辑源代码。`;
function flag(args, name) { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; }

async function daemon(directory, layout, startOnReady) {
  const unlock = acquireDaemonLock(directory, layout);
  let manager;
  let closeControl;
  let closing = false;
  const close = async () => {
    if (closing) return; closing = true;
    let failed = false;
    try { await manager?.close(); }
    catch (error) { console.error('关闭运行组件失败：' + error.message); failed = true; }
    finally { try { await closeControl?.(); } finally { unlock(); } }
    process.exit(failed ? 1 : 0);
  };
  process.on('SIGTERM', close); process.on('SIGINT', close);
  try {
    manager = new CompanionManager(directory, layout);
    await manager.initialize();
    closeControl = await serveControl(manager, close, unlock);
    let resume;
    try { resume = JSON.parse(readFileSync(path.join(directory, 'update-resume.json'), 'utf8')); } catch (error) { if (error.code !== 'ENOENT') console.error('更新后的连接恢复标记不可用，请手动启动服务。'); }
    if (startOnReady || resume?.version === VERSION && resume.wasRunning) {
      try { await manager.start(); if (resume?.version === VERSION) unlinkSync(path.join(directory, 'update-resume.json')); }
      catch (error) { if (startOnReady) throw error; console.error('更新完成，连接服务需手动启动：' + error.message); }
    } else if (resume?.version === VERSION) unlinkSync(path.join(directory, 'update-resume.json'));
    console.log('ClawMate Codex 本机服务就绪。');
  } catch (error) {
    try { await manager?.close(); }
    finally { try { await closeControl?.(); } finally { unlock(); } }
    throw error;
  }
}
async function main() {
  const [command = 'help', ...args] = process.argv.slice(2);
  if (['help', '--help', '-h'].includes(command)) return console.log(HELP);
  if (command === '--version') return console.log(VERSION);
  const directory = dataDirectory(); const layout = installLayout();
  if (['check-update', 'update'].includes(command)) {
    const updater = new ReleaseUpdater(directory);
    if (args.includes('--preview')) updater.configure({ autoCheck: updater.preferences.autoCheck, channel: 'preview' });
    const info = await updater.check();
    if (command === 'check-update' || !info.hasUpdate) return console.log(JSON.stringify(info, null, 2));
    console.log(`发现连接器 ${info.latestVersion}：\n${info.notes}`);
    if (!args.includes('--yes')) {
      if (!stdin.isTTY) throw new Error('非交互更新请使用 update --yes；只查看版本可使用 check-update。');
      const rl = createInterface({ input: stdin, output: stdout });
      try { if (!/^(y|yes)$/i.test((await rl.question('下载并更新？[y/N] ')).trim())) return; } finally { rl.close(); }
    }
    let last = -1;
    updater.on('change', state => { if (state.phase === 'downloading' && state.progress >= last + 5) { last = state.progress; console.log(`下载更新 ${state.progress}%`); } });
    await updater.download(); const filename = await updater.verifiedFile(); console.log('下载校验完成：' + filename);
    if (args.includes('--download-only') || !updater.state.canInstall) return console.log('请打开下载包手动安装，原配置与配对信息保留在应用数据目录。');
    const prepared = await updater.prepareJob({ layout, installRoot: layout.base, dataDir: directory });
    const { wasRunning } = await quiesceForUpdate(directory, layout, controlRequest, quitDaemon);
    try { await startUpdateJob(prepared, wasRunning); }
    catch (error) { if (wasRunning) { await ensureDaemon(directory, layout); await controlRequest(directory, 'start'); } throw error; }
    return console.log('更新程序已启动，当前命令将退出；进度和结果位于应用数据目录 updates/install-result.json。');
  }
  if (command === 'daemon') return daemon(directory, layout, false);
  if (command === 'serve') {
    let attached = false;
    try { await controlRequest(directory, 'status'); attached = true; }
    catch (error) { if (!['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code)) throw error; }
    if (!attached) return daemon(directory, layout, true);
    await ensureDaemon(directory, layout);
    await controlRequest(directory, 'start');
    console.log('已连接本机后台服务，按 Ctrl+C 停止手机连接。');
    await new Promise(resolve => {
      let polling = false;
      const finish = () => { clearInterval(timer); process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop); resolve(); };
      const stop = async () => { try { await controlRequest(directory, 'stop'); finish(); } catch (error) { console.error(error.message); } };
      const timer = setInterval(async () => {
        if (polling) return; polling = true;
        try { if ((await controlRequest(directory, 'status')).state !== 'running') finish(); } catch { finish(); }
        finally { polling = false; }
      }, 1000);
      process.on('SIGINT', stop); process.on('SIGTERM', stop);
    });
    return;
  }
  if (command === 'setup') {
    // Configure through the same daemon as the GUI; no conflicting local writers.
    await ensureDaemon(directory, layout);
    let config = (await controlRequest(directory, 'status')).config;
    const imported = flag(args, '--config');
    if (imported) config = JSON.parse(readFileSync(path.resolve(imported), 'utf8'));
    else {
      let project = flag(args, '--project'); let name = flag(args, '--name');
      if (!project) {
        if (!stdin.isTTY) throw new Error('非交互终端请使用 setup --project /完整项目路径。');
        const rl = createInterface({ input: stdin, output: stdout });
        try {
          name = await rl.question(`电脑名称 [${config.name}]：`) || config.name;
          project = await rl.question('允许手机访问的项目文件夹完整路径：');
        } finally { rl.close(); }
      }
      config = { ...config, name: name || config.name,
        host: flag(args, '--host') || config.host, port: Number(flag(args, '--port') || config.port),
        workspaces: [{ name: path.basename(path.resolve(project)), path: path.resolve(project) }] };
    }
    await controlRequest(directory, 'configure', config);
    return console.log('配置已保存。接下来执行 clawmate-codex login，再执行 clawmate-codex start。');
  }
  // Inspection and explicit shutdown must remain available even for an older daemon.
  if (['status', 'stop', 'quit'].includes(command)) {
    try { return console.log(JSON.stringify(await controlRequest(directory, command), null, 2)); }
    catch (error) {
      if (!['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code)) throw error;
      if (command !== 'status') return console.log(JSON.stringify({ state: 'stopped' }));
    }
  }
  await ensureDaemon(directory, layout);
  if (command === 'login') {
    const login = await controlRequest(directory, 'login', { type: 'chatgptDeviceCode' });
    console.log(`请在浏览器打开：${login.verificationUrl}\n输入一次性登录码：${login.userCode}`);
    const deadline = Date.now() + 10 * 60000;
    while (Date.now() < deadline) {
      const status = await controlRequest(directory, 'status');
      if (status.login?.success || status.account) return console.log('Codex 登录成功。');
      if (status.login?.error) throw new Error(status.login.error);
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
    await controlRequest(directory, 'cancelLogin'); throw new Error('登录超时，请重新运行 login。');
  }
  if (command === 'pair') {
    const output = flag(args, '--output');
    if (!output) throw new Error('请用 --output 指定配对文件，例如 --output phone.clawmate-codex-pair.json。');
    const status = await controlRequest(directory, 'status');
    const origin = flag(args, '--origin') || status.origins[0];
    if (!origin) throw new Error('没有可用的连接地址，请检查网络。');
    const pairing = await controlRequest(directory, 'pair', { origin });
    writePrivate(path.resolve(output), pairing.bundle);
    return console.log('配对文件已导出。请在 5 分钟内传给自己的手机，在 Codex 页面导入。成功配对后该文件立即失效。');
  }
  if (command === 'devices') return console.log(JSON.stringify((await controlRequest(directory, 'status')).devices, null, 2));
  if (command === 'revoke') {
    if (!args[0]) throw new Error('请指定设备 ID。');
    await controlRequest(directory, 'revoke', { id: args[0] }); return console.log('设备连接权限已撤销。');
  }
  if (command === 'reset-pairing') {
    if (!args.includes('--confirm')) throw new Error('重置会撤销所有手机，请使用 reset-pairing --confirm 明确执行。');
    await controlRequest(directory, 'resetPairing'); return console.log('电脑配对已重置。项目和任务保留，请重新启动并配对手机。');
  }
  if (['start', 'stop', 'status', 'quit'].includes(command)) {
    const result = await controlRequest(directory, command);
    console.log(JSON.stringify(result, null, 2)); return;
  }
  throw new Error('未知命令。使用 clawmate-codex --help 查看可用命令。');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
