import { readdirSync, readFileSync, readlinkSync, lstatSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function secureDaemonSocket(socketPath, uid = process.getuid?.()) {
  try {
    if (!path.isAbsolute(socketPath) || socketPath.length > 107 || realpathSync(socketPath) !== socketPath) return false;
    const socket = lstatSync(socketPath), parent = lstatSync(path.dirname(socketPath));
    return socket.isSocket() && socket.uid === uid && !(socket.mode & 0o077) &&
      parent.isDirectory() && !parent.isSymbolicLink() && parent.uid === uid && !(parent.mode & 0o077);
  } catch { return false; }
}

// Read only our UID/namespace/CODEX_HOME. Never expose process environments or
// connect arbitrary network listeners. Linux daemon sockets have private parents.
export function discoverDaemons(environment = process.env) {
  if (process.platform !== 'linux') return [];
  const uid = process.getuid(); const results = new Set();
  let home, namespace, unix;
  try {
    home = realpathSync(environment.CODEX_HOME || path.join(os.homedir(), '.codex'));
    namespace = readlinkSync('/proc/self/ns/net');
    unix = readFileSync('/proc/net/unix', 'utf8').split('\n').map(line => line.trim().split(/\s+/));
  } catch { return []; }
  for (const pid of readdirSync('/proc').filter(name => /^\d+$/.test(name))) {
    try {
      const proc = '/proc/' + pid;
      if (lstatSync(proc).uid !== uid || readlinkSync(proc + '/ns/net') !== namespace) continue;
      const executable = readlinkSync(proc + '/exe');
      if (path.basename(executable) !== 'codex') continue;
      const args = readFileSync(proc + '/cmdline', 'utf8').split('\0');
      const listener = args.find(value => value.startsWith('--listen='))?.slice(9) || args[args.indexOf('--listen') + 1];
      if (!args.includes('app-server') || !listener?.startsWith('unix://')) continue;
      const env = readFileSync(proc + '/environ', 'utf8').split('\0');
      const codexHome = env.find(value => value.startsWith('CODEX_HOME='))?.slice(11) || path.join(os.homedir(), '.codex');
      if (realpathSync(codexHome) !== home) continue;
      const inodes = new Set(readdirSync(proc + '/fd').flatMap(fd => {
        try { const match = /^socket:\[(\d+)\]$/.exec(readlinkSync(proc + '/fd/' + fd)); return match ? [match[1]] : []; }
        catch { return []; }
      }));
      for (const columns of unix) {
        const socketPath = columns[7];
        // 00010000 denotes a listening Unix stream socket, not a connected peer.
        if (columns[3] === '00010000' && inodes.has(columns[6]) && socketPath && secureDaemonSocket(socketPath, uid)) results.add(socketPath);
      }
    } catch { /* A process may exit or be hidden while discovery is running. */ }
  }
  return [...results].sort().slice(0, 8);
}
