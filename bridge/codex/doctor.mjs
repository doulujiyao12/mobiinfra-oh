import { readFileSync } from 'node:fs';

// Check HTTPS and authentication without showing a token in process arguments or logs.
async function main() {
  const [, , filename, endpoint] = process.argv;
  if (!filename || !endpoint) throw new Error('Usage: node doctor.mjs <config.json> <https://server[:port]>');
  const origin = new URL(endpoint);
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/') {
    throw new Error('Supply an HTTPS origin only');
  }
  const config = JSON.parse(readFileSync(filename, 'utf8'));
  const response = await fetch(new URL('/v1/info', origin), { redirect: 'error',
    headers: { Authorization: `Bearer ${config.token}` }, signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`Bridge returned HTTP ${response.status}`);
  const info = await response.json();
  if (info.protocol !== 1 || !info.ready) throw new Error('Bridge protocol/ready check failed');
  console.log(JSON.stringify({ https: 'ok', authentication: 'ok', protocol: info.protocol,
    workspaces: info.workspaces.length, models: info.models.length }, null, 2));
}
main().catch(() => {
  console.error('连接检查失败。请检查地址、证书完整链与有效期、桥接令牌、监听地址、防火墙和 Codex 进程。');
  process.exitCode = 1;
});
