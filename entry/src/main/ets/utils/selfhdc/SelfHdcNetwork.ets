import { connection } from '@kit.NetworkKit';
import { SelfHdcIpCandidate } from './SelfHdcNetworkPolicy';

export interface SelfHdcNetworkSnapshot {
  candidates: SelfHdcIpCandidate[];
  localIpv4: string[];
  warnings: string[];
}

export async function readSelfHdcNetworks(): Promise<SelfHdcNetworkSnapshot> {
  let nets = await connection.getAllNets();
  let defaultId = -1;
  let snapshot: SelfHdcNetworkSnapshot = { candidates: [], localIpv4: [], warnings: [] };
  try { defaultId = (await connection.getDefaultNet()).netId; }
  catch (e) { snapshot.warnings.push('default network: ' + (e as Error).message); }
  for (let net of nets) {
    try {
      let properties = await connection.getConnectionProperties(net);
      let isWifi = /^wlan\d*$/i.test(properties.interfaceName);
      let isVpn = /^(tun|vpn|ppp)/i.test(properties.interfaceName);
      try {
        let caps = await connection.getNetCapabilities(net);
        isWifi = isWifi || caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
        isVpn = isVpn || caps.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0;
      } catch (e) { snapshot.warnings.push('capabilities net=' + net.netId + ': ' + (e as Error).message); }
      for (let link of properties.linkAddresses) {
        let ip = link.address.address;
        if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) { continue; }
        if (snapshot.localIpv4.indexOf(ip) < 0) { snapshot.localIpv4.push(ip); }
        snapshot.candidates.push({ ip: ip, isWifi: isWifi, isVpn: isVpn, isDefault: net.netId === defaultId });
      }
    } catch (e) { snapshot.warnings.push('properties net=' + net.netId + ': ' + (e as Error).message); }
  }
  return snapshot;
}
