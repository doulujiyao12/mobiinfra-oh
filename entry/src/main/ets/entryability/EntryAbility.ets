import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent } from '@kit.AbilityKit';
import { AppLogger } from '../utils/AppLogger';
import { display, window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AgentExecutionController } from '../utils/AgentExecutionController';
import { ProfileShareLaunchBridge } from '../utils/ProfileKnockShareService';
import {
  CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY,
  captureOverlayWindowTransition,
  FloatPanelManualMoveRect,
  resolveFloatPanelManualMoveRect
} from '../utils/CaptureOverlayPolicy';

const FLOAT_PANEL_COLLAPSED_WIDTH_VP = 88;
const FLOAT_PANEL_HEIGHT_VP = 72;
const FLOAT_PANEL_EXPANDED_WIDTH_RATIO = 0.84;
const FLOAT_PANEL_EXPANDED_MIN_WIDTH_VP = 300;
const FLOAT_PANEL_EXPANDED_SAFE_MARGIN_VP = 16;
const FLOAT_PANEL_RIGHT_MARGIN_VP = 12;
const FLOAT_PANEL_BOTTOM_MARGIN_VP = 100;
const DEFAULT_DISPLAY_WIDTH = 1080;
const DEFAULT_DISPLAY_HEIGHT = 2340;
const DEFAULT_DISPLAY_DENSITY = 3;
const FLOAT_PANEL_MOVE_THRESHOLD_PX = 8;

interface DisplaySize {
  width: number;
  height: number;
  density: number;
}

