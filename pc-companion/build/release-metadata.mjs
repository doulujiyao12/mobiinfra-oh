import { createReadStream, readdirSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const directory = path.resolve(process.argv[2] || path.join(root, 'dist'));
const { version } = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
const rows = [];
for (const name of readdirSync(directory).sort()) {
  if (!name.startsWith(`ClawMate-Codex-${version}-`) && !name.startsWith(`ClawMate-Codex-Terminal-${version}-`)) continue;
  if (!/\.(exe|zip|tar\.gz|dmg|deb)$/.test(name) || !statSync(path.join(directory, name)).isFile()) continue;
  const hash = createHash('sha256'); for await (const chunk of createReadStream(path.join(directory, name))) hash.update(chunk);
  rows.push(hash.digest('hex') + '  ' + name);
}
if (!rows.length) throw new Error('No current-version release assets found');
writeFileSync(path.join(directory, 'SHA256SUMS.txt'), rows.join('\n') + '\n');
console.log(`Release codex-bridge-v${version}: SHA256 checksums for ${rows.length} assets`);
