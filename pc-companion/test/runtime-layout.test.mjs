import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { desktopLayout } from '../desktop/runtime-layout.mjs';
import { installLayout } from '../host/paths.mjs';

test('installed portable Mac layout uses bundle Resources even when Electron reports isPackaged=false', () => {
  const resourcesPath = path.join(os.tmpdir(), 'ClawMate Codex.app', 'Contents', 'Resources');
  for (const name of ['app', 'app.asar']) {
    const layout = desktopLayout({ resourcesPath, appPath: path.join(resourcesPath, name), isPackaged: false });
    assert.equal(layout.base, resourcesPath); assert.equal(layout.node, installLayout(resourcesPath).node);
  }
});
test('native packaged and development runs select their respective resource roots', () => {
  const resourcesPath = path.join(os.tmpdir(), 'installed', 'resources');
  assert.equal(desktopLayout({ resourcesPath, appPath: '/ignored', isPackaged: true }).base, resourcesPath);
  assert.equal(desktopLayout({ resourcesPath, appPath: path.join(os.tmpdir(), 'source'), isPackaged: false }).base, installLayout().base);
  if (!process.env.CLAWMATE_CODEX_RESOURCES) assert.ok(installLayout().base.endsWith(path.join('out', `${process.platform}-${process.arch}`, 'resources')));
});
