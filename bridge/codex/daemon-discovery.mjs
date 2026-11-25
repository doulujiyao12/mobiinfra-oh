import { readdirSync, readFileSync, readlinkSync, lstatSync, realpathSync } from 'node:fs';
import { execFile } from 'node:child_process';
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

const privateWindowsSocket = String.raw`
$ErrorActionPreference = 'Stop'
$acl = [IO.Directory]::GetAccessControl($env:CLAWMATE_CODEX_SOCKET_DIRECTORY)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Equals($sid) -and
    $acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and
    $rules[0].IdentityReference.Equals($sid) -and $rules[0].AccessControlType -eq 'Allow' -and
    $rules[0].FileSystemRights -eq 'FullControl' -and
    $rules[0].InheritanceFlags -eq $inheritance -and
    $rules[0].PropagationFlags -eq 'None') {
  # IO_REPARSE_TAG_AF_UNIX. A symlink or junction has a different tag.
  $socket = $env:CLAWMATE_CODEX_SOCKET_PATH
  $tag = & ([IO.Path]::Combine($env:SystemRoot, 'System32/fsutil.exe')) reparsepoint query $socket
  if ($LASTEXITCODE -eq 0 -and $tag[0] -match '(?i)\b0x80000023\s*$') { exit 0 }
}
exit 1
`;

function checkWindowsSocket(directory, socket) {
  const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return new Promise(resolve => execFile(powershell, ['-NoProfile', '-NonInteractive', '-Command', privateWindowsSocket], {
    env: { ...process.env, CLAWMATE_CODEX_SOCKET_DIRECTORY: directory, CLAWMATE_CODEX_SOCKET_PATH: socket }, windowsHide: true, timeout: 3000
  }, error => resolve(!error)));
}

export async function validatedDaemonSocket(socket) {
  const directory = path.dirname(socket);
  try {
    const stat = lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) return null;
    if (process.platform === 'win32') {
      // Node can list an AF_UNIX entry but lstat/existsSync cannot open it.
      if (!readdirSync(directory).includes(path.basename(socket))) return null;
      return await checkWindowsSocket(directory, socket) ? socket : null;
    }
    if (stat.uid !== process.getuid() || (stat.mode & 0o077)) return null;
    // Codex can use a short, private physical socket and expose its default
    // control path as a symlink. Validate both ends before dialing it.
    const physical = realpathSync(socket);
    return secureDaemonSocket(physical) ? physical : null;
  } catch { return null; }
}

// Discover the managed per-user socket on each OS. Linux additionally searches
// custom local daemons in the same UID, network namespace and CODEX_HOME.
export async function discoverDaemons(environment = process.env) {
  let home;
  try { home = realpathSync(environment.CODEX_HOME || path.join(os.homedir(), '.codex')); }
  catch { return []; }
  const managed = await validatedDaemonSocket(path.join(home, 'app-server-control', 'app-server-control.sock'));
  const results = new Set(managed ? [managed] : []);
  if (process.platform !== 'linux') return [...results];
  return discoverLinuxDaemons(home, results);
}

function discoverLinuxDaemons(home, results) {
  const uid = process.getuid();
  let namespace, unix, entries;
  try {
    namespace = readlinkSync('/proc/self/ns/net');
    unix = readFileSync('/proc/net/unix', 'utf8').split('\n').map(line => line.trim().split(/\s+/));
    entries = readdirSync('/proc');
  } catch { return [...results]; }
  for (const pid of entries.filter(name => /^\d+$/.test(name))) {
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
  return [...results].slice(0, 8);
}
