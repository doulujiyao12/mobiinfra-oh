import http from 'node:http';
import https from 'node:https';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CodexRpc } from './rpc.mjs';
import { BridgeCore, BridgeError, MAX_BODY_BYTES, MAX_FILE_BYTES } from './core.mjs';

const digest = value => createHash('sha256').update(value).digest();
const loopback = host => ['127.0.0.1', '::1', 'localhost'].includes(host);

async function bodyJson(req, limit) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) {
    throw new BridgeError(415, 'Content-Type must be application/json');
  }
  if (Number(req.headers['content-length'] || 0) > limit) throw new BridgeError(413, 'Request too large');
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    if (length > limit) throw new BridgeError(413, 'Request too large');
    chunks.push(chunk);
  }
  let body;
  try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new BridgeError(400, 'Invalid JSON'); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new BridgeError(400, 'JSON object required');
  return body;
}

export function createBridgeServer(config, core) {
  if (typeof config.token !== 'string' || !/^[A-Za-z0-9_-]{43,128}$/.test(config.token)) {
    throw new Error('Use a random bridge token with at least 256 bits of entropy');
  }
  const tls = config.tls?.cert && config.tls?.key;
  if (!tls && !loopback(config.host || '127.0.0.1')) throw new Error('Non-loopback listeners require TLS');
  const expected = digest(`Bearer ${config.token}`);
  const rates = new Map();
  let uploadsInFlight = 0;
  const handler = async (req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (tls) res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    const send = (status, data) => { res.writeHead(status); res.end(JSON.stringify(data)); };
    let releasingUpload = false;
    try {
      // Native apps do not send Origin. Block browser origins rather than offering CORS.
      if (req.headers.origin !== undefined) throw new BridgeError(403, 'Browser origins are not permitted');
      const ip = req.socket.remoteAddress;
      const now = Date.now();
      let bucket = rates.get(ip);
      if (!bucket || now - bucket.since >= 60000) { bucket = { since: now, count: 0 }; rates.set(ip, bucket); }
      if (++bucket.count > 180) throw new BridgeError(429, 'Too many requests; retry in a minute');
      if (rates.size > 4096) for (const [key, b] of rates) if (now - b.since > 60000) rates.delete(key);
      if (!timingSafeEqual(digest(req.headers.authorization || ''), expected)) {
        res.setHeader('WWW-Authenticate', 'Bearer');
        throw new BridgeError(401, 'Bridge token rejected');
      }
      const url = new URL(req.url, 'http://bridge.invalid');
      if (url.search && !(req.method === 'GET' && /^\/v1\/tasks\/[^/]+$/.test(url.pathname))) {
        throw new BridgeError(400, 'Unexpected query parameters');
      }
      const route = url.pathname;
      if (req.method === 'GET' && route === '/v1/info') {
        core.requireReady();
        return send(200, { protocol: 1, name: config.name || 'Codex PC', ready: core.ready,
          workspaces: core.workspaces.map(w => ({ id: w.id, name: w.name })),
          models: core.models, maxFileBytes: MAX_FILE_BYTES });
      }
      if (req.method === 'GET' && route === '/v1/tasks') return send(200, { tasks: core.list() });
      const match = route.match(/^\/v1\/tasks\/([A-Za-z0-9_-]+)(?:\/(turns|interrupt|approvals))?$/);
      if (req.method === 'GET' && match && !match[2]) {
        const task = core.get(match[1]);
        return send(200, url.searchParams.get('revision') === String(task.revision) ? { unchanged: true } : { task });
      }
      if (req.method !== 'POST') throw new BridgeError(404, 'Route not found');
      const isUpload = route === '/v1/uploads';
      if (isUpload && uploadsInFlight >= 2) throw new BridgeError(429, 'Upload busy; retry shortly');
      if (isUpload) { uploadsInFlight++; releasingUpload = true; }
      const body = await bodyJson(req, isUpload ? MAX_BODY_BYTES : 64000);
      if (route === '/v1/tasks') return send(201, { task: await core.create(body) });
      if (isUpload) return send(201, { attachment: await core.upload(body) });
      if (match?.[2] === 'turns') return send(200, { task: await core.start(match[1], body) });
      if (match?.[2] === 'interrupt') return send(200, { task: await core.interrupt(match[1]) });
      if (match?.[2] === 'approvals') return send(200, { task: core.answer(match[1], body) });
      throw new BridgeError(404, 'Route not found');
    } catch (error) {
      if (!res.headersSent && !res.destroyed) {
        send(error instanceof BridgeError ? error.status : 502,
          { error: error instanceof BridgeError ? error.message : 'Codex operation failed; refresh task state and inspect PC configuration' });
      }
    } finally { if (releasingUpload) uploadsInFlight--; }
  };
  const server = tls ? https.createServer({ cert: readFileSync(config.tls.cert),
    key: readFileSync(config.tls.key), minVersion: 'TLSv1.2' }, handler) : http.createServer(handler);
  server.requestTimeout = 60000;
  server.headersTimeout = 15000;
  server.timeout = 65000;
  server.maxHeadersCount = 40;
  return server;
}

