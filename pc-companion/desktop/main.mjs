import { app, BrowserWindow, ipcMain, dialog, shell, clipboard, Menu, Tray, nativeImage } from 'electron';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mkdirSync, symlinkSync, existsSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import { dataDirectory, installLayout } from '../host/paths.mjs';
import { ensureDaemon, quitDaemon } from '../host/daemon-client.mjs';
import { DesktopLifecycle } from './lifecycle.mjs';
import { controlRequest } from '../host/control.mjs';
import { writePrivate } from '../host/settings.mjs';

const directory = dataDirectory();
const layout = installLayout(app.isPackaged ? process.resourcesPath : undefined);
const entry = path.join(path.dirname(fileURLToPath(import.meta.url)), 'ui', 'index.html');
const rendererUrl = pathToFileURL(entry).href;
let window; let tray; let quitting = false; let pairing;
const lifecycle = new DesktopLifecycle({ hasTray: () => !!tray,
  confirm: options => window && !window.isDestroyed() ? dialog.showMessageBox(window, options) : dialog.showMessageBox(options),
  hide: () => window?.hide(), show: showWindow,
  shutdown: () => quitDaemon(directory, layout), quit: () => { quitting = true; app.quit(); },
  report: error => dialog.showMessageBox(window, { type: 'error', title: '未能关闭后台服务', message: error.message }) });
const allowed = new Set(['status', 'configure', 'login', 'cancelLogin', 'logout', 'start', 'stop', 'pair', 'revoke', 'interrupt']);
function trusted(event) {
  if (lifecycle.closing) throw new Error('应用正在关闭，正在停止后台服务。');
  if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || event.senderFrame.url !== rendererUrl) {
    throw new Error('本机界面校验失败。');
  }
}
function safeAuthUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || !['auth.openai.com', 'auth0.openai.com', 'chatgpt.com'].includes(url.hostname)) {
    throw new Error('登录地址不在官方允许列表中。');
  }
  return url.href;
}
function showWindow() { if (window) { window.show(); window.focus(); } }
async function createWindow() {
  window = new BrowserWindow({ width: 1120, height: 800, minWidth: 900, minHeight: 650,
    title: 'ClawMate Codex', backgroundColor: '#f5f6fb', autoHideMenuBar: true,
    webPreferences: { preload: path.join(path.dirname(fileURLToPath(import.meta.url)), 'preload.cjs'),
      sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true, safeDialogs: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  window.on('close', event => { if (!quitting) { event.preventDefault(); void lifecycle.requestClose(); } });
  await window.loadFile(entry);
  const iconFile = path.join(layout.base, 'icon.png');
  const image = nativeImage.createFromPath(iconFile);
  if (!image.isEmpty()) {
    tray = new Tray(image.resize({ width: 22, height: 22 }));
    tray.setToolTip('ClawMate Codex');
    tray.setContextMenu(Menu.buildFromTemplate([{ label: '打开 ClawMate Codex', click: showWindow },
      { label: '关闭应用', click: () => { void lifecycle.requestClose(false); } }]));
    tray.on('double-click', showWindow);
  }
}
function installTerminal() {
  if (process.platform === 'win32') {
    const folder = path.dirname(layout.launcher).replace(/'/g, "''");
    const script = `$p=[Environment]::GetEnvironmentVariable('Path','User'); $v='${folder}'; if (($p -split ';') -notcontains $v) { [Environment]::SetEnvironmentVariable('Path',($p.TrimEnd(';')+';'+$v),'User') }`;
    execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true, timeout: 15000 });
    return '终端命令已加入当前用户 PATH，请重新打开终端后运行 clawmate-codex --help。';
  }
  const folder = path.join(os.homedir(), '.local', 'bin'); mkdirSync(folder, { recursive: true });
  const target = path.join(folder, 'clawmate-codex');
  if (existsSync(target)) {
    if (realpathSync(target) !== realpathSync(layout.launcher)) throw new Error('已有同名终端命令，程序没有覆盖它。');
  } else symlinkSync(layout.launcher, target);
  return `已安装 ${target}。若当前 shell 未包含 ~/.local/bin，可直接运行此路径，无需安装 Node.js。`;
}

ipcMain.handle('companion:call', async (event, method, body) => {
  trusted(event);
  if (!allowed.has(method)) throw new Error('不支持的操作。');
  await ensureDaemon(directory, layout);
  if (lifecycle.closing) throw new Error('应用正在关闭，正在停止后台服务。');
  const result = await controlRequest(directory, method, body);
  if (method === 'pair') pairing = result;
  if (method === 'login') {
    const url = result.authUrl || result.verificationUrl;
    if (url) await shell.openExternal(safeAuthUrl(url));
  }
  return result;
});
ipcMain.handle('companion:choose', async (event, kind) => {
  trusted(event);
  if (!['project', 'cert', 'key'].includes(kind)) throw new Error('不支持的文件选择类型。');
  const selected = await dialog.showOpenDialog(window, { title: kind === 'project' ? '选择允许手机访问的项目文件夹' : '选择证书文件',
    properties: kind === 'project' ? ['openDirectory'] : ['openFile'] });
  return selected.canceled ? '' : selected.filePaths[0];
});
ipcMain.handle('companion:export', async event => {
  trusted(event);
  if (!pairing || Date.now() >= pairing.expiresAt) throw new Error('配对信息已过期，请重新生成。');
  const selected = await dialog.showSaveDialog(window, { title: '导出一次性手机配对文件',
    defaultPath: 'phone.clawmate-codex-pair.json', filters: [{ name: 'ClawMate 手机配对', extensions: ['json'] }] });
  if (selected.canceled) return '';
  writePrivate(selected.filePath, pairing.bundle); return selected.filePath;
});
ipcMain.handle('companion:copyPairing', event => {
  trusted(event);
  if (!pairing || Date.now() >= pairing.expiresAt) throw new Error('配对信息已过期。');
  clipboard.writeText(pairing.encoded); return true;
});
ipcMain.handle('companion:installTerminal', event => { trusted(event); return installTerminal(); });
ipcMain.handle('companion:resetPairing', async event => {
  trusted(event);
  const choice = await dialog.showMessageBox(window, { type: 'warning', title: '重置电脑配对',
    message: '所有手机都需要重新配对。项目和任务记录会保留。', buttons: ['取消', '重置配对'], defaultId: 0, cancelId: 0 });
  if (choice.response !== 1) return false;
  await controlRequest(directory, 'resetPairing'); pairing = null; return true;
});
ipcMain.handle('companion:autoStart', (event, enabled) => {
  trusted(event);
  if (typeof enabled !== 'boolean') throw new Error('设置无效。');
  if (process.platform === 'linux') throw new Error('Linux 请在桌面系统的“启动应用”设置中添加 ClawMate Codex。');
  app.setLoginItemSettings({ openAtLogin: enabled }); return enabled;
});
ipcMain.handle('companion:shutdown', async event => {
  trusted(event);
  return lifecycle.requestClose(false);
});

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', showWindow);
  app.whenReady().then(createWindow).catch(error => { dialog.showErrorBox('ClawMate Codex', error.message); quitting = true; app.quit(); });
  app.on('before-quit', event => { if (!quitting) { event.preventDefault(); void lifecycle.requestClose(false); } });
  app.on('activate', showWindow);
  app.on('window-all-closed', () => { if (!tray) app.quit(); });
}
