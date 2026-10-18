import { execFileSync } from 'node:child_process';
import { readFileSync, mkdirSync, readdirSync, writeFileSync, copyFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2] || `${process.platform}-${process.arch}`;
const [platform, arch] = target.split('-');
const cliOnly = process.argv.includes('--cli-only');
const output = path.join(root, 'dist', target); mkdirSync(output, { recursive: true });
const version = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const resources = path.join(root, 'out', target, 'resources');
const archive = `ClawMate-Codex-Terminal-${version}-${target}.${platform === 'win32' ? 'zip' : 'tar.gz'}`;
if (platform === 'win32' && process.platform !== 'win32') execFileSync('bsdtar', ['-a', '-cf', path.join(output, archive), '-C', resources, '.'], { stdio: 'inherit' });
else execFileSync('tar', [platform === 'win32' ? '-a' : '-z', '-cf', path.join(output, archive), '-C', resources, '.'], { stdio: 'inherit' });
if (!cliOnly) {
  const builder = path.join(root, 'node_modules', 'electron-builder', 'cli.js');
  const platformTargets = platform === 'win32' ? ['--win'] : platform === 'darwin' ?
    (process.platform === 'darwin' ? ['--mac'] : ['--mac', 'zip']) : ['--linux'];
  execFileSync(process.execPath, [builder, '--config', path.join(root, 'electron-builder.cjs'),
    ...platformTargets, '--' + arch, '--publish', 'never'],
    { cwd: root, stdio: 'inherit', env: { ...process.env, CLAWMATE_BUILD_TARGET: target } });
}
const sums = readdirSync(output).filter(name => /\.(deb|dmg|exe|zip|tar\.gz)$/.test(name)).map(name => {
  return createHash('sha256').update(readFileSync(path.join(output, name))).digest('hex') + '  ' + name;
});
writeFileSync(path.join(output, 'SHA256SUMS.txt'), sums.join('\n') + '\n');
console.log('Built:', output);
