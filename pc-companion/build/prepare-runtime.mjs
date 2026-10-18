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
if (platform === 'win32') {
  // Windows/macOS/Linux tar implementations used by CI support zip extraction through their native tool.
  if (process.platform === 'win32') execFileSync('tar', ['-xf', nodeArchive, '-C', temporary], { stdio: 'inherit' });
  else execFileSync('unzip', ['-o', '-q', nodeArchive, '-d', temporary], { stdio: 'inherit' });
} else execFileSync('tar', ['-xzf', nodeArchive, '-C', temporary], { stdio: 'inherit' });
const nodeFolder = path.join(temporary, `node-v${lock.nodeVersion}-${platform === 'win32' ? 'win' : platform}-${arch}`);
cpSync(path.join(nodeFolder, platform === 'win32' ? 'node.exe' : 'bin/node'), path.join(destination, platform === 'win32' ? 'node.exe' : 'node'));
const codexArchive = download(lock.targets[target].codex.url, path.join(temporary, 'codex.tgz'), lock.targets[target].codex.sha512, 'sha512');
execFileSync('tar', ['-xzf', codexArchive, '-C', temporary], { stdio: 'inherit' });
const triple = `${arch === 'x64' ? 'x86_64' : 'aarch64'}-${platform === 'win32' ? 'pc-windows-msvc' : platform === 'darwin' ? 'apple-darwin' : 'unknown-linux-musl'}`;
const codexFolder = path.join(temporary, 'package', 'vendor', triple);
// Include Codex's companion binaries (code-mode host and search tools), not just the main executable.
cpSync(codexFolder, destination, { recursive: true });
const licenses = path.join(destination, 'licenses'); mkdirSync(licenses, { recursive: true });
cpSync(path.join(nodeFolder, 'LICENSE'), path.join(licenses, 'NODE-LICENSE.txt'));
const pkg = JSON.parse(readFileSync(path.join(temporary, 'package', 'package.json'), 'utf8'));
writeFileSync(path.join(licenses, 'CODEX-PACKAGE.json'), JSON.stringify({ name: pkg.name, version: pkg.version, license: pkg.license, repository: pkg.repository }, null, 2));
// The release includes upstream license and notices; fail rather than silently shipping without them.
download(lock.codexLicense.url, path.join(licenses, 'CODEX-LICENSE.txt'), lock.codexLicense.sha256);
if (platform !== 'win32') {
  chmodSync(path.join(destination, 'node'), 0o755); chmodSync(path.join(destination, 'bin', 'codex'), 0o755);
}
writeFileSync(path.join(destination, 'runtime.json'), JSON.stringify({ target, nodeVersion: lock.nodeVersion, codexVersion: lock.codexVersion }, null, 2));
console.log('Prepared verified runtimes:', target);
