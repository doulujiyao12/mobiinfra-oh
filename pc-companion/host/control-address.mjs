import { createHash } from 'node:crypto';
import path from 'node:path';

// Unix socket limits apply to UTF-8 bytes, including the full parent path.
// macOS's canonical /private/var/folders/.../T directory is often too long.
export function controlAddress(directory, { platform, uid, temporaryDirectory, fallbackDirectory }) {
  const hash = createHash('sha256').update(directory).digest('hex').slice(0, 20);
  if (platform === 'win32') return `\\\\.\\pipe\\clawmate-codex-${hash}`;
  const limit = platform === 'darwin' ? 103 : 107;
  for (const root of [temporaryDirectory, fallbackDirectory]) {
    if (!root || !path.posix.isAbsolute(root)) continue;
    const address = path.posix.join(root, `clawmate-codex-${uid}-${hash}`, 'control.sock');
    if (Buffer.byteLength(address, 'utf8') <= limit) return address;
  }
  throw new Error(`本机控制通道路径超过系统的 ${limit} 字节上限，请检查临时目录设置。`);
}
