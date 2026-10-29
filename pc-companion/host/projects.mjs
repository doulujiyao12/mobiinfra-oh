import { open, readdir, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const sourceOrder = ['Codex 项目', 'Codex 工作目录', '最近会话'];
const contains = (parent, child) => {
  const relative = path.relative(parent, child);
  return !relative || relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
};
async function readState(filename) {
  const file = await open(filename, 'r');
  try {
    const size = (await file.stat()).size;
    if (size > 8 * 1024 * 1024) throw new Error('Codex 项目配置过大，请使用文件夹选择。');
    const buffer = Buffer.alloc(size + 1);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    return JSON.parse(buffer.subarray(0, bytesRead).toString('utf8'));
  } finally { await file.close(); }
}

// Read local project/session metadata only. Never start Codex, read credentials
// or conversations, change Codex state, or grant phone access during discovery.
export async function discoverCodexProjects({ env = process.env, home = os.homedir(), excludeDirectory } = {}) {
  const codexHome = path.resolve(env.CODEX_HOME || path.join(home, '.codex'));
  const candidates = []; const warnings = [];
  const add = (directory, name, source, updatedAt = 0) => {
    if (candidates.length < 5000 && typeof directory === 'string' && directory.length <= 4096 &&
        path.isAbsolute(directory) && !/[\x00-\x1f]/.test(directory)) {
      candidates.push({ path: directory, name: typeof name === 'string' ? name.trim().slice(0, 80) : '', source,
        updatedAt: Number.isFinite(updatedAt) ? updatedAt : 0 });
    }
  };
  try {
    const state = await readState(path.join(codexHome, '.codex-global-state.json'));
    // Current desktop schema and earlier releases' saved workspace schema.
    for (const project of Object.values(state['local-projects'] || {}).slice(0, 500)) {
      if (project && Array.isArray(project.rootPaths)) for (const root of project.rootPaths.slice(0, 20)) {
        add(root, project.name, sourceOrder[0], project.updatedAt);
      }
    }
    const labels = state['electron-workspace-root-labels'] || {};
    for (const key of ['electron-saved-workspace-roots', 'active-workspace-roots']) {
      if (Array.isArray(state[key])) for (const root of state[key].slice(0, 500)) add(root, labels[root], sourceOrder[1]);
    }
    for (const root of Object.values(state['thread-workspace-root-hints'] || {}).slice(0, 500)) add(root, '', sourceOrder[2]);
  } catch (error) {
    if (error.code !== 'ENOENT') warnings.push('未能读取 Codex 项目配置，可刷新重试或浏览文件夹。');
  }
  try {
    const files = (await readdir(codexHome)).filter(name => /^state_\d+\.sqlite$/.test(name))
      .sort((a, b) => Number(b.match(/\d+/)[0]) - Number(a.match(/\d+/)[0]));
    if (files.length) {
      const { DatabaseSync } = await import('node:sqlite');
      const database = new DatabaseSync(path.join(codexHome, files[0]), { readOnly: true });
      try {
        database.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=100;');
        // Bound the result and query only cwd/recency, never titles or messages.
        const rows = database.prepare("SELECT cwd, updated_at FROM threads WHERE source IN ('cli', 'vscode', 'appServer', 'exec', 'unknown') ORDER BY updated_at DESC LIMIT 2000").all();
        for (const row of rows) add(row.cwd, '', sourceOrder[2], row.updated_at * 1000);
      } finally { database.close(); }
    }
  } catch (error) {
    if (error.code !== 'ENOENT') warnings.push('最近会话目录暂不可读取，已保留可用的 Codex 项目。');
  }
  const blocked = await Promise.all([home, codexHome, excludeDirectory].filter(Boolean).map(async directory => {
    try { return await realpath(directory); } catch { return path.resolve(directory); }
  }));
  const found = new Map(); let skipped = 0;
  // Small batches keep filesystem probes bounded even with large history.
  const unique = new Map();
  for (const candidate of candidates) {
    const normalized = path.normalize(candidate.path);
    const key = process.platform === 'win32' ? normalized.toLowerCase() : normalized;
    const previous = unique.get(key);
    if (!previous) unique.set(key, candidate);
    else {
      previous.updatedAt = Math.max(previous.updatedAt, candidate.updatedAt);
      if (sourceOrder.indexOf(candidate.source) < sourceOrder.indexOf(previous.source)) {
        previous.name = candidate.name; previous.source = candidate.source;
      }
    }
  }
  const probes = [...unique.values()];
  for (let start = 0; start < probes.length; start += 16) {
    const batch = await Promise.all(probes.slice(start, start + 16).map(async candidate => {
      try {
        const directory = await realpath(candidate.path);
        if (!(await stat(directory)).isDirectory() || blocked.some(value => contains(directory, value)) || contains(codexHome, directory)) return null;
        return { ...candidate, path: directory, name: candidate.name || path.basename(directory) };
      } catch { return null; }
    }));
    for (const candidate of batch) {
      if (!candidate) { skipped++; continue; }
      const key = process.platform === 'win32' ? candidate.path.toLowerCase() : candidate.path;
      const old = found.get(key);
      if (!old) found.set(key, candidate);
      else {
        old.updatedAt = Math.max(old.updatedAt, candidate.updatedAt);
        if (sourceOrder.indexOf(candidate.source) < sourceOrder.indexOf(old.source)) {
          old.name = candidate.name; old.source = candidate.source;
        }
      }
    }
  }
  const projects = [...found.values()].sort((a, b) => sourceOrder.indexOf(a.source) - sourceOrder.indexOf(b.source) ||
    b.updatedAt - a.updatedAt || a.name.localeCompare(b.name));
  return { projects: projects.slice(0, 200), truncated: projects.length > 200, warnings, skipped };
}
