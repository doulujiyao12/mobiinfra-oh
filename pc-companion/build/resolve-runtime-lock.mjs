// Maintainer-only: resolve fixed versions once and commit their integrity values before packaging.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { download } from './download.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cache = path.join(root, '.cache'); mkdirSync(cache, { recursive: true });
const nodeVersion = '22.23.2';
download(`https://nodejs.org/dist/v${nodeVersion}/SHASUMS256.txt`, path.join(cache, 'node-shasums.txt'));
const checksums = new Map(readFileSync(path.join(cache, 'node-shasums.txt'), 'utf8').trim().split('\n').map(line => line.trim().split(/\s+/).reverse()));
const lock = { nodeVersion, targets: {} };
for (const platform of ['linux', 'win32', 'darwin']) for (const arch of ['x64', 'arm64']) {
  const target = `${platform}-${arch}`;
  const nodeName = `node-v${nodeVersion}-${platform === 'win32' ? 'win' : platform}-${arch}.${platform === 'win32' ? 'zip' : 'tar.gz'}`;
  if (!checksums.has(nodeName)) throw new Error(`Official Node runtime missing: ${nodeName}`);
  lock.targets[target] = {
    node: { url: `https://nodejs.org/dist/v${nodeVersion}/${nodeName}`, sha256: checksums.get(nodeName) }
  };
}
writeFileSync(path.join(root, 'runtime-lock.json'), JSON.stringify(lock, null, 2) + '\n');
console.log('Wrote fixed Node.js runtime checksums for 6 targets.');
