import { UIContext, window } from '@kit.ArkUI';
import { AppLogger } from './AppLogger';
import { AppTheme } from './AppTheme';

let currentUiContext: UIContext | null = null;
let currentBackgroundColor: string = '#FFFFFF';
let currentNavigationBarColor: string = '';

export function clearPageStatusBarContext(): void {
  currentUiContext = null;
}

// Native window APIs consume strings, so re-resolve them on configuration changes.
// ArkUI itself keeps resource handles and updates its colors automatically.
export function refreshPageStatusBarAppearance(): void {
  if (currentUiContext !== null) {
    applyPageStatusBar(currentUiContext, currentBackgroundColor, currentNavigationBarColor);
  }
}

// 状态栏保持透明，让 FrostedPage 的顶部材质连续绘制到系统状态栏后方。
// 窗口底色及系统导航区域仍分别跟随页面，保留原有底部与键盘避让。
export function applyPageStatusBar(uiContext: UIContext, backgroundColor: string,
  navigationBarColor: string = ''): void {
  currentUiContext = uiContext;
  currentBackgroundColor = backgroundColor;
  currentNavigationBarColor = navigationBarColor;
  try {
    let windowName = uiContext.getWindowName();
    if (windowName === undefined || windowName.length === 0) {
      return;
    }
    let pageWindow = window.findWindow(windowName);
    pageWindow.setWindowBackgroundColor(AppTheme.resolve(uiContext, AppTheme.pageBackground(backgroundColor)));
    let contentColor = AppTheme.resolve(uiContext, $r('app.color.ui_text_primary'));
    let systemBarProperties: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    };
    if (navigationBarColor.length > 0) {
      systemBarProperties.navigationBarColor = AppTheme.resolve(uiContext, AppTheme.pageBackground(navigationBarColor));
    }
    pageWindow.setWindowSystemBarProperties(systemBarProperties).catch((e: Error): void => {
      AppLogger.warnCause('PageStatusBar', 'Cannot update status bar appearance', e);
    });
  } catch (e) {
    AppLogger.warnCause('PageStatusBar', 'Cannot update page window background', e as Error);
  }
}
