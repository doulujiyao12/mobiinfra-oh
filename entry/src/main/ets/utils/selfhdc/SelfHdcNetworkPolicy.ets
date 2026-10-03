export interface SelfHdcIpCandidate {
  ip: string;
  isWifi: boolean;
  isVpn: boolean;
  isDefault: boolean;
}

export function selfHdcIsUsableWifiIpv4(ip: string): boolean {
  let parts = ip.split('.');
  if (parts.length !== 4 || parts.some((part: string): boolean => {
    return !/^(0|[1-9]\d{0,2})$/.test(part) || Number(part) > 255;
  })) { return false; }
  let first = Number(parts[0]); let second = Number(parts[1]);
  return first > 0 && first < 224 && first !== 127 && !(first === 169 && second === 254);
}

export function selectSelfHdcWifiIpv4(candidates: SelfHdcIpCandidate[], previousIp: string): string {
  let wifi = candidates.filter((item: SelfHdcIpCandidate): boolean => {
    return item.isWifi && !item.isVpn && selfHdcIsUsableWifiIpv4(item.ip);
  });
  let preferred = wifi.filter((item: SelfHdcIpCandidate): boolean => item.isDefault);
  let pool = preferred.length > 0 ? preferred : wifi;
  let previous = pool.find((item: SelfHdcIpCandidate): boolean => item.ip === previousIp);
  return previous ? previous.ip : (pool.length > 0 ? pool[0].ip : '');
}
