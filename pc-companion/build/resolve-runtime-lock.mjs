// Maintainer-only: resolve fixed versions once and commit their integrity values before packaging.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { download } from './download.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cache = path.join(root, '.cache'); mkdirSync(cache, { recursive: true });
const nodeVersion = '22.23.2'; const codexVersion = '0.160.1';
download(`https://nodejs.org/dist/v${nodeVersion}/SHASUMS256.txt`, path.join(cache, 'node-shasums.txt'));
const checksums = new Map(readFileSync(path.join(cache, 'node-shasums.txt'), 'utf8').trim().split('\n').map(line => line.trim().split(/\s+/).reverse()));
const licenseUrl = `https://raw.githubusercontent.com/openai/codex/rust-v${codexVersion}/LICENSE`;
const licenseFile = path.join(cache, 'CODEX-LICENSE.txt'); download(licenseUrl, licenseFile);
const lock = { nodeVersion, codexVersion, codexLicense: { url: licenseUrl,
  sha256: createHash('sha256').update(readFileSync(licenseFile)).digest('hex') }, targets: {} };
for (const platform of ['linux', 'win32', 'darwin']) for (const arch of ['x64', 'arm64']) {
  const target = `${platform}-${arch}`;
  const nodeName = `node-v${nodeVersion}-${platform === 'win32' ? 'win' : platform}-${arch}.${platform === 'win32' ? 'zip' : 'tar.gz'}`;
  const metadataFile = path.join(cache, `codex-${target}.json`);
  download(`https://registry.npmjs.org/@openai/codex/${codexVersion}-${target}`, metadataFile);
  const metadata = JSON.parse(readFileSync(metadataFile, 'utf8'));
  if (metadata.version !== `${codexVersion}-${target}` || !metadata.dist.integrity?.startsWith('sha512-')) throw new Error('Unexpected Codex package metadata');
  if (!checksums.has(nodeName)) throw new Error(`Official Node runtime missing: ${nodeName}`);
  lock.targets[target] = {
    node: { url: `https://nodejs.org/dist/v${nodeVersion}/${nodeName}`, sha256: checksums.get(nodeName) },
    codex: { url: metadata.dist.tarball, sha512: Buffer.from(metadata.dist.integrity.slice(7), 'base64').toString('hex') }
  };
}
writeFileSync(path.join(root, 'runtime-lock.json'), JSON.stringify(lock, null, 2) + '\n');
console.log('Wrote fixed Node/Codex runtime checksums for 6 targets.');
