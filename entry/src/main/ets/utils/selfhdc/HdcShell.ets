export interface HdcShellPlan {
  wireCommand: string;
  marker: string;
}

export interface HdcShellResult {
  output: string;
  exitCode: number;
}

export function buildHdcShellPlan(command: string, session: number, channel: number): HdcShellPlan {
  if (!command.trim() || command.indexOf('\0') >= 0) {
    throw new Error('HDC_SHELL: empty command or embedded NUL');
  }
  let marker = '__SELF_HDC_EXIT_' + String(session) + '_' + String(channel) + '__:';
  // The daemon executes a shell script. Keep the actual command in a subshell so its exit
  // code is captured even when it changes directories or calls exit. Never retry it on parse failure.
  let script = '( ' + command + ' ); __self_hdc_rc=$?; printf \'\\n' + marker + '%s\\n\' "$__self_hdc_rc"';
  return { wireCommand: script, marker: marker };
}

export function hdcShellOutputPreview(output: string, sensitive: boolean): string {
  if (sensitive) { return '(sensitive output omitted)'; }
  // Escape control characters so a malformed/truncated reply remains readable in a log line.
  return output.substring(0, 768).replace(/\r/g, '\\r').replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t').replace(/\0/g, '\\0') + (output.length > 768 ? '…(truncated)' : '');
}

export function parseHdcShellResult(output: string, marker: string): HdcShellResult {
  let normalized = output.replace(/\0+$/, '');
  let index = normalized.lastIndexOf('\n' + marker);
  if (index < 0) {
    throw new Error('HDC_SHELL: exit marker missing; compound script may be truncated or output incomplete');
  }
  let exitText = normalized.substring(index + marker.length + 1).trim();
  let exitCode = Number(exitText);
  if (!/^\d{1,3}$/.test(exitText) || !Number.isInteger(exitCode) || exitCode < 0 || exitCode > 255) {
    throw new Error('HDC_SHELL: invalid exit marker');
  }
  return { output: normalized.substring(0, index), exitCode: exitCode };
}
