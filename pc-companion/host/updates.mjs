import { EventEmitter } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, mkdirSync, readFileSync, existsSync, statSync, unlinkSync,
  renameSync, openSync, closeSync, writeFileSync, copyFileSync, realpathSync, mkdtempSync, chmodSync, accessSync, constants, lstatSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { Readable, Transform } from 'node:stream';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { VERSION } from './paths.mjs';
import { writePrivate } from './settings.mjs';

export const UPDATE_REPOSITORY = 'doulujiyao12/mobiinfra-oh';
const releasePrefix = 'codex-bridge-v';
const api = `https://api.github.com/repos/${UPDATE_REPOSITORY}/releases`;
const busy = new Set(['starting', 'running', 'waitingApproval', 'stopping', 'releasing', 'unknown']);
const gone = error => ['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code);
const hosts = new Set(['api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com']);
const parseVersion = value => typeof value === 'string' && value.length <= 100 ? /^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})(?:-([a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*))?$/.exec(value) : null;
export function compareVersions(a, b) {
  const left = parseVersion(a); const right = parseVersion(b);
  if (!left || !right) throw new Error('更新版本号格式无效');
  for (let i = 1; i <= 3; i++) if (Number(left[i]) !== Number(right[i])) return Math.sign(Number(left[i]) - Number(right[i]));
  if (left[4] === right[4]) return 0;
  if (!left[4] || !right[4]) return left[4] ? -1 : 1;
  const x = left[4].split('.'); const y = right[4].split('.');
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if (x[i] === y[i]) continue;
    if (x[i] === undefined || y[i] === undefined) return x[i] === undefined ? -1 : 1;
    const nx = /^\d+$/.test(x[i]); const ny = /^\d+$/.test(y[i]);
    if (nx && ny) return BigInt(x[i]) < BigInt(y[i]) ? -1 : BigInt(x[i]) > BigInt(y[i]) ? 1 : 0;
    if (nx !== ny) return nx ? -1 : 1;
    return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}
export function assetNames(version, platform, arch, kind) {
  if (!parseVersion(version) || !['x64', 'arm64'].includes(arch) || !['desktop', 'terminal'].includes(kind)) return [];
  if (kind === 'terminal') return [`ClawMate-Codex-Terminal-${version}-${platform}-${arch}.${platform === 'win32' ? 'zip' : 'tar.gz'}`];
  if (platform === 'win32') return [`ClawMate-Codex-${version}-win-${arch}.exe`];
  if (platform === 'darwin') return [`ClawMate-Codex-${version}-darwin-${arch}-unsigned.zip`, `ClawMate-Codex-${version}-mac-${arch}.zip`];
  if (platform === 'linux') return [`ClawMate-Codex-${version}-linux-${arch}-unsigned.tar.gz`, `ClawMate-Codex-${version}-linux-${arch}.tar.gz`];
  return [];
}
export function safeUpdateUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port || !hosts.has(url.hostname)) throw new Error('更新下载地址不受信任');
  return url;
}
function assetUrl(tag, name) { return `https://github.com/${UPDATE_REPOSITORY}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`; }
export function chooseUpdate(releases, { platform, arch, kind, currentVersion = VERSION, channel = 'stable' }) {
  if (!Array.isArray(releases)) throw new Error('GitHub 更新响应格式无效');
  const choices = [];
  for (const release of releases) {
    if (release.draft || typeof release.tag_name !== 'string' || !release.tag_name.startsWith(releasePrefix)) continue;
    const version = release.tag_name.slice(releasePrefix.length);
    if (!parseVersion(version) || compareVersions(version, currentVersion) <= 0 ||
        channel !== 'preview' && (release.prerelease || parseVersion(version)[4])) continue;
    const names = assetNames(version, platform, arch, kind);
    const assets = Array.isArray(release.assets) ? release.assets : [];
    const asset = names.map(name => assets.find(item => item.name === name)).find(Boolean);
    if (!asset || asset.state !== 'uploaded' || !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size > 1024 ** 3) continue;
    if (asset.browser_download_url !== assetUrl(release.tag_name, asset.name) &&
        asset.browser_download_url !== decodeURI(assetUrl(release.tag_name, asset.name))) continue;
    const sums = assets.find(item => item.name === 'SHA256SUMS.txt' && item.state === 'uploaded');
    choices.push({ version, tag: release.tag_name, name: asset.name, size: asset.size,
      url: assetUrl(release.tag_name, asset.name), sha256: /^sha256:[a-f\d]{64}$/i.test(asset.digest || '') ? asset.digest.slice(7).toLowerCase() : '',
      checksumUrl: sums ? assetUrl(release.tag_name, 'SHA256SUMS.txt') : '',
      releaseUrl: `https://github.com/${UPDATE_REPOSITORY}/releases/tag/${encodeURIComponent(release.tag_name)}`,
      notes: String(release.body || '新版本已发布。').replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').slice(0, 6000), prerelease: !!release.prerelease });
  }
  return choices.sort((a, b) => compareVersions(b.version, a.version))[0] || null;
}
export async function fileSha256(filename) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest('hex');
}
export async function updateResponse(url, { fetcher = fetch, signal, headers = {} } = {}) {
  for (let redirects = 0; redirects < 6; redirects++) {
    safeUpdateUrl(url);
    const response = await fetcher(url, { redirect: 'manual', signal, headers: { 'User-Agent': `ClawMate-Codex/${VERSION}`, ...headers } });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); await response.body?.cancel();
      if (!location) throw new Error('更新下载重定向缺少地址');
      url = new URL(location, url).href; continue;
    }
    return response;
  }
  throw new Error('更新下载重定向次数过多');
}
async function limitedText(response, maximum) {
  if (!response.ok) { await response.body?.cancel(); throw new Error(response.status === 403 || response.status === 429 ? 'GitHub 请求受到限制，请稍后检查更新' : `更新服务返回 HTTP ${response.status}`); }
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length; if (size > maximum) throw new Error('更新元数据过大'); chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}
export function checksumFromText(text, name) {
  const matches = text.split(/\r?\n/).map(line => /^([a-f\d]{64})\s+\*?(.+)$/i.exec(line.trim()))
    .filter(match => match && match[2] === name);
  if (matches.length !== 1) throw new Error('发布的校验清单缺失或重复，请等待维护者补齐');
  return matches[0][1].toLowerCase();
}
function downloadLock(directory) {
  const filename = path.join(directory, 'download.lock'); const nonce = randomUUID();
  try { const file = openSync(filename, 'wx', 0o600); try { writeFileSync(file, JSON.stringify({ pid: process.pid, nonce })); } finally { closeSync(file); } }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let previous;
    try { previous = JSON.parse(readFileSync(filename, 'utf8')); if (!Number.isSafeInteger(previous.pid) || previous.pid < 1) throw new Error(); }
    catch { throw new Error('更新锁不可用，请检查更新目录'); }
    let dead = false;
    try { process.kill(previous.pid, 0); } catch (failure) { dead = failure.code === 'ESRCH'; }
    if (!dead) throw new Error('另一窗口或终端正在下载更新，请稍候');
    unlinkSync(filename); return downloadLock(directory);
  }
  return () => { try { if (JSON.parse(readFileSync(filename, 'utf8')).nonce === nonce) unlinkSync(filename); } catch {} };
}

