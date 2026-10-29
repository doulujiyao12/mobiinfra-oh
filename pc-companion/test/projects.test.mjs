import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import os from 'node:os';
import { discoverCodexProjects } from '../host/projects.mjs';

function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'clawmate-projects-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'home'); const codexHome = path.join(home, '.codex');
  mkdirSync(codexHome, { recursive: true });
  const folder = name => { const p = path.join(home, name); mkdirSync(p, { recursive: true }); return p; };
  const stateFile = path.join(codexHome, '.codex-global-state.json');
  const state = value => writeFileSync(stateFile, JSON.stringify(value));
  return { root, home, codexHome, folder, state, stateFile,
    discover: options => discoverCodexProjects({ home, env: {}, ...options }) };
}

test('current and legacy saved projects merge with recent cwd metadata without modifying state or authorizing access', async t => {
  const f = fixture(t); const app = f.folder('app'); const legacy = f.folder('legacy'); const cli = f.folder('cli');
  f.state({ 'local-projects': { id: { name: '我的 App', rootPaths: [app], updatedAt: 200 } },
    'electron-saved-workspace-roots': [legacy, app], 'electron-workspace-root-labels': { [legacy]: '旧版项目' },
    'thread-workspace-root-hints': { a: app } });
  const before = readFileSync(f.stateFile);
  const database = new DatabaseSync(path.join(f.codexHome, 'state_5.sqlite'));
  database.exec('CREATE TABLE threads(cwd TEXT, source TEXT, updated_at INTEGER)');
  const insert = database.prepare('INSERT INTO threads VALUES(?,?,?)');
  insert.run(cli, 'cli', 400); insert.run(app, 'vscode', 500); insert.run(cli, 'cli', 300);
  insert.run(f.folder('subagent-only'), 'subagent', 600); database.close();
  const result = await f.discover();
  assert.deepEqual(result.projects.map(p => p.name), ['我的 App', '旧版项目', 'cli']);
  assert.equal(result.projects[0].updatedAt, 500000); assert.deepEqual(result.warnings, []);
  assert.deepEqual(readFileSync(f.stateFile), before);
  assert.equal(result.projects.some(p => 'id' in p || 'authorized' in p), false);
});

test('custom CODEX_HOME, stale paths, invalid input and credential-containing roots are handled safely', async t => {
  const f = fixture(t); const other = f.folder('alternate');
  const app = f.folder('works'); const config = f.folder('connector-settings');
  writeFileSync(path.join(other, '.codex-global-state.json'), JSON.stringify({ 'active-workspace-roots':
    [f.home, f.root, other, config, 'relative', null, '/missing/clawmate-test', app] }));
  const result = await f.discover({ env: { CODEX_HOME: other }, excludeDirectory: config });
  assert.deepEqual(result.projects.map(p => p.path), [app]); assert.deepEqual(result.warnings, []);
  assert.ok(result.skipped >= 5);
});

test('missing Codex and malformed metadata keep folder browsing available', async t => {
  const f = fixture(t); let result = await f.discover();
  assert.deepEqual(result.projects, []); assert.deepEqual(result.warnings, []);
  writeFileSync(f.stateFile, '{');
  writeFileSync(path.join(f.codexHome, 'state_5.sqlite'), 'not a database');
  result = await f.discover(); assert.deepEqual(result.projects, []); assert.equal(result.warnings.length, 2);
});

test('discovery bounds UI results and preserves long names safely as text', async t => {
  const f = fixture(t); const roots = Array.from({ length: 205 }, (_, i) => f.folder('project-' + i));
  f.state({ 'local-projects': { id: { name: '<img onerror=bad()>'.repeat(10), rootPaths: roots.slice(0, 20) } },
    'electron-saved-workspace-roots': roots });
  const result = await f.discover(); assert.equal(result.projects.length, 200); assert.equal(result.truncated, true);
  assert.equal(result.projects[0].name.length, 80);
});
