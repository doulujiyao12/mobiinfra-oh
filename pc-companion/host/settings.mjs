import { mkdirSync, readFileSync, writeFileSync, renameSync, realpathSync, statSync, chmodSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import path from 'node:path';
import os from 'node:os';

export function writePrivate(filename, value) {
  writeFileSync(filename + '.tmp', typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  renameSync(filename + '.tmp', filename);
  if (process.platform !== 'win32') chmodSync(filename, 0o600);
}
export class Settings {
  constructor(directory) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    this.directory = realpathSync(directory);
    if (process.platform !== 'win32') chmodSync(this.directory, 0o700);
    this.filename = path.join(this.directory, 'config.json');
    try { this.value = JSON.parse(readFileSync(this.filename, 'utf8')); }
    catch (error) {
      if (error.code !== 'ENOENT') throw new Error('本机配置损坏，请从备份恢复，程序没有覆盖原文件。');
      this.value = { version: 1, name: os.hostname(), host: '0.0.0.0', port: 8787,
        token: randomBytes(32).toString('base64url'), workspaces: [],
        networkMode: 'lan', publicOrigin: '', certFile: '', keyFile: '' };
      this.save();
    }
  }
  save() { writePrivate(this.filename, this.value); }
  publicValue() {
    const { name, host, port, workspaces, networkMode, publicOrigin, certFile, keyFile } = this.value;
    return { name, host, port, workspaces, networkMode, publicOrigin, certFile, keyFile };
  }
  update(input) {
    if (typeof input.name !== 'string' || !input.name.trim() || input.name.length > 80) throw new Error('电脑名称需为 1–80 个字符。');
    if (!['0.0.0.0', '127.0.0.1'].includes(input.host)) throw new Error('请选择本机或局域网监听。');
    if (!Number.isInteger(input.port) || input.port < 1024 || input.port > 65535) throw new Error('端口范围为 1024–65535。');
    if (!['lan', 'public'].includes(input.networkMode)) throw new Error('无效的连接模式。');
    if (!Array.isArray(input.workspaces) || input.workspaces.length > 20) throw new Error('最多配置 20 个项目。');
    const workspaces = input.workspaces.map((w, index) => {
      if (typeof w.path !== 'string' || !path.isAbsolute(w.path) || typeof w.name !== 'string' || !w.name.trim() || w.name.length > 80) {
        throw new Error('项目需要名称和完整文件夹路径。');
      }
      const project = realpathSync(w.path);
      if (!statSync(project).isDirectory()) throw new Error('项目路径不是文件夹。');
      const relative = path.relative(project, this.directory);
      if (!relative || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
        throw new Error('请选择具体项目，不要选择包含连接凭据的用户主目录。');
      }
      const previous = this.value.workspaces.find(item => item.path === project);
      return { id: previous?.id || randomUUID(), name: w.name.trim(), path: project };
    });
    if (new Set(workspaces.map(w => w.path)).size !== workspaces.length) throw new Error('项目文件夹不能重复。');
    const value = { ...this.value, name: input.name.trim(), host: input.host, port: input.port, workspaces,
      networkMode: input.networkMode, publicOrigin: '', certFile: '', keyFile: '' };
    if (input.networkMode === 'public') {
      const url = new URL(input.publicOrigin);
      if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) throw new Error('请填写最终 HTTPS 地址，不含路径。');
      if (!path.isAbsolute(input.certFile || '') || !path.isAbsolute(input.keyFile || '')) throw new Error('请选择服务器证书完整链和私钥。');
      for (const filename of [input.certFile, input.keyFile]) {
        if (!statSync(filename).isFile()) throw new Error('证书或私钥文件不可用。');
        const resolved = realpathSync(filename);
        if (workspaces.some(w => { const relative = path.relative(w.path, resolved);
          return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
        })) throw new Error('请把证书和私钥保存在项目目录以外。');
      }
      value.publicOrigin = url.origin; value.certFile = input.certFile; value.keyFile = input.keyFile;
    }
    this.value = value; this.save(); return this.publicValue();
  }
}
