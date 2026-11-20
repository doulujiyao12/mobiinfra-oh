import { readFileSync, mkdirSync, cpSync, chmodSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { download } from './download.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2] || `${process.platform}-${process.arch}`;
const lock = JSON.parse(readFileSync(path.join(root, 'runtime-lock.json'), 'utf8'));
if (!lock.targets[target]) throw new Error('Unsupported runtime target: ' + target);
const [platform, arch] = target.split('-');
const destination = path.join(root, 'vendor', target); mkdirSync(destination, { recursive: true });
const temporary = path.join(root, '.cache', target); mkdirSync(temporary, { recursive: true });
const nodeArchive = download(lock.targets[target].node.url, path.join(temporary, path.basename(lock.targets[target].node.url)), lock.targets[target].node.sha256);
const nodeName = `node-v${lock.nodeVersion}-${platform === 'win32' ? 'win' : platform}-${arch}`;
if (platform === 'win32') {
  // Windows/macOS/Linux tar implementations used by CI support zip extraction through their native tool.
  if (process.platform === 'win32') execFileSync('tar', ['-xf', nodeArchive, '-C', temporary], { stdio: 'inherit' });
  else execFileSync('unzip', ['-o', '-q', nodeArchive, '-d', temporary], { stdio: 'inherit' });
} else {
  // Only these two files ship in the runtime. Avoid npm/corepack symlinks when cross-building on Windows.
  execFileSync('tar', ['-xzf', nodeArchive, '-C', temporary, `${nodeName}/bin/node`, `${nodeName}/LICENSE`], { stdio: 'inherit' });
}
const nodeFolder = path.join(temporary, nodeName);
cpSync(path.join(nodeFolder, platform === 'win32' ? 'node.exe' : 'bin/node'), path.join(destination, platform === 'win32' ? 'node.exe' : 'node'));
const licenses = path.join(destination, 'licenses'); mkdirSync(licenses, { recursive: true });
cpSync(path.join(nodeFolder, 'LICENSE'), path.join(licenses, 'NODE-LICENSE.txt'));
if (platform !== 'win32') chmodSync(path.join(destination, 'node'), 0o755);
writeFileSync(path.join(destination, 'runtime.json'), JSON.stringify({ target, nodeVersion: lock.nodeVersion }, null, 2));
console.log('Prepared verified Node.js runtime:', target);
