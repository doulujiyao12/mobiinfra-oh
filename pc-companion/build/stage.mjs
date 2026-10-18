import { build } from 'esbuild';
import { mkdirSync, cpSync, readFileSync, writeFileSync, chmodSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2] || `${process.platform}-${process.arch}`;
const [platform, arch] = target.split('-');
const output = path.join(root, 'out', target);
const resources = path.join(output, 'resources');
const app = path.join(output, 'app');
mkdirSync(path.join(resources, 'bin'), { recursive: true }); mkdirSync(path.join(resources, 'host'), { recursive: true });
const extension = platform === 'win32' ? '.exe' : '';
execFileSync('go', ['build', '-trimpath', '-ldflags=-s -w', '-o', path.join(resources, 'bin', 'clawmate-codex' + extension), '.'], {
  cwd: path.join(root, 'launcher'), stdio: 'inherit', env: { ...process.env, CGO_ENABLED: '0',
    GOOS: platform === 'win32' ? 'windows' : platform, GOARCH: arch === 'x64' ? 'amd64' : 'arm64' }
});
cpSync(path.join(root, 'vendor', target), path.join(resources, 'runtime'), { recursive: true });
cpSync(path.resolve(root, '../AppScope/resources/base/media/Icon.png'), path.join(resources, 'icon.png'));
const banner = "import { createRequire as __makeRequire } from 'node:module'; const require = __makeRequire(import.meta.url);";
await build({ entryPoints: [path.join(root, 'host', 'cli.mjs')], outfile: path.join(resources, 'host', 'cli.mjs'),
  bundle: true, platform: 'node', format: 'esm', target: 'node22', banner: { js: banner } });
mkdirSync(path.join(app, 'desktop'), { recursive: true });
await build({ entryPoints: [path.join(root, 'desktop', 'main.mjs')], outfile: path.join(app, 'desktop', 'main.mjs'),
  bundle: true, platform: 'node', format: 'esm', external: ['electron'], target: 'node22', banner: { js: banner } });
cpSync(path.join(root, 'desktop', 'preload.cjs'), path.join(app, 'desktop', 'preload.cjs'));
cpSync(path.join(root, 'desktop', 'ui'), path.join(app, 'desktop', 'ui'), { recursive: true });
const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
writeFileSync(path.join(app, 'package.json'), JSON.stringify({ name: pkg.name, productName: pkg.productName, version: pkg.version,
  description: pkg.description, homepage: pkg.homepage, author: pkg.author, license: pkg.license, main: 'desktop/main.mjs', type: 'module' }, null, 2));
const licenseRoot = path.join(resources, 'licenses'); mkdirSync(licenseRoot, { recursive: true });
cpSync(path.join(resources, 'runtime', 'licenses'), licenseRoot, { recursive: true });
// Include the production JS dependency tree's license texts with the bundled CLI.
const visited = new Set();
function licenses(packageName) {
  if (visited.has(packageName)) return; visited.add(packageName);
  const location = path.join(root, 'node_modules', packageName);
  const metadata = JSON.parse(readFileSync(path.join(location, 'package.json'), 'utf8'));
  const folder = path.join(licenseRoot, packageName.replace(/[@/]/g, '_')); mkdirSync(folder, { recursive: true });
  for (const filename of readdirSync(location)) if (/^(LICENSE|COPYING|NOTICE)/i.test(filename)) cpSync(path.join(location, filename), path.join(folder, filename));
  writeFileSync(path.join(folder, 'package.json'), JSON.stringify({ name: metadata.name, version: metadata.version, license: metadata.license }, null, 2));
  for (const dependency of Object.keys(metadata.dependencies || {})) licenses(dependency);
}
licenses('qrcode');
cpSync(path.join(root, 'USER-GUIDE.md'), path.join(resources, '使用说明.md'));
writeFileSync(path.join(output, 'target.json'), JSON.stringify({ platform, arch, target }));
console.log('Staged desktop application and standalone terminal runtime:', output);