export class ReleaseUpdater extends EventEmitter {
  candidate = null; controller = null; operation = null;
  constructor(directory, options = {}) {
    super(); this.directory = path.join(directory, 'updates'); mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.options = { platform: process.platform, arch: process.arch, kind: 'terminal', currentVersion: VERSION, ...options };
    this.fetcher = options.fetcher || fetch; this.settingsFile = path.join(this.directory, 'preferences.json');
    this.preferences = { autoCheck: true, channel: 'stable', ignoredVersion: '' };
    let startupError = '';
    try { const saved = JSON.parse(readFileSync(this.settingsFile, 'utf8')); this.preferences = {
      autoCheck: saved.autoCheck !== false, channel: saved.channel === 'preview' ? 'preview' : 'stable',
      ignoredVersion: parseVersion(saved.ignoredVersion) ? saved.ignoredVersion : '' }; } catch (error) { if (error.code !== 'ENOENT') startupError = '更新设置读取失败，已使用默认值；连接功能不受影响'; }
    this.state = { phase: 'idle', currentVersion: this.options.currentVersion, latestVersion: '', notes: '', progress: 0, downloadedBytes: 0,
      totalBytes: 0, error: startupError, checkedAt: 0, hasUpdate: false, platform: this.options.platform, ...this.preferences,
      canInstall: this.options.platform === 'linux' || this.options.platform === 'win32' && this.options.kind === 'desktop' };
    try {
      const ready = JSON.parse(readFileSync(path.join(this.directory, 'ready.json'), 'utf8'));
      const names = assetNames(ready.version, this.options.platform, this.options.arch, this.options.kind);
      if (names.includes(ready.name) && ready.url === assetUrl(releasePrefix + ready.version, ready.name) &&
          /^[a-f\d]{64}$/.test(ready.sha256) && compareVersions(ready.version, this.options.currentVersion) > 0 &&
          (this.preferences.channel === 'preview' || !ready.prerelease && !parseVersion(ready.version)[4]) && existsSync(path.join(this.directory, ready.name))) {
        this.candidate = ready; Object.assign(this.state, { phase: 'ready', hasUpdate: true, latestVersion: ready.version,
          notes: ready.notes, totalBytes: ready.size, downloadedBytes: ready.size, progress: 100 });
      }
    } catch (error) { if (error.code !== 'ENOENT') this.state.error = '上次更新缓存不可用，可重新检查并下载'; }
    try {
      const result = JSON.parse(readFileSync(path.join(this.directory, 'install-result.json'), 'utf8'));
      if (parseVersion(result.version) && compareVersions(result.version, this.options.currentVersion) >= 0 &&
          (result.status === 'failed' || String(result.message).includes('需手动'))) this.state.error = '上次更新：' + String(result.message).slice(0, 1200);
    } catch {}
  }
  snapshot() { return { ...this.state }; }
  change(value) { Object.assign(this.state, value); this.emit('change', this.snapshot()); return this.snapshot(); }
  configure(value) {
    if (this.operation) throw new Error('请等待当前更新操作完成');
    if (typeof value.autoCheck !== 'boolean' || !['stable', 'preview'].includes(value.channel)) throw new Error('更新设置无效');
    const changedChannel = value.channel !== this.preferences.channel;
    this.preferences = { autoCheck: value.autoCheck, channel: value.channel, ignoredVersion: changedChannel ? '' : this.preferences.ignoredVersion }; writePrivate(this.settingsFile, this.preferences);
    if (changedChannel) { this.candidate = null; this.change({ phase: 'idle', hasUpdate: false, latestVersion: '', notes: '', progress: 0 }); }
    return this.change(this.preferences);
  }
  cancel() { this.controller?.abort(); }
  later() {
    if (this.candidate) { this.preferences.ignoredVersion = this.candidate.version; writePrivate(this.settingsFile, this.preferences); }
    return this.change({ ignoredVersion: this.preferences.ignoredVersion });
  }
  async exclusive(kind, action) {
    if (this.operation) {
      if (this.operation.kind === kind) return this.operation.promise;
      throw new Error('请等待当前更新操作完成');
    }
    const operation = { kind, promise: Promise.resolve().then(action) }; this.operation = operation;
    try { return await operation.promise; } finally { if (this.operation === operation) this.operation = null; this.controller = null; }
  }
  check() {
    return this.exclusive('check', async () => {
      this.change({ phase: 'checking', error: '' }); this.controller = new AbortController();
      const signal = AbortSignal.any([this.controller.signal, AbortSignal.timeout(20000)]);
      try {
        const releases = [];
        for (let page = 1; page <= 3; page++) {
          const response = await updateResponse(`${api}?per_page=100&page=${page}`, { fetcher: this.fetcher, signal, headers: { Accept: 'application/vnd.github+json' } });
          const items = JSON.parse(await limitedText(response, 3 * 1024 * 1024));
          if (!Array.isArray(items)) throw new Error('GitHub 更新响应格式无效');
          releases.push(...items); if (items.length < 100) break;
        }
        const candidate = chooseUpdate(releases, { ...this.options, channel: this.preferences.channel });
        const ready = this.state.phase === 'ready' || existsSync(path.join(this.directory, 'ready.json'));
        const prior = this.candidate; this.candidate = candidate;
        if (!candidate) return this.change({ phase: 'latest', hasUpdate: false, latestVersion: '', notes: '', progress: 0, checkedAt: Date.now() });
        const reuse = ready && prior?.url === candidate.url && prior.sha256 && (!candidate.sha256 || prior.sha256 === candidate.sha256) && existsSync(path.join(this.directory, candidate.name));
        if (reuse) this.candidate.sha256 = prior.sha256;
        return this.change({ phase: reuse ? 'ready' : 'available', hasUpdate: true, latestVersion: candidate.version, notes: candidate.notes,
          progress: reuse ? 100 : 0, totalBytes: candidate.size, downloadedBytes: reuse ? candidate.size : 0, checkedAt: Date.now() });
      } catch (error) { this.change({ phase: 'error', error: error.name === 'AbortError' || error.name === 'TimeoutError' ? '检查更新超时或已取消，请稍后重试' : error.message }); throw error; }
    });
  }
  download() {
    return this.exclusive('download', async () => {
      const item = this.candidate; if (!item) throw new Error('请先检查更新');
      const unlock = downloadLock(this.directory); this.controller = new AbortController();
      const signal = AbortSignal.any([this.controller.signal, AbortSignal.timeout(20 * 60000)]);
      const filename = path.join(this.directory, item.name); const partial = filename + '.part';
      try {
        this.change({ phase: 'downloading', error: '' });
        if (!item.sha256) {
          if (!item.checksumUrl) throw new Error('此版本缺少 SHA256 校验信息，暂不能自动下载');
          const response = await updateResponse(item.checksumUrl, { fetcher: this.fetcher, signal });
          item.sha256 = checksumFromText(await limitedText(response, 256 * 1024), item.name);
        }
        if (existsSync(filename) && statSync(filename).size === item.size && await fileSha256(filename) === item.sha256) {
          writePrivate(path.join(this.directory, 'ready.json'), item);
          return this.change({ phase: 'ready', progress: 100, downloadedBytes: item.size });
        }
        if (existsSync(partial) && (!lstatSync(partial).isFile() || lstatSync(partial).isSymbolicLink())) throw new Error('下载缓存路径无效');
        let offset = existsSync(partial) ? statSync(partial).size : 0;
        if (offset >= item.size) { unlinkSync(partial); offset = 0; }
        const response = await updateResponse(item.url, { fetcher: this.fetcher, signal, headers: offset ? { Range: `bytes=${offset}-` } : {} });
        if (!response.ok) { await response.body?.cancel(); throw new Error(`下载更新失败（HTTP ${response.status}），可稍后继续`); }
        if (offset && response.status === 206) {
          const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
          if (!range || Number(range[1]) !== offset || Number(range[2]) !== item.size - 1 || Number(range[3]) !== item.size) { await response.body?.cancel(); throw new Error('断点续传响应无效'); }
        } else if (response.status === 200) offset = 0;
        else { await response.body?.cancel(); throw new Error('下载更新响应无效'); }
        const hash = createHash('sha256');
        if (offset) for await (const chunk of createReadStream(partial)) hash.update(chunk);
        let received = offset; let lastNotice = 0;
        const meter = new Transform({ transform: (chunk, _encoding, done) => {
          received += chunk.length;
          if (received > item.size) return done(new Error('下载文件超过发布的大小'));
          hash.update(chunk);
          if (Date.now() - lastNotice > 250) { lastNotice = Date.now(); this.change({ downloadedBytes: received, progress: Math.floor(received / item.size * 100) }); }
          done(null, chunk);
        } });
        await pipeline(Readable.fromWeb(response.body), meter, createWriteStream(partial, { flags: offset ? 'a' : 'w', mode: 0o600 }), { signal });
        if (received !== item.size || hash.digest('hex') !== item.sha256) { unlinkSync(partial); throw new Error('更新文件校验失败，请重新下载'); }
        if (existsSync(filename)) unlinkSync(filename);
        renameSync(partial, filename); writePrivate(path.join(this.directory, 'ready.json'), item);
        return this.change({ phase: 'ready', downloadedBytes: received, progress: 100 });
      } catch (error) { this.change({ phase: 'available', error: this.controller.signal.aborted ? '下载已暂停，点击下载可继续' : error.message }); throw error; }
      finally { unlock(); }
    });
  }
  async verifiedFile() {
    if (!this.candidate || this.state.phase !== 'ready') throw new Error('请先完成更新下载');
    const filename = path.join(this.directory, this.candidate.name);
    if (!existsSync(filename) || !lstatSync(filename).isFile() || lstatSync(filename).isSymbolicLink() || statSync(filename).size !== this.candidate.size || await fileSha256(filename) !== this.candidate.sha256) {
      this.change({ phase: 'available', progress: 0, error: '更新缓存已变化，请重新下载' }); throw new Error('更新缓存已变化，请重新下载');
    }
    return filename;
  }
  releaseUrl() { return this.candidate?.releaseUrl || `https://github.com/${UPDATE_REPOSITORY}/releases`; }
  async prepareJob({ layout, installRoot, dataDir, parentPid = process.pid }) {
    if (!this.state.canInstall) throw new Error('当前安装方式需要打开下载文件后手动安装');
    const archive = await this.verifiedFile();
    const root = realpathSync(installRoot); const data = realpathSync(dataDir);
    if (this.options.platform === 'linux') {
      try { accessSync(path.dirname(root), constants.W_OK); }
      catch { this.change({ canInstall: false, error: '安装目录需要管理员权限，请打开下载包后手动更新' }); throw new Error('安装目录需要管理员权限，可使用 update --download-only 下载后手动更新'); }
    }
    const relative = path.relative(root, data);
    if (!relative || relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative)) throw new Error('配置目录位于安装目录内，请手动更新以保留配置');
    const resources = this.options.kind === 'desktop' && this.options.platform === 'linux' ? path.join(root, 'resources') : this.options.platform === 'win32' ? path.join(root, 'resources') : root;
    for (const name of ['host/cli.mjs', 'runtime/node' + (this.options.platform === 'win32' ? '.exe' : ''), 'bin/clawmate-codex' + (this.options.platform === 'win32' ? '.exe' : '')]) {
      if (!statSync(path.join(resources, name)).isFile()) throw new Error('安装目录不是完整的 ClawMate 连接器');
    }
    const folder = mkdtempSync(path.join(this.directory, 'install-'));
    const helper = path.join(folder, 'update-helper.mjs'); const node = path.join(folder, this.options.platform === 'win32' ? 'node.exe' : 'node');
    copyFileSync(path.join(layout.base, 'host', 'update-helper.mjs'), helper); copyFileSync(layout.node, node);
    if (this.options.platform !== 'win32') chmodSync(node, 0o755);
    const job = { version: this.candidate.version, sha256: this.candidate.sha256, size: this.candidate.size, archive,
      platform: this.options.platform, kind: this.options.kind, installRoot: root, dataDir: data, parentPid, folder };
    writePrivate(path.join(folder, 'job.json'), job);
    return { node, helper, jobFile: path.join(folder, 'job.json'), job };
  }
}

