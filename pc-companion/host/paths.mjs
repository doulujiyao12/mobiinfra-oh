import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export const VERSION = '1.1.13';
export function dataDirectory(env = process.env, platform = process.platform) {
  if (env.CLAWMATE_CODEX_DATA_DIR) return path.resolve(env.CLAWMATE_CODEX_DATA_DIR);
  if (platform === 'win32') return path.join(env.LOCALAPPDATA || os.homedir(), 'ClawMateCodex');
  if (platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support', 'ClawMateCodex');
  return path.join(env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'clawmate-codex');
}
export function installLayout(root = process.env.CLAWMATE_CODEX_RESOURCES) {
  const base = root ? path.resolve(root) : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'out', 'resources');
  const executable = process.platform === 'win32' ? '.exe' : '';
  return { base, node: path.join(base, 'runtime', 'node' + executable),
    codex: path.join(base, 'runtime', 'bin', 'codex' + executable),
    cli: path.join(base, 'host', 'cli.mjs'), launcher: path.join(base, 'bin', 'clawmate-codex' + executable) };
}
