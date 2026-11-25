import { execFile } from 'node:child_process';
import { accessSync, constants, lstatSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { DaemonRpc } from '../../bridge/codex/daemon-rpc.mjs';
import { discoverDaemons } from '../../bridge/codex/daemon-discovery.mjs';
import { MAC_CODEX_BUNDLE_ID, macCodexDesktopBundles } from '../host/codex-runtime.mjs';

const run = promisify(execFile);
const quitScript = 'ObjC.import("AppKit"); function run(args) { var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[0])); if (!app.terminate) throw Error("Quit request rejected"); }';
const reply = (state, message, canStart = false) => ({ state, message, canStart });
const desktopHome = () => path.resolve(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'));

function canonical(filename) {
  try { return realpathSync(filename); } catch { return path.resolve(filename); }
}

async function desktopBundles(preferredExecutable, rows) {
  const runningBundles = rows.flatMap(row => {
    const match = row.executable.match(/^(.*\.app)\/Contents\/MacOS\/[^/]+$/i);
    return match && /^(ChatGPT|Codex)$/i.test(path.basename(row.executable)) ? [match[1]] : [];
  });
  const indexedBundles = await run('/usr/bin/mdfind', ['-0', `kMDItemCFBundleIdentifier == "${MAC_CODEX_BUNDLE_ID}"`], { timeout: 1500 })
    .then(({ stdout }) => stdout.split('\0').filter(filename => path.isAbsolute(filename) && /\.app$/i.test(filename)))
    .catch(() => []);
  const result = [];
  for (const candidate of macCodexDesktopBundles(preferredExecutable, runningBundles, indexedBundles)) {
    const plist = path.join(candidate.bundle, 'Contents', 'Info.plist');
    try {
      const read = key => run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plist], { timeout: 2000 })
        .then(({ stdout }) => stdout.trim());
      const [identifier, executable] = await Promise.all([read('CFBundleIdentifier'), read('CFBundleExecutable')]);
      if (identifier !== MAC_CODEX_BUNDLE_ID || !executable || executable !== path.basename(executable)) continue;
      const main = realpathSync(path.join(candidate.bundle, 'Contents', 'MacOS', executable));
      const contents = canonical(candidate.bundle) + '/Contents/';
      if (!main.startsWith(contents + 'MacOS/') || !candidate.executable.startsWith(contents + 'Resources/') ||
        result.some(bundle => bundle.main === main)) continue;
      result.push({ ...candidate, main });
    } catch { /* An application can move or be replaced while discovering it. */ }
  }
  return result;
}

async function processes() {
  const { stdout } = await run('/bin/ps', ['-ax', '-o', 'pid=,ppid=,uid=,comm='], { timeout: 2500 });
  return stdout.split('\n').flatMap(line => {
    const row = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    return row && Number(row[3]) === process.getuid() ?
      [{ pid: Number(row[1]), parent: Number(row[2]), executable: row[4].trim() }] : [];
  });
}

function matchesDesktop(row, desktop) {
  return row.executable === desktop.main ||
    (row.executable.endsWith('/' + path.basename(desktop.main)) && canonical(row.executable) === desktop.main);
}

function descendants(rows, parent) {
  const ids = new Set([parent]);
  for (let previous = 0; previous < ids.size;) {
    previous = ids.size;
    for (const row of rows) if (ids.has(row.parent)) ids.add(row.pid);
  }
  return [...ids].filter(id => id !== parent);
}