export async function quiesceForUpdate(directory, layout, request, quit) {
  let status;
  try { status = await request(directory, 'status'); } catch (error) { if (!gone(error)) throw error; }
  if (!status) return { wasRunning: false };
  if ((status.tasks || []).some(task => busy.has(task.status))) throw new Error('还有任务正在执行或状态未确认，请等待完成或刷新状态后再更新');
  const prepared = await request(directory, 'prepareUpdate');
  try { await quit(directory, layout); }
  catch (error) { await request(directory, 'cancelUpdate').catch(() => {}); throw error; }
  return prepared;
}
export function startUpdateJob(prepared, wasRunning, launch = spawn) {
  writePrivate(path.join(prepared.job.dataDir, 'update-resume.json'), { version: prepared.job.version, wasRunning });
  const log = openSync(path.join(prepared.job.folder, 'install.log'), 'a', 0o600); let child;
  try { child = launch(prepared.node, [prepared.helper, prepared.jobFile], { detached: true, windowsHide: true, stdio: ['ignore', log, log],
    env: { ...process.env, CLAWMATE_CODEX_DATA_DIR: prepared.job.dataDir } }); } finally { closeSync(log); }
  return new Promise((resolve, reject) => { child.once('error', reject); child.once('spawn', () => { child.unref(); resolve(); }); });
}
