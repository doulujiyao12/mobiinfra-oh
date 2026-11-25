import path from 'node:path';
import { execFile, fork, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { DesktopIpc } from '../../bridge/codex/desktop-ipc.mjs';
import { DaemonRpc } from '../../bridge/codex/daemon-rpc.mjs';
import { validatedDaemonSocket } from '../../bridge/codex/daemon-discovery.mjs';
import { desktopLaunchArgs, sharedDesktopState } from '../host/shared-desktop.mjs';

const exec = promisify(execFile);
// Resolve the registered GUI, then correlate its own local app-server child tree.
// Get-Process alone also sees CLI sessions, renderer processes and other desktops.
const inspectScript = String.raw`
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$pkg = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (!$pkg) { '{}' ; exit }
$apps = (Get-AppxPackageManifest $pkg).Package.Applications.Application
$entry = @($apps | Where-Object { [IO.Path]::GetFileName($_.Executable) -match '^(ChatGPT|Codex)\.exe$' })
if ($entry.Count -ne 1) { '{}' ; exit }
$exe = [IO.Path]::GetFullPath([IO.Path]::Combine($pkg.InstallLocation,$entry[0].Executable))
$cli = [IO.Path]::Combine([IO.Path]::GetDirectoryName($exe),'resources','codex.exe')
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$all = @(Get-CimInstance Win32_Process -Filter "SessionId=$session" | Where-Object {
  $_.ExecutablePath -eq $exe -or $_.ExecutablePath -eq $cli
})
$roots = @($all | Where-Object { $_.ExecutablePath -eq $exe -and $_.CommandLine -and $_.CommandLine -notmatch '\s--type=' -and
  $_.ParentProcessId -notin @($all.ProcessId) })
$result = @{ executable=$exe; cli=$cli; count=$roots.Count; stdio=$false; visible=$false }
if ($roots.Count -eq 1) {
  $root=$roots[0]; $p=Get-Process -Id $root.ProcessId -ErrorAction Stop
  $owner=Invoke-CimMethod -InputObject $root -MethodName GetOwnerSid
  if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
    $result.count=-1; $result | ConvertTo-Json -Compress; exit
  }
  $result.pid=$p.Id; $result.created=$p.StartTime.ToUniversalTime().Ticks.ToString()
  $result.visible=$p.MainWindowHandle -ne 0
  $result.custom=$root.CommandLine -match '\s--(user-data-dir|profile-directory|remote-debugging-port)(=|\s)'
  foreach($c in $all) {
    if ($c.ExecutablePath -ne $cli -or $c.CommandLine -notmatch '\sapp-server(\s|$)' -or
        $c.CommandLine -match 'app-server\s+(daemon|proxy)|--listen[= ]+(unix|ws|off)') {continue}
    $ancestor=$c.ParentProcessId
    for ($i=0;$i -lt 10 -and $ancestor;$i++) {
      if ($ancestor -eq $p.Id) {$result.stdio=$true;break}
      $parent=$all | Where-Object ProcessId -eq $ancestor | Select-Object -First 1
      $ancestor=$parent.ParentProcessId
    }
  }
}
$result | ConvertTo-Json -Compress
`;

async function powershell(script, extra = {}, timeout = 12000) {
  const system = path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0');
  const env = { ...process.env, ...extra, PSModulePath: path.join(system, 'Modules') };
  const { stdout } = await exec(path.join(system, 'powershell.exe'), ['-NoProfile','-NonInteractive','-EncodedCommand',
    Buffer.from(script,'utf16le').toString('base64')], { env, windowsHide: true, timeout });
  return stdout.trim();
}
export const inspectWindowsDesktop = async () => JSON.parse(await powershell(inspectScript));

export function classifyDesktop(info, active, legacy) {
  if (!info.executable) return { state:'unsupported', text:'未找到可自动重启的 Windows 版 Codex 桌面。' };
  if (info.count === 0) return { state:'off', text:'桌面未运行。可以直接以共享方式打开。' };
  if (info.count === 1 && info.pid && info.pid === active?.pid) return { state:'shared', text:'桌面已接入共享后台。请在手机打开同一项目的原会话。' };
  if (info.count !== 1 || info.custom) return { state:'unknown', text:'检测到多个实例或自定义启动参数，请保留当前启动方式。' };
  if (legacy) return { state:'available', text:'检测到桌面共享通道。请在手机打开原会话。' };
  if (info.stdio && info.visible) return { state:'private', text:'当前桌面使用独立连接，手机无法实时接入这里打开的会话。' };
  return { state:'unknown', text:'暂时无法确认桌面连接方式。请打开 Codex 主窗口后重新检查。' };
}

export async function probeSharing(directory) {
  if (process.platform !== 'win32') return { state:'notApplicable', text:'自动重启适用于 Windows 桌面。' };
  const info = await inspectWindowsDesktop();
  let active = sharedDesktopState(directory);
  if (active?.pid === info.pid && active) {
    const socket = await validatedDaemonSocket(active.socket);
    if (socket) {
      const check = new DaemonRpc(socket, { proxy:{ command:info.cli, environment:process.env } });
      try { await check.initialize(); } catch { active = null; } finally { check.close(); }
    } else active = null;
  }
  let legacy = false;
  if (info.pid && info.stdio) {
    const ipc = new DesktopIpc();
    try { await ipc.connect(); legacy = true; } catch {} finally { ipc.close(); }
  }
  return { ...classifyDesktop(info, active, legacy), info };
}

async function closeWindow(info) {
  const script = await readFile(new URL('./quit-codex.ps1', import.meta.url), 'utf8');
  let result;
  try {
    result = await powershell(script, {CM_DESKTOP_PID:String(info.pid), CM_DESKTOP_CREATED:info.created,
      CM_DESKTOP_EXE:info.executable}, 60000);
  } catch { result = 'unavailable'; }
  if (result !== 'closed') throw new Error('Codex 尚未正常退出。请保存工作，通过桌面菜单退出后，再点击「以共享方式打开」。');
}

function next(worker, kind, timeout) {
  return new Promise((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); worker.off('message', message); worker.off('exit', ended); worker.off('error', ended); };
    const ended = () => { cleanup(); reject(new Error('共享启动进程提前退出。')); };
    const message = value => {
      if (value.kind === kind || value.kind === 'error') {
        cleanup(); if (value.kind === 'error') reject(new Error(value.message)); else resolve();
      }
    };
    const timer = setTimeout(() => { cleanup(); reject(new Error('尚未确认桌面接入共享后台。请查看桌面窗口后重新检查；如需恢复，可正常退出并从原快捷方式打开。')); }, timeout);
    worker.on('message', message); worker.once('exit', ended); worker.once('error', ended);
  });
}

