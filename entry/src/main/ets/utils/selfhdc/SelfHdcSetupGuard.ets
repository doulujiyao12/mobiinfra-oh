import { router, UIContext } from '@kit.ArkUI';
import { AppLogger } from '../AppLogger';
import { showToastSafely } from '../PromptSafe';
import { SelfHdcTaskSettings } from './SelfHdcTaskSettings';
import { selfHdcSetupProblem } from './SelfHdcSetupPolicy';
import { showSelfHdcSetupDialog } from '../../components/SelfHdcSetupDialog';

export class SelfHdcSetupGuard {
  private static checking: boolean = false;

  // Do not queue task starts behind a dialog or automatically replay them after settings navigation.
  static async ensure(uiContext: UIContext, filesDir: string, reason: string,
    phoneModeOnly: boolean = true, startupReminderOnly: boolean = false): Promise<boolean> {
    if (SelfHdcSetupGuard.checking) { return false; }
    SelfHdcSetupGuard.checking = true;
    try {
      let settings = SelfHdcTaskSettings.load(filesDir);
      if (phoneModeOnly && settings.mode !== 'phone') { return true; }
      if (!startupReminderOnly) {
        settings = await SelfHdcTaskSettings.refreshLocalIp(filesDir, reason);
        // A user may have changed the mode while address detection was pending.
        if (phoneModeOnly && settings.mode !== 'phone') { return true; }
        let problem = selfHdcSetupProblem(settings, AppStorage.get<string>('selfHdcDetectedWifiIp') || '');
        if (problem.length === 0) { return true; }
        AppLogger.info('SelfHdc', 'SETUP_REQUIRED source=' + reason + ' ' + problem.replace(/\n/g, ' '));
        if (settings.port.trim().length > 0 || settings.skipSetupReminder) {
          // Suppressing the guide never bypasses connection validation before a phone task.
          showToastSafely('请检查“我的 > 手机 HDC”的连接设置：\n' + problem, 3000);
          return false;
        }
      } else {
        // Reminder eligibility uses saved settings only; no device state inspection.
        if (settings.port.trim().length > 0 || settings.skipSetupReminder) { return true; }
        AppLogger.info('SelfHdc', 'SETUP_GUIDE source=' + reason);
      }
      let openSettings = await showSelfHdcSetupDialog(uiContext, (skipReminder: boolean): void => {
        SelfHdcTaskSettings.saveSetupReminderChoice(filesDir, skipReminder);
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