function socketExists(home) {
  try { lstatSync(path.join(home, 'app-server-control', 'app-server-control.sock')); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

async function socketUnderDesktop(socket, rows, pid, executable) {
  const children = descendants(rows, pid).filter(id => rows.some(row => row.pid === id && row.executable === executable));
  if (!children.length) return false;
  try {
    const { stdout } = await run('/usr/sbin/lsof', ['-n', '-a', '-U', '-p', children.join(','), '-Fn'], { timeout: 2200 });
    return stdout.split('\n').includes('n' + socket);
  } catch { return false; }
}

async function querySharing(socket, threadId) {
  const rpc = new DaemonRpc(socket, { timeout: 2200 });
  try {
    await rpc.initialize();
    let cursor;
    for (let index = 0; index < 20; index += 1) {
      const page = await rpc.request('thread/loaded/list', { limit: 100, cursor });
      if (!threadId || page.data.includes(threadId)) return true;
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    return false;
  } finally { rpc.close(); }
}

async function checkProfile(pid, home) {
  // ps exposes the desktop's explicit override, including ordinary spaces in its path.
  // No other environment values should be logged, returned, or reused.
  const { stdout } = await run('/bin/ps', ['eww', '-p', String(pid), '-o', 'command='], { timeout: 2500 })
    .catch(() => { throw new Error('无法确认当前 ChatGPT 的 Codex 数据目录，请重新检查桌面状态。'); });
  if (!stdout.trim()) throw new Error('ChatGPT 已退出，请重新检查共享状态。');
  const overrides = [...stdout.matchAll(/(?:^|\s)CODEX_HOME=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|\n|$)/g)];
  const current = overrides[0]?.[1] || path.join(os.homedir(), '.codex');
  if (overrides.length > 1 || !path.isAbsolute(current) || canonical(current) !== canonical(home)) {
    throw new Error('ChatGPT 和 ClawMate 使用了不同的 Codex 数据目录。请先用同一数据目录打开两者，再启用共享。');
  }
}

export class MacDesktopSharing {
  constructor(layout) {
    this.layout = layout;
    this.adapter = path.join(layout.base, 'bin', 'codex-shared-desktop');
  }

  async inspect({ executable: preferredExecutable, home = desktopHome() } = {}, rescan = false) {
    const rows = await processes();
    if (rescan || this.preferredExecutable !== preferredExecutable || !(this.validUntil > Date.now())) {
      this.bundles = await desktopBundles(preferredExecutable, rows);
      this.preferredExecutable = preferredExecutable;
      this.validUntil = Date.now() + 30000;
    }
    const running = this.bundles.flatMap(bundle => rows.filter(row => matchesDesktop(row, bundle))
      .map(row => ({ ...bundle, pid: row.pid })));
    if (running.length > 1) return { status: reply('unavailable', '检测到多个 ChatGPT 桌面实例。请保留要共享的那个实例后再试。') };
    const desktop = running[0] || this.bundles[0];
    if (!desktop) return { status: reply('unavailable', '未找到可用于会话共享的 ChatGPT 桌面版。') };

    const [socket] = await discoverDaemons({ CODEX_HOME: home });
    if (desktop.pid && socket && await socketUnderDesktop(socket, rows, desktop.pid, desktop.executable)) {
      try {
        if (await querySharing(socket)) return { desktop, home, socket, status: reply('ready', '共享后台已就绪。在 ChatGPT 打开目标会话后，可从手机的「电脑会话」进入同一条。') };
      } catch { /* A socket alone does not establish a live App Server session. */ }
    }
    if (socketExists(home)) {
      return { status: reply('unavailable', '检测到已有 Codex 控制 socket，但未能确认当前 ChatGPT 使用这个后台。请检查现有后台后再试。') };
    }
    try {
      accessSync(this.adapter, constants.X_OK);
      accessSync(this.layout.node, constants.X_OK);
      accessSync(path.join(this.layout.base, 'host', 'macos-shared-launch.mjs'), constants.R_OK);
    }
    catch { return { status: reply('unavailable', '当前 ClawMate 安装缺少 macOS 共享启动组件。') }; }
    return { desktop, home, status: desktop.pid ?
      reply('restart', 'ChatGPT 尚未以共享模式运行。重启后，ClawMate 可以接入已授权项目的电脑会话。', true) :
      reply('start', '从 ClawMate 打开 ChatGPT，可为桌面会话启用共享。', true) };
  }

  async status(profile) {
    if (this.progress) return this.progress;
    try { return (await this.inspect(profile)).status; }
    catch { return reply('unavailable', '暂时无法读取 ChatGPT 的共享状态。'); }
  }

  async restart(profile, threadId, confirm) {
    if (this.progress) throw new Error('正在切换 ChatGPT 共享模式，请稍候。');
    this.progress = reply('starting', '正在检查共享启动条件…');
    try {
      const { desktop, home, status } = await this.inspect(profile, true);
      if (status.state === 'ready') return status;
      if (!status.canStart) throw new Error(status.message);
      if (desktop.pid) await checkProfile(desktop.pid, home);
      const [help, launchHelp] = await Promise.all([
        run(desktop.executable, ['app-server', '--help'], { timeout: 6000 }).then(({ stdout }) => stdout),
        run('/usr/bin/open', ['--help'], { timeout: 2500 }).catch(error => error)
          .then(({ stdout, stderr }) => (stdout || '') + (stderr || ''))
      ]);
      if (!help.includes('--listen') || !help.includes('unix://')) throw new Error('当前安装的 Codex 不支持 App Server 本地监听。');
      if (!launchHelp.includes('--env')) throw new Error('当前 macOS 的应用启动命令不支持传入共享启动参数。');
      if (!await confirm(Boolean(desktop.pid))) return status;

      const current = (await processes()).filter(row => matchesDesktop(row, desktop));
      if (current.some(row => row.pid !== desktop.pid)) throw new Error('确认期间 ChatGPT 实例发生变化，请重新检查共享状态。');
      if (desktop.pid) {
        this.progress = reply('starting', '正在等待 ChatGPT 正常退出。如果它没有自动退出，请在 ChatGPT 按 ⌘Q。');
        if (current.length) {
          await run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', quitScript, String(desktop.pid)], { timeout: 6000 }).catch(() => {});
        }
        const deadline = Date.now() + 45000;
        while ((await processes()).some(row => matchesDesktop(row, desktop))) {
          if (Date.now() >= deadline) throw new Error('ChatGPT 尚未退出。请在 ChatGPT 按 ⌘Q 后重试。');
          await delay(500);
        }
      }
      const socketDeadline = Date.now() + 5000;
      while (socketExists(home)) {
        if (Date.now() >= socketDeadline) throw new Error('原 Codex 控制 socket 仍然存在，请等后台退出后重试。');
        await delay(250);
      }
      this.progress = reply('starting', '正在启动 ChatGPT 并检查共享后台…');
      const args = ['--env', 'CODEX_CLI_PATH=' + this.adapter, '--env', 'CODEX_HOME=' + home,
        '--env', 'CLAWMATE_DESKTOP_CODEX_EXECUTABLE=' + desktop.executable, '-a', desktop.bundle];
      if (threadId) args.push('codex://threads/' + threadId);
      await run('/usr/bin/open', args, { timeout: 6000 });
      const deadline = Date.now() + 25000;
      let ready = false;
      do {
        ready = false;
        const rows = await processes();
        const opened = rows.find(row => matchesDesktop(row, desktop));
        const [socket] = await discoverDaemons({ CODEX_HOME: home });
        if (opened && socket && await socketUnderDesktop(socket, rows, opened.pid, desktop.executable)) {
          try {
            const loaded = await querySharing(socket, threadId);
            ready = true;
            if (loaded) {
              return reply('ready', threadId ? '共享后台已加载所选原会话。可从手机进入同一条。' :
                '共享后台已就绪。请在 ChatGPT 打开目标会话，再从手机进入同一条。');
            }
          } catch { /* The desktop may still be loading the backend or original chat. */ }
        }
        await delay(600);
      } while (Date.now() < deadline);
      if (ready) return reply('ready', '共享后台已就绪，所选会话尚未加载。请在 ChatGPT 中打开它。');
      throw new Error('已请求打开 ChatGPT，但未验证到共享后台。请检查桌面启动状态，或正常打开 ChatGPT 后重试。');
    } finally { this.progress = null; }
  }
}
