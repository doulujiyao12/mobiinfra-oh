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
    phoneModeOnly: boolean = true): Promise<boolean> {
    if (SelfHdcSetupGuard.checking) { return false; }
    SelfHdcSetupGuard.checking = true;
    try {
      let settings = SelfHdcTaskSettings.load(filesDir);
      if (phoneModeOnly && settings.mode !== 'phone') { return true; }
      settings = await SelfHdcTaskSettings.refreshLocalIp(filesDir, reason);
      // A user may have changed the mode while address detection was pending.
      if (phoneModeOnly && settings.mode !== 'phone') { return true; }
      let problem = selfHdcSetupProblem(settings);
      if (problem.length === 0) { return true; }
      AppLogger.info('SelfHdc', 'SETUP_REQUIRED source=' + reason + ' ' + problem.replace(/\n/g, ' '));
      let openSettings = await showSelfHdcSetupDialog(uiContext, problem);
      if (openSettings) { await router.pushUrl({ url: 'pages/settings/SelfHdcTestPage' }, router.RouterMode.Single); }
      return false;
    } catch (e) {
      AppLogger.warnCause('SelfHdc', 'Setup check failed source=' + reason, e as Error);
      showToastSafely('手机自控设置检查失败，请到“我的 > 手机 HDC”检查：' + (e as Error).message, 2500);
      return false;
    } finally { SelfHdcSetupGuard.checking = false; }
  }
}
