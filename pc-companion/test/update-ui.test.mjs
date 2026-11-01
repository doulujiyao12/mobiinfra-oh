import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

test('update UI covers discovery, progress, ready/manual install, errors and settings without rendering release HTML', async () => {
  const html = readFileSync(new URL('../desktop/ui/index.html', import.meta.url), 'utf8');
  const source = readFileSync(new URL('../desktop/ui/renderer.js', import.meta.url), 'utf8');
  const nodes = new Map([...html.matchAll(/id="([^"]+)"/g)].map(match => [match[1], {
    hidden: true, handlers: {}, classList: { toggle() {} }, addEventListener(name, fn) { this.handlers[name] = fn; }
  }]));
  let render;
  const initial = { phase: 'idle', currentVersion: '1.1.13', autoCheck: true, channel: 'stable', progress: 0, downloadedBytes: 0, totalBytes: 0,
    platform: 'win32', canInstall: true, hasUpdate: false, latestVersion: '', notes: '', error: '' };
  const context = { document: { getElementById: id => { assert.ok(nodes.has(id), id); return nodes.get(id); }, querySelectorAll: () => [] },
    window: { companion: { call: () => new Promise(() => {}), onUpdate: callback => { render = callback; }, updates: async () => initial } },
    setInterval() {}, console };
  vm.runInNewContext(source, context); await Promise.resolve();
  assert.equal(nodes.get('updateBanner').hidden, true);
  render({ ...initial, phase: 'available', hasUpdate: true, latestVersion: '1.1.14', notes: '<img src=x onerror=alert(1)>', totalBytes: 100 });
  assert.equal(nodes.get('updateBanner').hidden, false); assert.equal(nodes.get('downloadUpdate').hidden, false);
  assert.equal(nodes.get('updateNotes').textContent, '<img src=x onerror=alert(1)>'); assert.equal(nodes.get('updateNotes').innerHTML, undefined);
  render({ ...initial, phase: 'downloading', hasUpdate: true, latestVersion: '1.1.14', totalBytes: 100, downloadedBytes: 50, progress: 50 });
  assert.equal(nodes.get('updateProgress').value, 50); assert.equal(nodes.get('pauseUpdate').hidden, false); assert.equal(nodes.get('checkUpdate').disabled, true);
  render({ ...initial, phase: 'ready', hasUpdate: true }); assert.equal(nodes.get('installUpdate').hidden, false);
  render({ ...initial, phase: 'ready', hasUpdate: true, platform: 'darwin', canInstall: false });
  assert.equal(nodes.get('installUpdate').hidden, true); assert.equal(nodes.get('openUpdate').hidden, false); assert.match(nodes.get('updateManual').textContent, /未签名/);
  render({ ...initial, phase: 'error', error: 'Network failed' }); assert.equal(nodes.get('updateError').hidden, false);
});
