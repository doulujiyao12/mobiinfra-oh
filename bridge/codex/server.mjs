import http from 'node:http';
import https from 'node:https';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzip } from 'node:zlib';
import { CodexRpc } from './rpc.mjs';
import { BridgeCore, BridgeError, MAX_BODY_BYTES, MAX_FILE_BYTES } from './core.mjs';
import { MAX_ARTIFACT_BYTES } from './artifacts.mjs';
import { ReadCoordinator } from './read-coordinator.mjs';
import { TaskSync } from './task-sync.mjs';

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

export function createBridgeServer(config, core, extensions = {}) {
  if (typeof config.token !== 'string' || !/^[A-Za-z0-9_-]{43,128}$/.test(config.token)) {
    throw new Error('Use a random bridge token with at least 256 bits of entropy');
  }
  const tls = config.tls?.cert && config.tls?.key;
  if (!tls && !loopback(config.host || '127.0.0.1')) throw new Error('Non-loopback listeners require TLS');
  const expected = digest(`Bearer ${config.token}`);
  const rates = new Map();
  let uploadsInFlight = 0;
  const reads = new ReadCoordinator(); const sync = new TaskSync();
  const handler = async (req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (tls) res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    const send = (status, data) => {
      if (res.destroyed) return;
      const bytes = Buffer.from(JSON.stringify(data));
      const finish = (body, compressed) => {
        if (res.destroyed || res.headersSent) return;
        res.setHeader('Vary', 'Accept-Encoding');
        if (compressed) res.setHeader('Content-Encoding', 'gzip');
        res.setHeader('Content-Length', body.length); res.writeHead(status); res.end(body);
      };
      if (bytes.length >= 1024 && /(?:^|,)\s*gzip\s*(?:,|$)/i.test(req.headers['accept-encoding'] || '')) {
        gzip(bytes, { level: 4 }, (error, compressed) => finish(error ? bytes : compressed, !error));
      } else finish(bytes, false);
    };
    let releasingUpload = false;
    try {
      // Native apps do not send Origin. Block browser origins rather than offering CORS.
      if (req.headers.origin !== undefined) throw new BridgeError(403, 'Browser origins are not permitted');
      const url = new URL(req.url, 'http://bridge.invalid');
      const downloadRoute = /^\/v1\/tasks\/([A-Za-z0-9_-]+)\/artifacts\/([A-Za-z0-9_-]+)$/.exec(url.pathname);
      const ip = req.socket.remoteAddress + (downloadRoute ? ':artifact' : ':api');
      const now = Date.now();
      let bucket = rates.get(ip);
      if (!bucket || now - bucket.since >= 60000) { bucket = { since: now, count: 0 }; rates.set(ip, bucket); }
      if (++bucket.count > (downloadRoute ? 1200 : 180)) throw new BridgeError(429, 'Too many requests; retry in a minute');
      if (rates.size > 4096) for (const [key, b] of rates) if (now - b.since > 60000) rates.delete(key);
      if (req.method === 'POST' && url.pathname === '/v1/pair' && extensions.pairing) {
        if (url.search) throw new BridgeError(400, 'Unexpected query parameters');
        const body = await bodyJson(req, 4096);
        return send(200, extensions.pairing.redeem(body));
      }
      const authorization = req.headers.authorization || '';
      const deviceToken = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
      if (!timingSafeEqual(digest(authorization), expected) && !extensions.pairing?.authenticates(deviceToken)) {
        res.setHeader('WWW-Authenticate', 'Bearer');
        throw new BridgeError(401, 'Bridge token rejected');
      }
      if (url.search && !(req.method === 'GET' && (/^\/v1\/tasks\/[^/]+$/.test(url.pathname) ||
        /^\/v1\/threads(?:\/[A-Za-z0-9_-]{1,128})?$/.test(url.pathname) || downloadRoute))) {
        throw new BridgeError(400, 'Unexpected query parameters');
      }
      const route = url.pathname;
      if (req.method === 'GET' && route === '/v1/health') return send(200, { protocol: 1, ready: core.ready, serverTime: Date.now() });
      if (req.method === 'GET' && route === '/v1/info') {
        core.requireReady();
        return send(200, { protocol: 1, name: config.name || 'Codex PC', ready: core.ready,
          workspaces: core.workspaces.map(w => ({ id: w.id, name: w.name })),
          models: core.models, maxFileBytes: MAX_FILE_BYTES, artifactsSupported: true, maxArtifactBytes: MAX_ARTIFACT_BYTES,
          existingSessionsSupported: true, sameSessionSupported: true, permissionSettingsSupported: true, taskUpdatesSupported: true,
          healthSupported: true, taskDeltaSupported: true, artifactChunkBytes: 262144,
          desktopSessionSharingSupported: !!config.desktopCoordination });
      }
      if (req.method === 'GET' && route === '/v1/tasks') return send(200, { tasks: core.list() });
      const historyRoute = /^\/v1\/threads(?:\/([A-Za-z0-9_-]{1,128})(\/(?:fork|resume))?)?$/.exec(route);
      if (req.method === 'GET' && historyRoute && !historyRoute[2]) {
        if (url.searchParams.getAll('cursor').length > 1 || [...url.searchParams.keys()].some(key => key !== 'cursor')) {
          throw new BridgeError(400, 'Invalid history query');
        }
        const cursor = url.searchParams.get('cursor') || undefined;
        const result = await reads.run('history:' + (historyRoute[1] || 'list') + ':' + (cursor || ''), () =>
          historyRoute[1] ? core.history.read(historyRoute[1], cursor) : core.history.list(cursor));
        return send(200, historyRoute[1] ? { task: result } : result);
      }
      if (req.method === 'GET' && downloadRoute) {
        core.get(downloadRoute[1]);
        const offsets = url.searchParams.getAll('offset');
        const lengths = url.searchParams.getAll('length');
        if (offsets.length !== 1 || !/^(0|[1-9][0-9]{0,9})$/.test(offsets[0]) || lengths.length > 1 ||
          (lengths.length && (!/^\d{1,7}$/.test(lengths[0]) || Number(lengths[0]) < 16384 || Number(lengths[0]) > 1048576)) ||
          [...url.searchParams.keys()].some(key => !['offset', 'length'].includes(key))) {
          throw new BridgeError(400, 'Invalid artifact offset');
        }
        let chunk;
        try { chunk = core.artifacts.chunk(downloadRoute[1], downloadRoute[2], Number(offsets[0]), lengths.length ? Number(lengths[0]) : undefined); }
        catch { throw new BridgeError(409, 'Artifact unavailable or invalid offset; refresh the task'); }
        if (!chunk) throw new BridgeError(404, 'Artifact not found in this session');
        return send(200, { artifactChunk: chunk });
      }
      const match = route.match(/^\/v1\/tasks\/([A-Za-z0-9_-]+)(?:\/(turns|interrupt|approvals))?$/);
      if (req.method === 'GET' && match && !match[2]) {
        if ([...url.searchParams.keys()].some(key => !['revision', 'waitMs', 'sync'].includes(key)) ||
          url.searchParams.getAll('revision').length > 1 || url.searchParams.getAll('waitMs').length > 1 ||
          url.searchParams.getAll('sync').length > 1 || (url.searchParams.has('sync') && url.searchParams.get('sync') !== 'delta')) throw new BridgeError(400, 'Invalid task update query');
        const waitMs = url.searchParams.get('waitMs') || '0';
        const revision = url.searchParams.get('revision');
        if (!/^\d{1,5}$/.test(waitMs) || Number(waitMs) > 15000 ||
          (revision !== null && (!/^\d{1,15}$/.test(revision) || !Number.isSafeInteger(Number(revision)))) ||
          (Number(waitMs) && revision === null)) throw new BridgeError(400, 'Invalid task update wait');
        let task = await reads.run('task:' + match[1], () => core.snapshot(match[1]));
        if (res.destroyed) return;
        if (revision === String(task.revision) && Number(waitMs)) {
          const controller = new AbortController();
          const cancel = () => controller.abort();
          res.once('close', cancel);
          if (res.destroyed) controller.abort();
          try { await core.waitForChange(task.id, Number(revision), Number(waitMs), controller.signal); }
          finally { res.off('close', cancel); }
          if (res.destroyed) return;
          if (!timingSafeEqual(digest(authorization), expected) && !extensions.pairing?.authenticates(deviceToken)) throw new BridgeError(401, 'Device authorization was revoked');
          task = await reads.run('task:' + match[1], () => core.snapshot(match[1]));
        }
        return send(200, revision === String(task.revision) ? { unchanged: true } : sync.envelope(task, revision, url.searchParams.get('sync') === 'delta'));
      }
      if (req.method !== 'POST') throw new BridgeError(404, 'Route not found');
      const isUpload = route === '/v1/uploads';
      if (isUpload && uploadsInFlight >= 2) throw new BridgeError(429, 'Upload busy; retry shortly');
      if (isUpload) { uploadsInFlight++; releasingUpload = true; }
      const body = await bodyJson(req, isUpload ? MAX_BODY_BYTES : 64000);
      if (historyRoute?.[2] === '/fork') return send(201, { task: await core.history.fork(historyRoute[1], body) });
      if (historyRoute?.[2] === '/resume') return send(200, { task: await core.history.resume(historyRoute[1], body) });
      if (route === '/v1/tasks') return send(201, { task: await core.create(body) });
      if (isUpload) return send(201, { attachment: await core.upload(body) });
      if (match?.[2] === 'turns') return send(200, { task: await core.start(match[1], body) });
      if (match?.[2] === 'interrupt') return send(200, { task: await core.interrupt(match[1]) });
      if (match?.[2] === 'approvals') return send(200, { task: await core.answer(match[1], body) });
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
  server.requestTimeout = 90000;
  server.headersTimeout = 60000;
  server.keepAliveTimeout = 30000;
  server.timeout = 100000;
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

if (process.argv[1] && path.basename(process.argv[1]) === 'server.mjs' && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exit(1); });
}
