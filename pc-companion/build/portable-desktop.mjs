// Cross-host unsigned evaluation bundles. Native signed releases still use electron-builder.
import { download } from './download.mjs';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2];
if (!['linux-x64', 'linux-arm64', 'darwin-arm64', 'darwin-x64'].includes(target)) throw new Error('Choose a Linux/macOS portable target');
const [platform, arch] = target.split('-');
const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
const stage = path.join(root, 'out', target);
if (JSON.parse(readFileSync(path.join(stage, 'target.json'), 'utf8')).target !== target) throw new Error('Stage target mismatch');
const electron = pkg.devDependencies.electron;
const release = `https://github.com/electron/electron/releases/download/v${electron}/`;
const archiveName = `electron-v${electron}-${platform}-${arch}.zip`;
const cache = path.join(root, '.cache', 'electron-portable', target);
const sums = download(release + 'SHASUMS256.txt', path.join(cache, 'SHASUMS256.txt'));
const checksum = readFileSync(sums, 'utf8').split(/\r?\n/).map(line => /^([a-f0-9]{64})\s+\*?(.+)$/i.exec(line))
  .find(match => match && match[2] === archiveName)?.[1];
if (!checksum) throw new Error('Electron release checksum is missing for ' + archiveName);
const archive = download(release + archiveName, path.join(cache, archiveName), checksum);
const output = path.join(root, 'dist', target); mkdirSync(output, { recursive: true });
const filename = `ClawMate-Codex-${pkg.version}-${platform}-${arch}-unsigned.${platform === 'darwin' ? 'zip' : 'tar.gz'}`;
execFileSync(process.env.CLAWMATE_PYTHON || 'python', [path.join(root, 'build', 'portable-desktop.py'),
  '--electron', archive, '--stage', stage, '--target', target, '--version', pkg.version, '--output', path.join(output, filename)],
{ stdio: 'inherit' });
const hash = createHash('sha256').update(readFileSync(path.join(output, filename))).digest('hex');
writeFileSync(path.join(output, 'SHA256SUMS.txt'), hash + '  ' + filename + '\n');
writeFileSync(path.join(output, 'BUILD-INFO.json'), JSON.stringify({ version: pkg.version, target, host: process.platform,
  format: 'portable-desktop', signed: false, notarized: false, nativeRuntimeTested: false,
  electronVersion: pkg.devDependencies.electron, artifactProtocol: 1 }, null, 2));
console.log('Built unsigned portable desktop:', path.join(output, filename));
