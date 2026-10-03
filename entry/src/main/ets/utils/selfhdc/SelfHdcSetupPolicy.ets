import { parseSelfHdcEndpoint } from './SelfHdcPolicy';

export interface SelfHdcSetupConnection { ip: string; port: string; autoIp: boolean; }

export const PHONE_HDC_SETUP_GUIDE: string =
  '开启开发者模式：\n' +
  '1. 打开“设置 > 关于手机”。\n' +
  '2. 连续快速点击“软件版本号”7次。\n' +
  '3. 在设置中搜索“无线调试”，开启后记录 IP 地址和 HDC 连接端口。\n\n' +
  '到“我的 > 手机 HDC”填写连接端口。IP 默认自动更新，也可关闭自动更新后手动填写。';

// Only an explicit saved PC selection enables desktop control.
export function selfHdcControlMode(mode: string | undefined): string { return mode === 'pc' ? 'pc' : 'phone'; }

export function selfHdcSetupProblem(settings: SelfHdcSetupConnection, detectedWifiIp: string): string {
  let problems: string[] = [];
  if (settings.autoIp && detectedWifiIp.trim().length === 0) {
    problems.push('未检测到可用的手机 Wi-Fi IP，请连接 Wi-Fi，或手动填写无线调试页面的 IP。');
  }
  if (settings.ip.trim().length === 0) {
    problems.push('尚未填写手机 IP 地址。');
  } else {
    try { parseSelfHdcEndpoint(settings.ip, '1'); }
    catch (e) { problems.push('IP 地址格式不正确，请填写无线调试页面的 IPv4 地址。'); }
  }
  if (settings.port.trim().length === 0) {
    problems.push('尚未填写无线调试连接端口。');
  } else {
    try { parseSelfHdcEndpoint('127.0.0.1', settings.port); }
    catch (e) { problems.push('无线调试端口必须是 1–65535 的整数。'); }
  }
  return problems.join('\n');
}
