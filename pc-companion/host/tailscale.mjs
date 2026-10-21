import http from 'node:http';
import { isIPv4 } from 'node:net';
import { lstatSync, readFileSync, readdirSync, readlinkSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';

// Userspace Tailscale has no OS interface. Query only its local, read-only API;
// never start/login/configure Tailscale or read its state/credential files.
export function isTailscaleIPv4(address) {
  if (typeof address !== 'string' || !isIPv4(address)) return false;
  const parts = address.split('.').map(Number);
  return parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}

export function discoverTailscaleSockets({ env = process.env, procRoot = '/proc', uid = process.getuid?.() } = {}) {
  const explicit = env.CLAWMATE_TAILSCALE_SOCKET || env.TS_SOCKET;
  const candidates = explicit ? [explicit] : ['/var/run/tailscale/tailscaled.sock', '/run/tailscale/tailscaled.sock'];
  if (!explicit) {
    let entries = [];
    try { entries = readdirSync(procRoot); } catch {}
    let networkNamespace;
    try { networkNamespace = readlinkSync(path.join(procRoot, 'self/ns/net')); } catch {}
    for (const pid of entries) {
      if (!/^\d+$/.test(pid)) continue;
      try {
        const folder = path.join(procRoot, pid);
        if (readFileSync(path.join(folder, 'comm'), 'utf8').trim() !== 'tailscaled') continue;
        const owner = statSync(folder).uid;
        if (owner !== 0 && owner !== uid) continue;
        if (networkNamespace && readlinkSync(path.join(folder, 'ns/net')) !== networkNamespace) continue;
        const args = readFileSync(path.join(folder, 'cmdline'), 'utf8').split('\0');
        for (let i = 1; i < args.length; i++) {
          if (args[i].startsWith('--socket=')) candidates.push(args[i].slice('--socket='.length));
          else if (args[i] === '--socket' && args[i + 1]) candidates.push(args[i + 1]);
        }
      } catch {} // Other users' or already-exited processes need no extra permissions.
    }
  }
  const sockets = [];
  for (const filename of candidates) {
    if (typeof filename !== 'string' || !path.isAbsolute(filename) || filename.includes('\0')) continue;
    try {
      const resolved = realpathSync(filename);
      if (lstatSync(resolved).isSocket() && !sockets.includes(resolved)) sockets.push(resolved);
    } catch {}
  }
  return sockets.slice(0, 8);
}

export function readTailscaleStatus(socketPath, { timeout = 1500, maxBytes = 1024 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    let timer; let settled = false;
    const fail = error => {
      if (settled) return;
      settled = true; clearTimeout(timer); reject(error); req.destroy(error);
    };
    const req = http.get({ socketPath, path: '/localapi/v0/status?peers=false', agent: false,
      headers: { Host: 'local-tailscaled.sock', Accept: 'application/json' } }, res => {
      if (res.statusCode !== 200) {
        res.resume();
        const error = new Error('Tailscale local status is unavailable');
        error.code = res.statusCode === 403 ? 'EACCES' : 'TAILSCALE_HTTP';
        fail(error); return;
      }
      let size = 0; const chunks = [];
      res.on('data', chunk => {
        if (settled) return;
        size += chunk.length;
        if (size > maxBytes) { fail(Object.assign(new Error('Tailscale status too large'), { code: 'TAILSCALE_SIZE' })); return; }
        chunks.push(chunk);
      });
      res.on('error', fail);
      res.on('end', () => {
        clearTimeout(timer);
        if (settled) return;
        try { const value = JSON.parse(Buffer.concat(chunks).toString('utf8')); settled = true; resolve(value); }
        catch { fail(Object.assign(new Error('Invalid Tailscale status'), { code: 'TAILSCALE_JSON' })); }
      });
    });
    timer = setTimeout(() => fail(Object.assign(new Error('Tailscale status timed out'), { code: 'ETIMEDOUT' })), timeout);
    req.on('error', fail);
    req.on('close', () => clearTimeout(timer));
  });
}

function addressesFromStatus(status) {
  if (status?.BackendState !== 'Running' || status.Self?.Online === false || status.Self?.Expired === true) return [];
  // Never use Peer addresses: certificates must identify this server only.
  const source = status.Self?.TailscaleIPs ?? status.TailscaleIPs;
  return Array.isArray(source) ? [...new Set(source.filter(isTailscaleIPv4))].sort() : [];
}

export class TailscaleDiscovery {
  constructor({ platform = process.platform, env = process.env, discover = discoverTailscaleSockets,
    query = readTailscaleStatus, now = Date.now, cacheMs = 5000 } = {}) {
    this.enabled = platform === 'linux'; this.env = env; this.discover = discover;
    this.query = query; this.now = now; this.cacheMs = cacheMs;
    this.checkedAt = -Infinity; this.pending = null;
    this.snapshot = { state: this.enabled ? 'notChecked' : 'disabled', addresses: [], socketPath: '', message: '' };
  }
  status() { return { ...this.snapshot, addresses: [...this.snapshot.addresses] }; }
  async refresh({ force = false } = {}) {
    if (!this.enabled) return this.status();
    if (this.pending) return this.pending;
    if (!force && this.now() - this.checkedAt < this.cacheMs) return this.status();
    this.pending = this.inspect();
    try { return await this.pending; } finally { this.pending = null; }
  }
  async inspect() {
    let sockets = [];
    try { sockets = this.discover({ env: this.env }); } catch {}
    let next = { state: 'notFound', addresses: [], socketPath: '',
      message: '未发现 Tailscale 本地 socket；自定义路径可通过 CLAWMATE_TAILSCALE_SOCKET 指定。' };
    if (sockets.length) {
      const results = await Promise.all(sockets.map(async socketPath => {
        try { const status = await this.query(socketPath); return { socketPath, status, addresses: addressesFromStatus(status) }; }
        catch (error) { return { socketPath, error: error.code }; }
      }));
      const active = results.filter(result => result.addresses?.length);
      if (new Set(active.map(result => result.addresses.join(','))).size > 1) {
        next = { ...next, state: 'ambiguous', message: '发现多个不同的 Tailscale 实例，请用 CLAWMATE_TAILSCALE_SOCKET 选择本机实例。' };
      } else if (active.length) {
        next = { state: 'Running', addresses: active[0].addresses, socketPath: active[0].socketPath, message: '' };
      } else {
        const observed = results.find(result => result.status);
        next = { state: observed?.status?.BackendState || 'unavailable', addresses: [],
          socketPath: observed?.socketPath || sockets[0], message: observed ?
            'Tailscale 尚未联网或没有可用的本机 IPv4 地址，请检查 Tailscale 登录和连接状态。' :
            (results.some(result => result.error === 'EACCES') ? '无权读取 Tailscale 本地状态；请使用有读取权限的同一系统用户。' :
              'Tailscale 本地状态读取失败或超时，请检查 socket 和服务状态。') };
      }
    }
    // Failed/offline refreshes discard old addresses instead of silently reusing them.
    this.snapshot = next; this.checkedAt = this.now(); return this.status();
  }
}
