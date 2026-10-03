import { UIContext, window } from '@kit.ArkUI';
import { AppLogger } from './AppLogger';

// 状态栏保持透明，让 FrostedPage 的顶部材质连续绘制到系统状态栏后方。
// 窗口底色及系统导航区域仍分别跟随页面，保留原有底部与键盘避让。
export function applyPageStatusBar(uiContext: UIContext, backgroundColor: string,
  navigationBarColor: string = ''): void {
  try {
    let windowName = uiContext.getWindowName();
    if (windowName === undefined || windowName.length === 0) {
      return;
    }
    let pageWindow = window.findWindow(windowName);
    pageWindow.setWindowBackgroundColor(backgroundColor);
    let systemBarProperties: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      statusBarContentColor: '#172033'
    };
    if (navigationBarColor.length > 0) {
      systemBarProperties.navigationBarColor = navigationBarColor;
    }
    pageWindow.setWindowSystemBarProperties(systemBarProperties).catch((e: Error): void => {
      AppLogger.warnCause('PageStatusBar', 'Cannot update status bar appearance', e);
    });
  } catch (e) {
    AppLogger.warnCause('PageStatusBar', 'Cannot update page window background', e as Error);
  }
}