export async function supportsSharedUrl(filename, openStream) {
  const needle = Buffer.from('CODEX_APP_SERVER_WS_URL');
  let tail = Buffer.alloc(0);
  for await (const chunk of openStream(filename)) {
    const data = Buffer.concat([tail,chunk]);
    if (data.includes(needle)) return true;
    tail = data.subarray(Math.max(0,data.length - needle.length + 1));
  }
  return false;
}

export async function switchDesktop({ directory, layout, consent, idle, openStream, probe = probeSharing,
  close = closeWindow, inspect = inspectWindowsDesktop, startWorker = fork, restore = spawn }) {
  const before = await probe(directory);
  if (!['private','off'].includes(before.state)) return before.text;
  const info = before.info;
  if (!await supportsSharedUrl(path.join(path.dirname(info.executable),'resources','app.asar'), openStream)) {
    throw new Error('此桌面版本未找到共享启动入口，请更新桌面后重试。');
  }
  if (!await consent(before.state)) return '已取消。';
  await idle();
  const worker = startWorker(layout.cli, ['desktop-share-worker',info.cli], { execPath:layout.node, execArgv:[],
    env:{...process.env,CLAWMATE_CODEX_DATA_DIR:directory}, detached:true, windowsHide:true, stdio:['ignore','ignore','ignore','ipc'] });
  let wasClosed = false;
  try {
    await next(worker,'ready',18000);
    const current = await probe(directory);
    if (current.state !== before.state || current.info?.executable !== info.executable ||
      current.info?.pid !== info.pid || current.info?.created !== info.created) throw new Error('桌面状态已变化，请重新检查。');
    await idle();
    if (before.state === 'private') { await close(info); wasClosed = true; }
    const remaining = await inspect();
    if (remaining.count !== 0 || remaining.executable !== info.executable) throw new Error('桌面实例或安装位置已变化，请重新检查。');
    const started = next(worker,'launched',10000);
    worker.send({ executable:info.executable }); await started;
    await next(worker,'connected',45000);
    return '桌面已接入共享后台。在电脑打开原会话后，即可从手机继续。';
  } catch (error) {
    if (wasClosed) {
      const current = await inspect();
      if (current.count === 0 && current.executable === info.executable) {
        const child = restore(info.executable, desktopLaunchArgs(), { detached:true, stdio:'ignore' });
        await new Promise((resolve,reject) => { child.once('spawn',resolve); child.once('error',reject); });
        child.unref();
        throw new Error(error.message + ' 已按原方式重新打开 Codex。');
      }
    }
    throw error;
  } finally {
    if (worker.connected) worker.disconnect();
    worker.unref();
  }
}
