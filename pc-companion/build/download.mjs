import { execFileSync } from 'node:child_process';
import { readFileSync, mkdirSync, existsSync, unlinkSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

export function download(url, filename, expected, algorithm = 'sha256') {
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:' || !['registry.npmjs.org', 'nodejs.org', 'github.com', 'raw.githubusercontent.com'].includes(parsed.hostname)) throw new Error('Download host not allowed');
  mkdirSync(path.dirname(filename), { recursive: true });
  const valid = () => !expected || createHash(algorithm).update(readFileSync(filename)).digest('hex') === expected;
  if (existsSync(filename) && expected && valid()) return filename;
  execFileSync('curl', ['--fail', '--location', '--proto', '=https', '--tlsv1.2', '--retry', '2',
    '--connect-timeout', '20', '--max-time', '1200', '--silent', '--show-error', '--output', filename, url], { stdio: 'inherit' });
  if (!valid()) { unlinkSync(filename); throw new Error('Downloaded runtime checksum does not match the committed lock file'); }
  return filename;
}
