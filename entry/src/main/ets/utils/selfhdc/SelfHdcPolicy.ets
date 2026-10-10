export interface SelfHdcEndpoint {
  ip: string;
  port: number;
}

export interface SelfHdcSwipe {
  x: number;
  startY: number;
  endY: number;
}

export function parseSelfHdcEndpoint(ipText: string, portText: string): SelfHdcEndpoint {
  let ip = ipText.trim();
  let parts = ip.split('.');
  if (parts.length !== 4 || parts.some((part: string): boolean => {
    return !/^(0|[1-9]\d{0,2})$/.test(part) || Number(part) > 255;
  })) {
    throw new Error('SELF_HDC_INPUT: 请输入手机无线调试页面显示的 IPv4 地址');
  }
  let portValue = portText.trim();
  if (!/^\d{1,5}$/.test(portValue) || Number(portValue) < 1 || Number(portValue) > 65535) {
    throw new Error('SELF_HDC_INPUT: 调试端口必须是 1–65535 的整数');
  }
  return { ip: ip, port: Number(portValue) };
}

export function selfHdcShellQuote(value: string): string {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}

// execute() checks the exit code first. These tools may also report errors with exit=0.
export function selfHdcHasCommandFailure(output: string): boolean {
  return output.split(/[\r\n]+/).some((line: string): boolean => {
    let text = line.trim();
    // uitest reports successful input as a whole line containing "No Error".
    // Ignore only that line, so a subsequent real error still stops the test.
    if (/^no error$/i.test(text)) { return false; }
    return /error|fail|失败/i.test(text);
  });
}

export function selfHdcSwipeForSize(width: number, height: number): SelfHdcSwipe {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 100 || height < 100 ||
    width > 10000 || height > 10000) {
    throw new Error('SELF_HDC_IMAGE: 无效屏幕尺寸');
  }
  return { x: Math.floor(width * 0.5), startY: Math.floor(height * 0.72), endY: Math.floor(height * 0.32) };
}