export function initializeConfig(filename, workspace) {
  const absolute = path.resolve(filename);
  const project = realpathSync(workspace);
  if (!statSync(project).isDirectory()) throw new Error('Workspace must be a directory');
  const relative = path.relative(project, absolute);
  if (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative)) {
    throw new Error('Store the config outside the agent workspace');
  }
  mkdirSync(path.dirname(absolute), { recursive: true, mode: 0o700 });
  const config = { name: '我的 Codex', host: '127.0.0.1', port: 8787,
    token: randomBytes(32).toString('base64url'), codexCommand: 'codex',
    stateDir: path.join(path.dirname(absolute), 'state'),
    workspaces: [{ id: 'default', name: path.basename(project), path: project }] };
  // Refuse to overwrite an existing secret, including a symlink.
  writeFileSync(absolute, `${JSON.stringify(config, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  return config;
}

async function main() {
  const [, , action, filename, workspace] = process.argv;
  if (action === 'init' && filename && workspace) {
    initializeConfig(filename, workspace);
    console.log('已生成配置。请在本机查看 token 字段，配置 HTTPS 后填入手机。请勿分享配置文件。');
    return;
  }
  if (action === 'rotate' && filename) {
    const target = realpathSync(filename);
    const config = JSON.parse(readFileSync(target, 'utf8'));
    config.token = randomBytes(32).toString('base64url');
    writeFileSync(target, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
    console.log('桥接令牌已轮换。重启服务后，旧令牌失效；请在手机端更新。');
    return;
  }
  if (action !== 'serve' || !filename) throw new Error('Usage: node server.mjs init <config.json> <project-dir> | serve <config.json> | rotate <config.json>');
  const configPath = realpathSync(filename);
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  for (const w of config.workspaces) {
    const relative = path.relative(realpathSync(w.path), configPath);
    if (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative)) {
      throw new Error('Config containing the bridge token must be outside agent workspaces');
    }
  }
  const rpc = new CodexRpc(config.codexCommand || 'codex');
  const core = new BridgeCore(config, rpc);
  const server = createBridgeServer(config, core);
  try { await core.initialize(); }
  catch { rpc.close(); throw new Error('Codex initialization failed. Check installation/login on the PC.'); }
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.port || 8787, config.host || '127.0.0.1', resolve);
  });
  console.log(`ClawMate Codex bridge listening (${config.tls ? 'HTTPS' : 'loopback HTTP'}), protocol v1`);
  let closing = false;
  const close = () => {
    if (closing) return;
    closing = true;
    core.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  };
  process.on('SIGINT', close);
  process.on('SIGTERM', close);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exit(1); });
}
