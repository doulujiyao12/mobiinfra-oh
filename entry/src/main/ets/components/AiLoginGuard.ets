import { UIContext } from '@kit.ArkUI';
import { AiServiceAccess, AI_LOGIN_REQUIRED_MESSAGE } from '../utils/AiServiceAccess';
import { showToastSafely } from '../utils/PromptSafe';

export class AiLoginGuard {
  private static visible: boolean = false;

  // 拦截时立即返回，不排队或自动重发用户的消息。后台刷新不弹窗。
  static ensure(uiContext: UIContext, showPrompt: boolean = true): boolean {
    if (AiServiceAccess.isAllowed()) {
      return true;
    }
    if (showPrompt && !AiLoginGuard.visible) {
      AiLoginGuard.visible = true;
      try {
        uiContext.showAlertDialog({
          title: '请先登录',
          message: AI_LOGIN_REQUIRED_MESSAGE,
          autoCancel: true,
          onDidDisappear: () => { AiLoginGuard.visible = false; },
          confirm: { value: '知道了', action: () => {} }
        });
      } catch (e) {
        AiLoginGuard.visible = false;
        showToastSafely(AI_LOGIN_REQUIRED_MESSAGE);
      }
    }
    return false;
  }
}
