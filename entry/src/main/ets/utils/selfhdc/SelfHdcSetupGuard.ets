import { router, UIContext } from '@kit.ArkUI';
import { AppLogger } from '../AppLogger';
import { showToastSafely } from '../PromptSafe';
import { SelfHdcTaskSettings } from './SelfHdcTaskSettings';
import { PHONE_HDC_SETUP_GUIDE, selfHdcSetupProblem } from './SelfHdcSetupPolicy';

export class SelfHdcSetupGuard {
  private static checking: boolean = false;

  // Do not queue task starts behind a dialog or automatically replay them after settings navigation.
  static async ensure(uiContext: UIContext, filesDir: string, reason: string,
    phoneModeOnly: boolean = true): Promise<boolean> {
    if (SelfHdcSetupGuard.checking) { return false; }
    SelfHdcSetupGuard.checking = true;
    try {
      if (phoneModeOnly && SelfHdcTaskSettings.load(filesDir).mode !== 'phone') { return true; }
      let settings = await SelfHdcTaskSettings.refreshLocalIp(filesDir, reason);
      // A user may have changed the mode while address detection was pending.
      if (phoneModeOnly && settings.mode !== 'phone') { return true; }
      let problem = selfHdcSetupProblem(settings, AppStorage.get<string>('selfHdcDetectedWifiIp') || '');
      if (problem.length === 0) { return true; }
      AppLogger.info('SelfHdc', 'SETUP_REQUIRED source=' + reason + ' ' + problem.replace(/\n/g, ' '));
      let openSettings = false;
      await new Promise<void>((resolve): void => {
        uiContext.showAlertDialog({
          title: '请设置手机自控',
          message: problem + '\n\n' + PHONE_HDC_SETUP_GUIDE +
            '\n\n检测到 IP 只表示网络地址可用，仍需开启无线调试。端口重新开启后可能变化。',
          autoCancel: true,
          onDidDisappear: (): void => { resolve(); },
          primaryButton: { value: '稍后设置', action: (): void => {} },
          secondaryButton: { value: '去设置', action: (): void => { openSettings = true; } }
        });
      });
      if (openSettings) { await router.pushUrl({ url: 'pages/settings/SelfHdcTestPage' }, router.RouterMode.Single); }
      return false;
    } catch (e) {
      AppLogger.warnCause('SelfHdc', 'Setup check failed source=' + reason, e as Error);
      showToastSafely('手机自控设置检查失败，请到“我的 > 手机 HDC”检查：' + (e as Error).message, 2500);
      return false;
    } finally { SelfHdcSetupGuard.checking = false; }
  }
}
