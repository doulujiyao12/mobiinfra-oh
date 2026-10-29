// Run with the Electron executable, under a virtual display in CI. No real Codex or account is used.
import { app, BrowserWindow } from 'electron';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { serveControl } from '../host/control.mjs';
import QRCode from 'qrcode';
import { VERSION, installLayout } from '../host/paths.mjs';
import { DatabaseSync } from 'node:sqlite';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-ui-smoke-'));
process.env.CLAWMATE_CODEX_DATA_DIR = dir;
process.env.CLAWMATE_CODEX_RESOURCES = path.join(root, 'out', `${process.platform}-${process.arch}`, 'resources');
mkdirSync(path.join(dir, 'electron'), { recursive: true }); app.setPath('userData', path.join(dir, 'electron'));
process.env.CODEX_HOME = path.join(dir, 'codex-home'); mkdirSync(process.env.CODEX_HOME);
const existingProject = path.join(dir, 'existing-project'); mkdirSync(existingProject);
writeFileSync(path.join(process.env.CODEX_HOME, '.codex-global-state.json'), JSON.stringify({
  'local-projects': { demo: { name: '已有 Codex 项目', rootPaths: [existingProject] } } }));
const recentProject = path.join(dir, 'recent-cli-project'); mkdirSync(recentProject);
const projectDatabase = new DatabaseSync(path.join(process.env.CODEX_HOME, 'state_5.sqlite'));
projectDatabase.exec('CREATE TABLE threads(cwd TEXT, source TEXT, updated_at INTEGER)');
projectDatabase.prepare('INSERT INTO threads VALUES(?,?,?)').run(recentProject, 'cli', 100);
projectDatabase.close();
const status = { version: VERSION, state: 'stopped', account: { type: 'chatgpt', email: 'demo@example.invalid', planType: 'plus' },
  config: { name: '我的开发电脑', host: '0.0.0.0', port: 8787, networkMode: 'lan', publicOrigin: '', certFile: '', keyFile: '',
    workspaces: [{ id: 'project', name: '鸿蒙项目', path: '/projects/harmony-app' }] },
  origins: ['https://192.168.1.20:8787'], devices: [], tasks: [], fingerprint: 'DEMO · ONLY USED IN UI TEST', dataDirectory: '/private/app-data', launcher: installLayout().launcher };
const manager = { layout: installLayout(), settings: { directory: dir }, async dispatch(method, body) {
  if (method === 'status') return status;
  if (method === 'configure') { status.config = body; return status; }
  if (method === 'start') { status.state = 'running'; return status; }
  if (method === 'pair') return { bundle: {}, encoded: 'TEST-PAIRING-ONLY', expiresAt: Date.now() + 300000, qr: await QRCode.toDataURL('UI TEST ONLY') };
  throw new Error('Unsupported test operation: ' + method);
} };
const close = await serveControl(manager, () => {});
const timeout = setTimeout(() => { console.error('UI test timed out'); app.exit(1); }, 30000);
async function waitFor(fn) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) { if (await fn()) return; await new Promise(resolve => setTimeout(resolve, 100)); }
  throw new Error('UI condition was not reached');
}
// Finish evaluating the ESM entry before awaiting Electron's ready event.
setImmediate(async () => { try {
  await import(process.env.CLAWMATE_UI_MAIN || '../desktop/main.mjs'); await app.whenReady();
  let win;
  await waitFor(() => { win = BrowserWindow.getAllWindows()[0]; return !!win; });
  const errors = [];
  win.webContents.on('console-message', details => { if (details.level === 'error') errors.push(details.message); });
  await waitFor(() => win.webContents.executeJavaScript("document.getElementById('accountBadge')?.textContent === '已登录'"));
  assert.equal(await win.webContents.executeJavaScript("document.getElementById('projects').textContent.includes('鸿蒙项目')"), true);
  await win.webContents.executeJavaScript("document.getElementById('addProject').click()");
  await waitFor(() => win.webContents.executeJavaScript("document.querySelector('.project-option')?.textContent.includes('已有 Codex 项目')"));
  assert.equal(await win.webContents.executeJavaScript("document.querySelectorAll('.project-option').length"), 2);
  assert.equal(await win.webContents.executeJavaScript("document.getElementById('projectPicker').open"), true);
  if (process.env.CLAWMATE_UI_PICKER_SCREENSHOT) writeFileSync(process.env.CLAWMATE_UI_PICKER_SCREENSHOT, (await win.webContents.capturePage()).toPNG());
  await win.webContents.executeJavaScript("document.getElementById('projectSearch').value='no-match'; document.getElementById('projectSearch').dispatchEvent(new Event('input'))");
  assert.equal(await win.webContents.executeJavaScript("document.querySelectorAll('.project-option').length"), 0);
  await win.webContents.executeJavaScript("document.getElementById('projectSearch').value=''; document.getElementById('projectSearch').dispatchEvent(new Event('input')); document.querySelector('.project-option').click()");
  assert.equal(await win.webContents.executeJavaScript("document.getElementById('projectPicker').open"), false);
  assert.equal(status.config.workspaces.length, 1, 'Discovery/selection alone must not save an authorization');
  assert.equal(await win.webContents.executeJavaScript("document.getElementById('projects').textContent.includes('已有 Codex 项目')"), true);
  await win.webContents.executeJavaScript("document.getElementById('start').click()");
  await waitFor(() => win.webContents.executeJavaScript("document.getElementById('sideState').textContent.includes('已启动')"));
  await win.webContents.executeJavaScript("document.getElementById('generatePairing').click()");
  await waitFor(() => win.webContents.executeJavaScript("!document.getElementById('pairingResult').hidden"));
  assert.equal(await win.webContents.executeJavaScript("typeof process"), 'undefined');
  assert.equal(await win.webContents.executeJavaScript("typeof require"), 'undefined');
  assert.equal(errors.filter(message => /Content Security Policy|ReferenceError|TypeError/.test(message)).length, 0);
  if (process.env.CLAWMATE_UI_SCREENSHOT) writeFileSync(process.env.CLAWMATE_UI_SCREENSHOT, (await win.webContents.capturePage()).toPNG());
  win.destroy(); await close(); clearTimeout(timeout);
  console.log('PASS: real Electron UI, isolated preload IPC, project discovery/search/selection, explicit save, service start, pairing and CSP.');
  if (process.env.CLAWMATE_UI_RESULT) writeFileSync(process.env.CLAWMATE_UI_RESULT, JSON.stringify({ passed: true, errors }));
  try { rmSync(dir, { recursive: true, force: true }); }
  catch (error) {
    // Chromium may hold its temporary profile until the process has exited.
    if (process.platform !== 'win32' || !['EPERM', 'EBUSY'].includes(error.code)) throw error;
    console.warn('Temporary UI test profile can be removed after Electron exits.');
  }
  app.exit(0);
} catch (error) { console.error(error); clearTimeout(timeout); await close(); app.exit(1); } });