// 应用主 Ability：加载 Index 页面，并在 Agent 执行期间协调后台浮窗、
// 长时任务权限和“从浮窗回到主应用”的能力。
export default class EntryAbility extends UIAbility {
  private edgeFlowWindow: window.Window | null = null;
  private floatWindow: window.Window | null = null;
  private floatPanelX: number = 0;
  private floatPanelY: number = 0;
  private floatPanelWidth: number = 0;
  private floatPanelHeight: number = 0;
  private floatPanelHasCustomPosition: boolean = false;
  private floatPanelAnchorCenterX: number = 0;
  private floatPanelAnchorCenterY: number = 0;
  private floatPanelMoveStartX: number = 0;
  private floatPanelMoveStartY: number = 0;
  private floatPanelMoveStartWidth: number = 0;
  private floatPanelMoveStartHeight: number = 0;
  private floatPanelMoveStartScreenX: number = 0;
  private floatPanelMoveStartScreenY: number = 0;
  private floatPanelManualMoving: boolean = false;
  private floatPanelRectChangeCallback: ((options: window.RectChangeOptions) => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      AppLogger.error('Ability', 'Failed to set colorMode. Cause: ' + JSON.stringify(err));
    }
    // AgentExecutionController 统一管理本地/云端 Agent 的执行态、取消态和浮窗同步。
    AgentExecutionController.initialize();
    AgentExecutionController.setFloatWindowSyncHandler(() => {
      this.syncFloatWindow();
    });
    AgentExecutionController.setFloatPanelLayoutHandler((expanded: boolean) => {
      this.layoutFloatPanelWindow(expanded);
    });
    AgentExecutionController.setFloatPanelMoveHandler((phase: string, screenX: number, screenY: number) => {
      this.handleFloatPanelMove(phase, screenX, screenY);
    });
    AgentExecutionController.setCaptureOverlayHandler(async (hidden: boolean): Promise<boolean> => {
      return await this.handleCaptureOverlayVisibility(hidden);
    });
    AgentExecutionController.setReturnToAppHandler(async () => {
      let wantInfo: Want = {
        bundleName: 'com.clawmate.app',
        abilityName: 'EntryAbility'
      };
      try {
        await this.context.startAbility(wantInfo);
      } catch (err) {
        let error = err as Error;
        AppLogger.error('Ability', 'Failed to bring app to foreground. Cause: ' + JSON.stringify(error));
        throw error;
      }
    });
    AppLogger.info('Ability', 'Ability onCreate launchReason=' + String(launchParam.launchReason) +
      ', want=' + this.wantBrief(want));
    ProfileShareLaunchBridge.enqueueWant(want, this.isProfileShareRelatedWant(want, launchParam));
  }

  onDestroy(): void {
    AgentExecutionController.setFloatWindowSyncHandler(null);
    AgentExecutionController.setFloatPanelLayoutHandler(null);
    AgentExecutionController.setFloatPanelMoveHandler(null);
    AgentExecutionController.setCaptureOverlayHandler(null);
    AgentExecutionController.setReturnToAppHandler(null);
    AppLogger.info('Ability', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppLogger.info('Ability', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        AppLogger.error('Ability', 'Failed to load the content. Cause: ' + JSON.stringify(err));
        return;
      }
      AppLogger.info('Ability', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    AppLogger.info('Ability', 'Ability onWindowStageDestroy');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLogger.info('Ability', 'Ability onNewWant launchReason=' + String(launchParam.launchReason) +
      ', want=' + this.wantBrief(want));
    ProfileShareLaunchBridge.enqueueWant(want, this.isProfileShareRelatedWant(want, launchParam));
  }

  private isProfileShareRelatedWant(want: Want, launchParam: AbilityConstant.LaunchParam): boolean {
    return launchParam.launchReason === AbilityConstant.LaunchReason.SHARE ||
    ProfileShareLaunchBridge.isProfileShareLaunchWant(want) ||
    ProfileShareLaunchBridge.isProfileFileOpenWant(want);
  }

  private wantBrief(want: Want): string {
    let parameterKeys = '';
    if (want.parameters !== undefined) {
      parameterKeys = Object.keys(want.parameters).join(',');
    }
    return 'action=' + String(want.action) +
      ', type=' + String(want.type) +
      ', uri=' + String(want.uri) +
      ', parameters=' + parameterKeys;
  }

  onForeground(): void {
    AppLogger.info('Ability', 'Ability onForeground');
    this.destroyFloatWindow();
    try {
      // 当应用回到前台，停止后台长时任务，省电
      backgroundTaskManager.stopBackgroundRunning(this.context).then(() => {
        AppLogger.info('BackgroundTask', 'stopBackgroundRunning succeeded');
      }).catch((err: Error) => {
        AppLogger.warn('BackgroundTask', 'stopBackgroundRunning failed Cause: ' + JSON.stringify(err));
      });
    } catch (err) {
      AppLogger.error('BackgroundTask', 'stopBackgroundRunning error: ' + JSON.stringify(err));
    }
  }

  onBackground(): void {
    AppLogger.info('Ability', 'Ability onBackground');
    this.syncFloatWindow();
    if (!AgentExecutionController.isExecutionActive()) {
      return;
    }
    try {
      // 配置 WantAgent，用于在通知栏显示后台任务并能点击回到应用
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: "com.clawmate.app",
            abilityName: "EntryAbility"
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };

      wantAgent.getWantAgent(wantAgentInfo).then((wantAgentObj) => {
        // 当应用退到后台时，立刻向系统申请数据传输类的长时运行权限
        backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wantAgentObj).then(() => {
          AppLogger.info('BackgroundTask', 'startBackgroundRunning succeeded');
        }).catch((err: Error) => {
          AppLogger.error('BackgroundTask', 'startBackgroundRunning failed Cause: ' + JSON.stringify(err));
        });
      });
    } catch (error) {
      AppLogger.error('BackgroundTask', 'startBackgroundRunning error Cause: ' + JSON.stringify(error));
    }
  }

  private syncFloatWindow(): void {
    // 只有 Agent 正在执行时才保留浮窗；普通后台状态不额外占用屏幕空间。
    if (AgentExecutionController.isExecutionActive()) {
      this.createFloatWindow();
      return;
    }
    this.destroyFloatWindow();
  }

  // 执行期悬浮窗只能展示状态和接收少量控制操作，不能抢走前台业务 App 的焦点。
  // 否则截图前后的焦点切换可能导致软键盘收起/弹出，进而让 Decider 截图和实际点击布局不一致。
  private async configureCaptureSafeWindow(win: window.Window, label: string, touchable: boolean): Promise<void> {
    try {
      // 即使系统临时把浮窗置为焦点窗口，也尽量保留其他窗口创建的软键盘。
      win.keepKeyboardOnFocus(true);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to keep keyboard on focus for ' + label + '. Cause: ' +
        JSON.stringify(err));
    }
    try {
      // 不可获焦是关键：触摸穿透/禁触摸不能替代焦点控制。
      await win.setWindowFocusable(false);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to disable focus for ' + label + '. Cause: ' + JSON.stringify(err));
    }
    try {
      await win.setWindowTouchable(touchable);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to set touchable=' + String(touchable) + ' for ' + label +
        '. Cause: ' + JSON.stringify(err));
    }
  }

  // 截图隐藏阶段只临时禁用小面板触摸；窗口对象保持存在，避免 destroy/create 触发输入法状态变化。
  private async setFloatPanelTouchable(touchable: boolean, context: string): Promise<void> {
    if (!this.floatWindow) {
      return;
    }
    try {
      await this.floatWindow.setWindowTouchable(touchable);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to set float panel touchable during ' + context + '. Cause: ' +
        JSON.stringify(err));
    }
  }

  // 截图前隐藏 overlay 时不销毁窗口：FloatWindow 停止渲染面板内容并禁触，
  // EdgeFlowWindow 同步移除 HDS 流光效果。截图后恢复原窗口，避免软键盘与页面避让区域抖动。
  private async handleCaptureOverlayVisibility(hidden: boolean): Promise<boolean> {
    if (!hidden && !AgentExecutionController.isExecutionActive()) {
      // 任务已结束时只清理渲染状态，不重新创建后台浮窗。
      AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, false);
      return false;
    }
    let transition = captureOverlayWindowTransition(hidden, this.floatWindow !== null,
      this.edgeFlowWindow !== null);
    if (!transition.applied) {
      return false;
    }
    AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, transition.contentHidden);

    if (transition.shouldCreateWindow) {
      // 恢复请求可能发生在面板尚未创建的早期阶段；仍按执行态创建正常小面板。
      this.createFloatPanelWindow();
      return true;
    }
    if (!this.floatWindow) {
      // 流光窗口可能先于小面板完成创建；此时隐藏状态仍已生效，截图可以继续。
      return transition.applied;
    }

    try {
      this.syncFloatPanelWindowRect();
      if (!hidden) {
        // 恢复时保持用户拖动后的锚点和展开态，不改变原有浮窗布局策略。
        this.layoutFloatPanelWindow(AgentExecutionController.isFloatPanelExpanded());
        await this.floatWindow.showWindow();
      }
      await this.setFloatPanelTouchable(transition.windowTouchable, hidden ? 'capture hide' : 'capture restore');
      return true;
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to switch float panel capture state. Cause: ' + JSON.stringify(err));
      return false;
    }
  }

  private getDisplaySize(): DisplaySize {
    try {
      let defaultDisplay = display.getDefaultDisplaySync();
      let density = defaultDisplay.densityPixels > 0 ? defaultDisplay.densityPixels : DEFAULT_DISPLAY_DENSITY;
      return {
        width: defaultDisplay.width,
        height: defaultDisplay.height,
        density: density
      };
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to get display size. Cause: ' + JSON.stringify(err));
    }
    return {
      width: DEFAULT_DISPLAY_WIDTH,
      height: DEFAULT_DISPLAY_HEIGHT,
      density: DEFAULT_DISPLAY_DENSITY
    };
  }

  private createFloatWindow(): void {
    // 后台任务由两层悬浮窗组成：全屏不可触透明流光层 + 可点击的小型状态面板。
    this.createEdgeFlowWindow(() => {
      this.createFloatPanelWindow();
    });
  }

  private createEdgeFlowWindow(onReady: () => void): void {
    if (this.edgeFlowWindow) {
      try {
        this.edgeFlowWindow.showWindow();
      } catch (err) {
        AppLogger.error('FloatWindow', 'Failed to show edge flow window. Cause: ' + JSON.stringify(err));
      }
      onReady();
      return;
    }
    let config: window.Configuration = {
      name: 'ClawMateEdgeFlowWindow',
      windowType: window.WindowType.TYPE_FLOAT,
      ctx: this.context
    };

    window.createWindow(config).then(async (win: window.Window) => {
      this.edgeFlowWindow = win;
      let displaySize = this.getDisplaySize();
      // 浮窗保持真实屏幕大小，流光的贴边压缩由 EdgeFlowWindow 内部的效果层完成。
      win.resize(displaySize.width, displaySize.height);
      win.moveWindowTo(0, 0);
      try {
        win.setWindowBackgroundColor('#00000000');
      } catch (err) {
        AppLogger.error('FloatWindow', 'Failed to configure edge flow window. Cause: ' + JSON.stringify(err));
      }
      // 全屏边缘流光层也必须不可获焦；它不可触摸，但仍可能参与窗口焦点管理。
      await this.configureCaptureSafeWindow(win, 'edge flow window', false);
      win.setUIContent('pages/EdgeFlowWindow', (err) => {
        if (err.code) {
          AppLogger.error('FloatWindow', 'Failed to load edge flow window content. Cause: ' + JSON.stringify(err));
          onReady();
          return;
        }
        win.showWindow();
        try {
          win.setWindowBackgroundColor('#00000000');
        } catch (error) {
          AppLogger.error('FloatWindow', 'Failed to keep edge flow window transparent. Cause: ' + JSON.stringify(error));
        }
        onReady();
        AppLogger.info('FloatWindow', 'Transparent edge flow window created and shown');
      });
    }).catch((err: Error) => {
      AppLogger.error('FloatWindow', 'Failed to create edge flow window. Cause: ' + JSON.stringify(err));
      onReady();
    });
  }

  private createFloatPanelWindow(): void {
    // 小型浮窗只承载实时状态和终止按钮，不负责模型推理或任务调度。
    if (this.floatWindow) {
      this.layoutFloatPanelWindow(AgentExecutionController.isFloatPanelExpanded());
      try {
        this.floatWindow.showWindow();
      } catch (err) {
        AppLogger.error('FloatWindow', 'Failed to show float window. Cause: ' + JSON.stringify(err));
      }
      return;
    }
    let config: window.Configuration = {
      name: 'ClawMateFloatWindow',
      windowType: window.WindowType.TYPE_FLOAT,
      ctx: this.context
    };

    window.createWindow(config).then(async (win: window.Window) => {
      this.floatWindow = win;
      this.registerFloatPanelRectChange(win);
      this.layoutFloatPanelWindow(AgentExecutionController.isFloatPanelExpanded());
      try {
        win.setWindowBackgroundColor('#00000000');
      } catch (err) {
        AppLogger.error('FloatWindow', 'Failed to configure float window background. Cause: ' + JSON.stringify(err));
      }
      // 小型控制面板平时可触摸，但不可获焦；截图期间由 handleCaptureOverlayVisibility 临时禁触。
      await this.configureCaptureSafeWindow(win, 'float panel window', true);
      win.setUIContent('pages/FloatWindow', (err) => {
        if (err.code) {
          AppLogger.error('FloatWindow', 'Failed to load float window content. Cause: ' + JSON.stringify(err));
          return;
        }
        win.showWindow();
        try {
          win.setWindowBackgroundColor('#00000000');
        } catch (error) {
          AppLogger.error('FloatWindow', 'Failed to keep float window transparent. Cause: ' + JSON.stringify(error));
        }
        AppLogger.info('FloatWindow', 'Float window created and shown');
      });
    }).catch((err: Error) => {
      AppLogger.error('FloatWindow', 'Failed to create float window. Cause: ' + JSON.stringify(err));
    });
  }

  private layoutFloatPanelWindow(expanded: boolean): void {
    if (!this.floatWindow) {
      return;
    }
    let displaySize = this.getDisplaySize();
    let panelWidth = expanded ? this.getExpandedFloatPanelWidth(displaySize) :
      this.vpToPx(FLOAT_PANEL_COLLAPSED_WIDTH_VP, displaySize.density);
    let panelHeight = this.vpToPx(FLOAT_PANEL_HEIGHT_VP, displaySize.density);
    this.floatPanelWidth = panelWidth;
    this.floatPanelHeight = panelHeight;
    if (this.floatPanelHasCustomPosition) {
      this.floatPanelX = this.clamp(Math.round(this.floatPanelAnchorCenterX - panelWidth / 2), 0,
        Math.max(0, displaySize.width - panelWidth));
      this.floatPanelY = this.clamp(Math.round(this.floatPanelAnchorCenterY - panelHeight / 2), 0,
        Math.max(0, displaySize.height - panelHeight));
    } else {
      this.floatPanelX = Math.max(0,
        displaySize.width - panelWidth - this.vpToPx(FLOAT_PANEL_RIGHT_MARGIN_VP, displaySize.density));
      this.floatPanelY = Math.max(0,
        displaySize.height - panelHeight - this.vpToPx(FLOAT_PANEL_BOTTOM_MARGIN_VP, displaySize.density));
    }
    try {
      this.floatWindow.resize(panelWidth, panelHeight);
      this.floatWindow.moveWindowTo(this.floatPanelX, this.floatPanelY);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to layout float window. Cause: ' + JSON.stringify(err));
    }
  }

  private getExpandedFloatPanelWidth(displaySize: DisplaySize): number {
    // window.resize 使用物理像素，ArkUI 内部使用 vp。展开态按屏幕比例计算，
    // 同时保留左右安全边距，避免全屏覆盖和固定宽度在不同设备上裁切。
    let collapsedWidth = this.vpToPx(FLOAT_PANEL_COLLAPSED_WIDTH_VP, displaySize.density);
    let safeMargin = this.vpToPx(FLOAT_PANEL_EXPANDED_SAFE_MARGIN_VP, displaySize.density);
    let availableWidth = Math.max(collapsedWidth, displaySize.width - safeMargin * 2);
    let minWidth = Math.min(this.vpToPx(FLOAT_PANEL_EXPANDED_MIN_WIDTH_VP, displaySize.density), availableWidth);
    let preferredWidth = Math.round(displaySize.width * FLOAT_PANEL_EXPANDED_WIDTH_RATIO);
    return Math.min(Math.max(preferredWidth, minWidth), availableWidth);
  }

  private handleFloatPanelMove(phase: string, screenX: number, screenY: number): void {
    if (!this.floatWindow) {
      return;
    }
    if (phase === 'start') {
      this.captureFloatPanelMoveStart();
      this.floatPanelMoveStartScreenX = screenX;
      this.floatPanelMoveStartScreenY = screenY;
      this.floatPanelManualMoving = true;
      // 小浮窗保持 setWindowFocusable(false) 以不抢前台输入法焦点，因此不能依赖 startMoving。
      // 拖动改为 TouchType.Move 中手动 moveWindowTo，保留键盘稳定性和拖动能力。
      return;
    }
    if (phase === 'move') {
      this.moveFloatPanelByTouch(screenX, screenY);
      return;
    }
    this.floatPanelManualMoving = false;
    this.syncFloatPanelWindowRect();
    if (this.hasFloatPanelMoved()) {
      this.floatPanelHasCustomPosition = true;
      this.updateFloatPanelAnchorFromCurrentRect();
    }
  }

  private moveFloatPanelByTouch(screenX: number, screenY: number): void {
    if (!this.floatWindow || !this.floatPanelManualMoving) {
      return;
    }
    let displaySize = this.getDisplaySize();
    let moved: FloatPanelManualMoveRect = resolveFloatPanelManualMoveRect({
      startLeft: this.floatPanelMoveStartX,
      startTop: this.floatPanelMoveStartY,
      width: this.floatPanelMoveStartWidth,
      height: this.floatPanelMoveStartHeight,
      startScreenX: this.floatPanelMoveStartScreenX,
      startScreenY: this.floatPanelMoveStartScreenY,
      currentScreenX: screenX,
      currentScreenY: screenY,
      touchScale: displaySize.density,
      displayWidth: displaySize.width,
      displayHeight: displaySize.height
    });
    try {
      this.floatWindow.moveWindowTo(moved.left, moved.top);
      this.floatPanelX = moved.left;
      this.floatPanelY = moved.top;
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to move float window manually. Cause: ' + JSON.stringify(err));
    }
  }

  private syncFloatPanelWindowRect(): void {
    if (!this.floatWindow) {
      return;
    }
    try {
      let rect = this.floatWindow.getWindowProperties().windowRect;
      this.floatPanelX = rect.left;
      this.floatPanelY = rect.top;
      this.floatPanelWidth = rect.width;
      this.floatPanelHeight = rect.height;
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to sync float window rect. Cause: ' + JSON.stringify(err));
    }
  }

  private registerFloatPanelRectChange(win: window.Window): void {
    if (this.floatPanelRectChangeCallback) {
      return;
    }
    this.floatPanelRectChangeCallback = (options: window.RectChangeOptions) => {
      this.floatPanelX = options.rect.left;
      this.floatPanelY = options.rect.top;
      this.floatPanelWidth = options.rect.width;
      this.floatPanelHeight = options.rect.height;
    };
    try {
      win.on('windowRectChange', this.floatPanelRectChangeCallback);
    } catch (err) {
      this.floatPanelRectChangeCallback = null;
      AppLogger.error('FloatWindow', 'Failed to watch float window rect. Cause: ' + JSON.stringify(err));
    }
  }

  private unregisterFloatPanelRectChange(): void {
    if (!this.floatWindow || !this.floatPanelRectChangeCallback) {
      return;
    }
    try {
      this.floatWindow.off('windowRectChange', this.floatPanelRectChangeCallback);
    } catch (err) {
      AppLogger.error('FloatWindow', 'Failed to unwatch float window rect. Cause: ' + JSON.stringify(err));
    }
    this.floatPanelRectChangeCallback = null;
  }

  private captureFloatPanelMoveStart(): void {
    this.syncFloatPanelWindowRect();
    this.floatPanelMoveStartX = this.floatPanelX;
    this.floatPanelMoveStartY = this.floatPanelY;
    this.floatPanelMoveStartWidth = this.floatPanelWidth;
    this.floatPanelMoveStartHeight = this.floatPanelHeight;
  }

  private hasFloatPanelMoved(): boolean {
    let sizeChanged = Math.abs(this.floatPanelWidth - this.floatPanelMoveStartWidth) > FLOAT_PANEL_MOVE_THRESHOLD_PX ||
      Math.abs(this.floatPanelHeight - this.floatPanelMoveStartHeight) > FLOAT_PANEL_MOVE_THRESHOLD_PX;
    if (sizeChanged) {
      return false;
    }
    let offsetX = Math.abs(this.floatPanelX - this.floatPanelMoveStartX);
    let offsetY = Math.abs(this.floatPanelY - this.floatPanelMoveStartY);
    return offsetX > FLOAT_PANEL_MOVE_THRESHOLD_PX || offsetY > FLOAT_PANEL_MOVE_THRESHOLD_PX;
  }

  private updateFloatPanelAnchorFromCurrentRect(): void {
    this.floatPanelAnchorCenterX = this.floatPanelX + this.floatPanelWidth / 2;
    this.floatPanelAnchorCenterY = this.floatPanelY + this.floatPanelHeight / 2;
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.min(Math.max(value, min), max);
  }

  private vpToPx(value: number, density: number): number {
    return Math.round(value * density);
  }

  private destroyFloatWindow() {
    // 回到前台或任务结束后销毁浮窗，防止遮挡主界面。
    if (this.floatWindow) {
      this.unregisterFloatPanelRectChange();
      this.floatWindow.destroyWindow().then(() => {
        AppLogger.info('FloatWindow', 'Float window destroyed');
        this.floatWindow = null;
      }).catch((err: Error) => {
        AppLogger.error('FloatWindow', 'Failed to destroy float window. Cause: ' + JSON.stringify(err));
      });
    }
    if (this.edgeFlowWindow) {
      this.edgeFlowWindow.destroyWindow().then(() => {
        AppLogger.info('FloatWindow', 'Edge flow window destroyed');
        this.edgeFlowWindow = null;
      }).catch((err: Error) => {
        AppLogger.error('FloatWindow', 'Failed to destroy edge flow window. Cause: ' + JSON.stringify(err));
      });
    }
  }
}
