import { JSON as ArkJSON } from '@kit.ArkTS';
import { selfHdcEnsureDirectory, selfHdcExists, selfHdcReadText, selfHdcWriteAtomicText } from './SelfHdcFiles';
import { AppLogger } from '../AppLogger';
import { readSelfHdcNetworks } from './SelfHdcNetwork';
import { selectSelfHdcWifiIpv4 } from './SelfHdcNetworkPolicy';
import { SelfHdcSetupConnection, selfHdcControlMode } from './SelfHdcSetupPolicy';

export class SelfHdcTaskSettings implements SelfHdcSetupConnection {
  mode: string = 'phone';
  ip: string = '';
  port: string = '';
  autoIp: boolean = true;
  skipSetupReminder: boolean = false;
  private static refreshing: Promise<SelfHdcTaskSettings> | null = null;

  static load(filesDir: string): SelfHdcTaskSettings {
    let settings = new SelfHdcTaskSettings();
    let path = filesDir + '/self_hdc/task_connection.json';
    if (selfHdcExists(path)) {
      let saved = ArkJSON.parse(selfHdcReadText(path, 4096)) as SelfHdcTaskSettings;
      settings.mode = selfHdcControlMode(saved.mode);
      settings.ip = typeof saved.ip === 'string' ? saved.ip : '';
      settings.port = typeof saved.port === 'string' ? saved.port : '';
      settings.autoIp = typeof saved.autoIp === 'boolean' ? saved.autoIp : settings.ip !== '127.0.0.1';
      settings.skipSetupReminder = saved.skipSetupReminder === true;
    } else {
      let latest = filesDir + '/self_hdc/latest.json';
      if (selfHdcExists(latest)) {
        let saved = ArkJSON.parse(selfHdcReadText(latest, 256 * 1024)) as LegacySelfHdcEndpoint;
        if (typeof saved.endpoint === 'string') {
          let parts = saved.endpoint.split(':');
          if (parts.length === 2) {
            settings.ip = parts[0]; settings.port = parts[1]; settings.autoIp = settings.ip !== '127.0.0.1';
          }
        }
      }
    }
    return settings;
  }

  static save(filesDir: string, settings: SelfHdcTaskSettings): void {
    selfHdcEnsureDirectory(filesDir + '/self_hdc');
    selfHdcWriteAtomicText(filesDir + '/self_hdc/task_connection.json', ArkJSON.stringify(settings));
    AppStorage.setOrCreate('selfHdcTaskIp', settings.ip);
    AppStorage.setOrCreate('selfHdcTaskPort', settings.port);
    AppStorage.setOrCreate('selfHdcTaskAutoIp', settings.autoIp);
  }

  static saveEndpoint(filesDir: string, ip: string, port: string): void {
    let settings = SelfHdcTaskSettings.load(filesDir);
    settings.ip = ip.trim(); settings.port = port.trim();
    SelfHdcTaskSettings.save(filesDir, settings);
  }

  static saveMode(filesDir: string, mode: string): void {
    let settings = SelfHdcTaskSettings.load(filesDir);
    settings.mode = selfHdcControlMode(mode);
    SelfHdcTaskSettings.save(filesDir, settings);
  }

  static saveSetupReminderChoice(filesDir: string, skipReminder: boolean): void {
    let settings = SelfHdcTaskSettings.load(filesDir);
    settings.skipSetupReminder = skipReminder;
    SelfHdcTaskSettings.save(filesDir, settings);
  }

  static async refreshLocalIp(filesDir: string, reason: string): Promise<SelfHdcTaskSettings> {
    if (SelfHdcTaskSettings.refreshing !== null) { return await SelfHdcTaskSettings.refreshing; }
    let pending = SelfHdcTaskSettings.detectLocalIp(filesDir, reason);
    SelfHdcTaskSettings.refreshing = pending;
    try { return await pending; }
    finally { SelfHdcTaskSettings.refreshing = null; }
  }

  private static async detectLocalIp(filesDir: string, reason: string): Promise<SelfHdcTaskSettings> {
    try {
      let network = await readSelfHdcNetworks();
      // Read again after asynchronous detection: preserve any newer user port/mode/manual-IP edits.
      let settings = SelfHdcTaskSettings.load(filesDir);
      let detected = selectSelfHdcWifiIpv4(network.candidates, settings.ip);
      AppStorage.setOrCreate('selfHdcDetectedWifiIp', detected);
      AppStorage.setOrCreate('selfHdcLocalAddresses', network.localIpv4.join('、') || '未读到 IPv4 地址');
      let oldIp = settings.ip;
      if (settings.autoIp && detected) { settings.ip = detected; }
      SelfHdcTaskSettings.save(filesDir, settings);
      let status = settings.autoIp ? (detected ? '已自动更新 Wi-Fi IP：' + detected : '未检测到可用 Wi-Fi IPv4，保留上次地址') :
        '使用手动 IP；当前检测到 Wi-Fi IP：' + (detected || '无');
      AppStorage.setOrCreate('selfHdcIpStatus', status);
      AppLogger.info('SelfHdc', 'IP_REFRESH source=' + reason + ' auto=' + settings.autoIp + ' previous=' + oldIp +
        ' detected=' + detected + ' saved=' + settings.ip + ' portSource=manual');
      network.warnings.forEach((warning: string): void => { AppLogger.warn('SelfHdc', 'IP_REFRESH ' + warning); });
      return settings;
    } catch (e) {
      AppStorage.setOrCreate('selfHdcDetectedWifiIp', '');
      AppStorage.setOrCreate('selfHdcIpStatus', '自动检测 IP 失败：' + (e as Error).message + '；保留已保存的连接设置');
      AppLogger.warnCause('SelfHdc', 'IP_REFRESH source=' + reason + ' failed', e as Error);
      return SelfHdcTaskSettings.load(filesDir);
    }
  }
}

interface LegacySelfHdcEndpoint { endpoint?: string; }
