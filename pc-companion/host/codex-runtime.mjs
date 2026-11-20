import { execFileSync } from 'node:child_process';
import { accessSync, constants, realpathSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function windowsDesktopLocations(env) {
  const system = env.SystemRoot || 'C:\\Windows';
  const powershell = path.win32.join(system, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  try {
    return execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-Command',
      "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -ExpandProperty InstallLocation"],
    { encoding: 'utf8', timeout: 12000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }).split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  } catch { return []; }
}

function executablePath(filename, platform) {
  try {
    const resolved = realpathSync(filename);
    if (!statSync(resolved).isFile()) return null;
    accessSync(resolved, platform === 'win32' ? constants.F_OK : constants.X_OK);
    return resolved;
  } catch { return null; }
}

function externalExecutableValidator(resources, platform, resolve) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  let resourcePath = resources && paths.resolve(resources);
  try { if (resourcePath) resourcePath = realpathSync(resourcePath); } catch {}
  return candidate => {
    if (!paths.isAbsolute(candidate) || (platform === 'win32' && paths.extname(candidate).toLowerCase() !== '.exe')) return null;
    const found = resolve(candidate, platform);
    if (!found) return null;
    const relative = resourcePath ? paths.relative(resourcePath, found) : '..';
    return relative === '..' || relative.startsWith('..' + paths.sep) || paths.isAbsolute(relative) ? found : null;
  };
}

export function validateCodexSelection(filename, resources) {
  if (!externalExecutableValidator(resources, process.platform, executablePath)(filename)) {
    throw new Error('请选择电脑上已安装的 Codex 可执行文件。');
  }
}

export function findCodexRuntime({ env = process.env, platform = process.platform, arch = process.arch, home = os.homedir(),
  resources, preferredExecutable, desktopLocations = windowsDesktopLocations, resolve = executablePath } = {}) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  const executable = platform === 'win32' ? 'codex.exe' : 'codex';
  const validate = externalExecutableValidator(resources, platform, resolve);
  const preferred = typeof preferredExecutable === 'string' && validate(preferredExecutable);
  if (preferred) return preferred;

  const missing = message => Object.assign(new Error(message), { code: 'CODEX_NOT_FOUND' });
  const override = env.CLAWMATE_CODEX_EXECUTABLE?.trim();
  if (override) {
    const found = validate(override);
    if (!found) throw missing('CLAWMATE_CODEX_EXECUTABLE 无效，请填写本机 Codex 可执行文件的绝对路径。');
    return found;
  }

  const folders = (env.PATH || env.Path || '').split(paths.delimiter).map(folder => folder.trim().replace(/^"|"$/g, '')).filter(folder => paths.isAbsolute(folder));
  const candidates = [];
  if (platform === 'win32') {
    for (const folder of desktopLocations(env)) candidates.push(paths.join(folder, 'app', 'resources', executable));
    const windowsApps = paths.join(env.ProgramFiles || 'C:\\Program Files', 'WindowsApps');
    for (const folder of folders) {
      const relative = paths.relative(windowsApps, folder);
      if (/^OpenAI\.Codex_[^\\]+\\app\\resources$/i.test(relative)) candidates.push(paths.join(folder, executable));
    }
    candidates.push(paths.join(env.LOCALAPPDATA || paths.join(home, 'AppData', 'Local'), 'Programs', 'OpenAI', 'Codex', 'bin', executable));
  } else if (platform === 'darwin') {
    const app = 'Codex.app/Contents/Resources/codex';
    candidates.push(paths.join('/Applications', app), paths.join(home, 'Applications', app));
  }
  if (platform === 'win32' && env.APPDATA) folders.push(paths.join(env.APPDATA, 'npm'));
  if (platform !== 'win32') folders.push(paths.join(home, '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin');
  for (const folder of folders) {
    candidates.push(paths.join(folder, executable));
    if (platform === 'win32' && ['x64', 'arm64'].includes(arch)) {
      // npm's .cmd shim cannot be spawned without a shell. Use its installed native binary.
      const packageRoot = paths.join(folder, 'node_modules', '@openai');
      const target = `codex-win32-${arch}`;
      const triple = arch === 'arm64' ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc';
      for (const root of [packageRoot, paths.join(packageRoot, 'codex', 'node_modules', '@openai')]) {
        candidates.push(paths.join(root, target, 'vendor', triple, 'bin', executable));
      }
    }
  }
  for (const candidate of new Set(candidates)) {
    const found = validate(candidate);
    if (found) return found;
  }
  throw missing('未找到本机 Codex。请安装 Codex 桌面版或 CLI，或手动选择已安装的 Codex。');
}
