import { AppLogger } from './AppLogger';
import { PrivacyConsent } from './PrivacyConsent';
import { CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY } from './CaptureOverlayPolicy';

type CancelHandler = () => Promise<void>;
type VoidHandler = () => void;
type ReturnToAppHandler = () => Promise<void>;
type FloatPanelLayoutHandler = (expanded: boolean) => void;
type FloatPanelMoveHandler = (phase: string, screenX: number, screenY: number) => void;
type CaptureOverlayHandler = (hidden: boolean) => Promise<boolean>;

const PAUSE_POLL_INTERVAL_MS = 200;
const DEFAULT_FLOAT_TEXT = 'AI Agent running...';
const MAX_FLOAT_LOG_CHARS = 6000;
const FLOAT_STREAM_INTERVAL_MS = 18;
const FLOAT_STREAM_POST_STATUS_DELAY_MS = 500;
const FLOAT_STREAM_IDLE_STATUS = 'AI Agent running...';
const CANCEL_RETURN_TEARDOWN_DELAY_MS = 350;
const CANCEL_RETURN_TEARDOWN_TIMEOUT_MS = 1200;

export class AgentExecutionController {
  private static executionActive: boolean = false;
  private static cancelRequested: boolean = false;
  private static pauseRequested: boolean = false;
  private static floatPanelExpanded: boolean = false;
  private static localCancelHandler: CancelHandler | null = null;
  private static cloudCancelHandler: CancelHandler | null = null;
  private static floatWindowSyncHandler: VoidHandler | null = null;
  private static floatPanelLayoutHandler: FloatPanelLayoutHandler | null = null;
  private static floatPanelMoveHandler: FloatPanelMoveHandler | null = null;
  private static returnToAppHandler: ReturnToAppHandler | null = null;
  private static captureOverlayHandler: CaptureOverlayHandler | null = null;
  private static captureOverlayHideDepth: number = 0;
  private static captureOverlayHidden: boolean = false;
  private static streamDisplayText: string = '';
  private static streamDisplayPrefix: string = '';
  private static streamTargetText: string = '';
  private static streamTimerId: number = -1;
  private static pendingStreamStatusText: string = '';
  private static streamStatusTimerId: number = -1;

  private static warn(message: string, err: Error): void {
    AppLogger.warnCause('AgentExecution', message, err);
  }

  static initialize(): void {
    AppStorage.setOrCreate('floatText', 'AI Agent 运行中...');
    AppStorage.setOrCreate('floatTextLog', 'AI Agent 运行中...');
    AppStorage.setOrCreate('floatTextLatestFull', 'AI Agent 运行中...');
    AppStorage.setOrCreate('agentExecutionActive', false);
    AppStorage.setOrCreate('agentCancelRequested', false);
    AppStorage.setOrCreate('agentPauseRequested', false);
    AppStorage.setOrCreate('agentFloatPanelExpanded', false);
    // 截图隐藏态必须从 false 启动，避免 Ability 重建后 FloatWindow 长期透明。
    AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, false);
  }

  static isExecutionActive(): boolean {
    return AgentExecutionController.executionActive;
  }

  static isCancelRequested(): boolean {
    return AgentExecutionController.cancelRequested;
  }

  static isPauseRequested(): boolean {
    return AgentExecutionController.pauseRequested;
  }

  static isFloatPanelExpanded(): boolean {
    return AgentExecutionController.floatPanelExpanded;
  }

  static beginExecution(text: string = 'AI Agent running...'): void {
    PrivacyConsent.requireAccepted();
    AgentExecutionController.executionActive = true;
    AgentExecutionController.cancelRequested = false;
    AgentExecutionController.pauseRequested = false;
    AgentExecutionController.floatPanelExpanded = false;
    AppStorage.setOrCreate('agentExecutionActive', true);
    AppStorage.setOrCreate('agentCancelRequested', false);
    AppStorage.setOrCreate('agentPauseRequested', false);
    AppStorage.setOrCreate('agentFloatPanelExpanded', false);
    // 每次任务开始都恢复小面板内容，清理上一轮异常中断遗留的截图隐藏态。
    AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, false);
    AgentExecutionController.resetStreamDisplay();
    AgentExecutionController.writeFloatText(text, true, false);
    AgentExecutionController.notifyFloatWindowSync();
  }

  static updateFloatText(text: string): void {
    let normalized = AgentExecutionController.normalizeFloatText(text);
    if (AgentExecutionController.shouldDeferIdleStatus(normalized)) {
      AgentExecutionController.pendingStreamStatusText = normalized;
      if (AgentExecutionController.streamDisplayText.length >= AgentExecutionController.streamTargetText.length) {
        AgentExecutionController.schedulePendingStreamStatus();
      }
      return;
    }
    AgentExecutionController.resetStreamDisplay();
    AgentExecutionController.writeFloatText(text, false, false);
  }

  static replaceFloatText(text: string): void {
    AgentExecutionController.clearPendingStreamStatus();
    AgentExecutionController.writeFloatText(text, false, true, true);
  }

  static finishExecution(text: string = 'AI Agent running...'): void {
    AgentExecutionController.executionActive = false;
    AgentExecutionController.cancelRequested = false;
    AgentExecutionController.pauseRequested = false;
    AgentExecutionController.floatPanelExpanded = false;
    AgentExecutionController.captureOverlayHideDepth = 0;
    AgentExecutionController.captureOverlayHidden = false;
    AppStorage.setOrCreate('agentExecutionActive', false);
    AppStorage.setOrCreate('agentCancelRequested', false);
    AppStorage.setOrCreate('agentPauseRequested', false);
    AppStorage.setOrCreate('agentFloatPanelExpanded', false);
    // 任务结束后不保留截图隐藏态；后续重新创建浮窗时应显示正常面板。
    AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, false);
    AgentExecutionController.resetStreamDisplay();
    AgentExecutionController.writeFloatText(text, false, false);
    AgentExecutionController.notifyFloatWindowSync();
  }

  static requestCancellation(): void {
    AgentExecutionController.cancelRequested = true;
    AgentExecutionController.pauseRequested = false;
    AgentExecutionController.floatPanelExpanded = false;
    AgentExecutionController.captureOverlayHideDepth = 0;
    AgentExecutionController.captureOverlayHidden = false;
    AgentExecutionController.resetStreamDisplay();
    AppStorage.setOrCreate('agentCancelRequested', true);
    AppStorage.setOrCreate('agentPauseRequested', false);
    AppStorage.setOrCreate('agentFloatPanelExpanded', false);
    // 用户取消可能发生在截图 finally 前，主动恢复渲染状态避免悬浮窗残留透明。
    AppStorage.setOrCreate(CAPTURE_OVERLAY_HIDDEN_STORAGE_KEY, false);
    AgentExecutionController.writeFloatText('正在终止任务并返回 App...', false, false);

    AgentExecutionController.invokeCancelHandler(AgentExecutionController.localCancelHandler,
      'local cancel handler failed');
    AgentExecutionController.invokeCancelHandler(AgentExecutionController.cloudCancelHandler,
      'cloud cancel handler failed');

    AgentExecutionController.scheduleCancellationTeardown(AgentExecutionController.invokeReturnToAppHandler());
  }

  static togglePause(): void {
    if (!AgentExecutionController.executionActive) {
      return;
    }
    AgentExecutionController.pauseRequested = !AgentExecutionController.pauseRequested;
    AppStorage.setOrCreate('agentPauseRequested', AgentExecutionController.pauseRequested);
  }

  static resumeExecution(): void {
    AgentExecutionController.pauseRequested = false;
    AppStorage.setOrCreate('agentPauseRequested', false);
  }

  static toggleFloatPanelExpanded(): void {
    AgentExecutionController.floatPanelExpanded = !AgentExecutionController.floatPanelExpanded;
    AppStorage.setOrCreate('agentFloatPanelExpanded', AgentExecutionController.floatPanelExpanded);
    AgentExecutionController.notifyFloatPanelLayout();
  }

  static setFloatPanelExpanded(expanded: boolean): void {
    AgentExecutionController.floatPanelExpanded = expanded;
    AppStorage.setOrCreate('agentFloatPanelExpanded', expanded);
    AgentExecutionController.notifyFloatPanelLayout();
  }

  static async waitIfPaused(): Promise<void> {
    while (AgentExecutionController.pauseRequested && AgentExecutionController.executionActive &&
      !AgentExecutionController.cancelRequested) {
      await AgentExecutionController.sleep(PAUSE_POLL_INTERVAL_MS);
    }
  }

  static registerLocalCancelHandler(handler: CancelHandler | null): void {
    AgentExecutionController.localCancelHandler = handler;
  }

  static registerCloudCancelHandler(handler: CancelHandler | null): void {
    AgentExecutionController.cloudCancelHandler = handler;
  }

  static setFloatWindowSyncHandler(handler: VoidHandler | null): void {
    AgentExecutionController.floatWindowSyncHandler = handler;
  }

  static setFloatPanelLayoutHandler(handler: FloatPanelLayoutHandler | null): void {
    AgentExecutionController.floatPanelLayoutHandler = handler;
  }

  static setFloatPanelMoveHandler(handler: FloatPanelMoveHandler | null): void {
    AgentExecutionController.floatPanelMoveHandler = handler;
  }

  static startFloatPanelMove(screenX: number, screenY: number): void {
    AgentExecutionController.notifyFloatPanelMove('start', screenX, screenY);
  }

  static moveFloatPanel(screenX: number, screenY: number): void {
    AgentExecutionController.notifyFloatPanelMove('move', screenX, screenY);
  }

  static endFloatPanelMove(): void {
    AgentExecutionController.notifyFloatPanelMove('end', 0, 0);
  }

  static setReturnToAppHandler(handler: ReturnToAppHandler | null): void {
    AgentExecutionController.returnToAppHandler = handler;
  }

  static setCaptureOverlayHandler(handler: CaptureOverlayHandler | null): void {
    AgentExecutionController.captureOverlayHandler = handler;
  }

  static async hideCaptureOverlay(): Promise<boolean> {
    if (!AgentExecutionController.executionActive) {
      return false;
    }
    AgentExecutionController.captureOverlayHideDepth += 1;
    if (AgentExecutionController.captureOverlayHidden) {
      return false;
    }
    if (!AgentExecutionController.captureOverlayHandler) {
      return false;
    }
    try {
      let hidden = await AgentExecutionController.captureOverlayHandler(true);
      AgentExecutionController.captureOverlayHidden = hidden;
      return hidden;
    } catch (e) {
      AgentExecutionController.warn('capture overlay hide failed', e as Error);
      return false;
    }
  }

  static async restoreCaptureOverlay(token: boolean): Promise<void> {
    void token;
    if (AgentExecutionController.captureOverlayHideDepth > 0) {
      AgentExecutionController.captureOverlayHideDepth -= 1;
    }
    if (AgentExecutionController.captureOverlayHideDepth > 0) {
      return;
    }
    if (!AgentExecutionController.captureOverlayHidden) {
      return;
    }
    AgentExecutionController.captureOverlayHidden = false;
    if (!AgentExecutionController.captureOverlayHandler) {
      return;
    }
    try {
      await AgentExecutionController.captureOverlayHandler(false);
    } catch (e) {
      AgentExecutionController.warn('capture overlay restore failed', e as Error);
    }
  }

  static returnToApp(): boolean {
    let handler = AgentExecutionController.returnToAppHandler;
    if (!handler) {
      return false;
    }
    try {
      handler().catch((e: Error) => {
        AgentExecutionController.warn('return-to-app handler failed', e);
      });
      return true;
    } catch (e) {
      AgentExecutionController.warn('return-to-app handler failed', e as Error);
      return false;
    }
  }

  private static invokeReturnToAppHandler(): Promise<void> {
    let handler = AgentExecutionController.returnToAppHandler;
    if (!handler) {
      return Promise.resolve();
    }
    try {
      return handler();
    } catch (e) {
      AgentExecutionController.warn('return-to-app handler failed', e as Error);
    }
    return Promise.resolve();
  }

  private static invokeCancelHandler(handler: CancelHandler | null, warnMessage: string): void {
    if (!handler) {
      return;
    }
    try {
      handler().catch((e: Error) => {
        AgentExecutionController.warn(warnMessage, e);
      });
    } catch (e) {
      AgentExecutionController.warn(warnMessage, e as Error);
    }
  }

  private static scheduleCancellationTeardown(returnPromise: Promise<void>): void {
    let completed = false;
    let teardown = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      setTimeout(() => {
        AgentExecutionController.executionActive = false;
        AppStorage.setOrCreate('agentExecutionActive', false);
        AgentExecutionController.notifyFloatWindowSync();
      }, CANCEL_RETURN_TEARDOWN_DELAY_MS);
    };
    returnPromise.then(() => {
      teardown();
    }).catch((e: Error) => {
      AgentExecutionController.warn('return-to-app handler failed', e);
      teardown();
    });
    setTimeout(() => {
      teardown();
    }, CANCEL_RETURN_TEARDOWN_TIMEOUT_MS);
  }

  private static notifyFloatWindowSync(): void {
    try {
      AgentExecutionController.floatWindowSyncHandler?.();
    } catch (e) {
      AgentExecutionController.warn('float window sync handler failed', e as Error);
    }
  }

  private static notifyFloatPanelLayout(): void {
    try {
      AgentExecutionController.floatPanelLayoutHandler?.(AgentExecutionController.floatPanelExpanded);
    } catch (e) {
      AgentExecutionController.warn('float panel layout handler failed', e as Error);
    }
  }

  private static notifyFloatPanelMove(phase: string, screenX: number, screenY: number): void {
    try {
      AgentExecutionController.floatPanelMoveHandler?.(phase, screenX, screenY);
    } catch (e) {
      AgentExecutionController.warn('float panel move handler failed', e as Error);
    }
  }

  private static writeFloatText(text: string, resetLog: boolean, replaceLatest: boolean,
    animateDisplay: boolean = false): void {
    let normalized = AgentExecutionController.normalizeFloatText(text);
    let previousLatest = AgentExecutionController.getStorageString('floatTextLatestFull');
    let previousLog = resetLog ? '' : AgentExecutionController.getStorageString('floatTextLog');
    let nextLog = normalized;
    if (!resetLog && previousLog.length > 0) {
      let replacedLog = replaceLatest && previousLatest.length > 0 ?
        AgentExecutionController.tryReplaceLatestLog(previousLog, previousLatest, normalized) : '';
      if (replacedLog.length > 0) {
        nextLog = replacedLog;
      } else if (AgentExecutionController.logEndsWithEntry(previousLog, normalized)) {
        nextLog = previousLog;
      } else {
        nextLog = previousLog + '\n\n' + normalized;
      }
    }
    AppStorage.setOrCreate('floatTextLatestFull', normalized);
    AppStorage.setOrCreate('floatTextLog', AgentExecutionController.limitFloatLog(nextLog));
    if (animateDisplay) {
      AgentExecutionController.updateStreamingTarget(normalized,
        AgentExecutionController.currentLogPrefix(nextLog, normalized));
      return;
    }
    AppStorage.setOrCreate('floatText', normalized);
  }

  private static normalizeFloatText(text: string): string {
    let normalized = text.trim();
    return normalized.length > 0 ? normalized : DEFAULT_FLOAT_TEXT;
  }

  private static limitFloatLog(text: string): string {
    if (text.length <= MAX_FLOAT_LOG_CHARS) {
      return text;
    }
    return text.substring(text.length - MAX_FLOAT_LOG_CHARS);
  }

  private static currentLogPrefix(nextLog: string, latestText: string): string {
    if (latestText.length > 0 && nextLog.endsWith(latestText)) {
      return nextLog.substring(0, nextLog.length - latestText.length);
    }
    return '';
  }

  private static updateStreamingTarget(targetText: string, displayPrefix: string): void {
    if (targetText.indexOf(AgentExecutionController.streamDisplayText) !== 0) {
      AgentExecutionController.streamDisplayText = '';
    }
    AgentExecutionController.streamDisplayPrefix = displayPrefix;
    AgentExecutionController.streamTargetText = targetText;
    if (AgentExecutionController.streamTimerId === -1) {
      AgentExecutionController.tickStreamingDisplay();
    }
    AgentExecutionController.ensureStreamTimer();
  }

  private static tickStreamingDisplay(): void {
    if (AgentExecutionController.streamDisplayText.length < AgentExecutionController.streamTargetText.length) {
      let nextLength = AgentExecutionController.streamDisplayText.length + 1;
      AgentExecutionController.streamDisplayText = AgentExecutionController.streamTargetText.substring(0, nextLength);
      AppStorage.setOrCreate('floatText', AgentExecutionController.limitFloatLog(
        AgentExecutionController.streamDisplayPrefix + AgentExecutionController.streamDisplayText));
    }
    if (AgentExecutionController.streamDisplayText.length >= AgentExecutionController.streamTargetText.length) {
      AgentExecutionController.stopStreamTimer();
      AgentExecutionController.schedulePendingStreamStatus();
    }
  }

  private static ensureStreamTimer(): void {
    if (AgentExecutionController.streamTimerId !== -1) {
      return;
    }
    if (AgentExecutionController.streamDisplayText.length >= AgentExecutionController.streamTargetText.length) {
      return;
    }
    AgentExecutionController.streamTimerId = setInterval(() => {
      AgentExecutionController.tickStreamingDisplay();
    }, FLOAT_STREAM_INTERVAL_MS);
  }

  private static shouldDeferIdleStatus(text: string): boolean {
    return text === FLOAT_STREAM_IDLE_STATUS && AgentExecutionController.streamTargetText.length > 0;
  }

  private static schedulePendingStreamStatus(): void {
    if (AgentExecutionController.pendingStreamStatusText.length === 0 ||
      AgentExecutionController.streamStatusTimerId !== -1) {
      return;
    }
    let statusText = AgentExecutionController.pendingStreamStatusText;
    AgentExecutionController.pendingStreamStatusText = '';
    AgentExecutionController.streamStatusTimerId = setTimeout(() => {
      AgentExecutionController.streamStatusTimerId = -1;
      AgentExecutionController.resetStreamDisplay();
      AgentExecutionController.writeFloatText(statusText, false, false);
    }, FLOAT_STREAM_POST_STATUS_DELAY_MS);
  }

  private static clearPendingStreamStatus(): void {
    AgentExecutionController.pendingStreamStatusText = '';
    if (AgentExecutionController.streamStatusTimerId !== -1) {
      clearTimeout(AgentExecutionController.streamStatusTimerId);
      AgentExecutionController.streamStatusTimerId = -1;
    }
  }

  private static resetStreamDisplay(): void {
    AgentExecutionController.stopStreamTimer();
    AgentExecutionController.clearPendingStreamStatus();
    AgentExecutionController.streamDisplayText = '';
    AgentExecutionController.streamDisplayPrefix = '';
    AgentExecutionController.streamTargetText = '';
  }

  private static stopStreamTimer(): void {
    if (AgentExecutionController.streamTimerId !== -1) {
      clearInterval(AgentExecutionController.streamTimerId);
      AgentExecutionController.streamTimerId = -1;
    }
  }

  private static logEndsWithEntry(logText: string, entry: string): boolean {
    return logText === entry || logText.endsWith('\n\n' + entry);
  }

  private static tryReplaceLatestLog(logText: string, previousLatest: string, nextLatest: string): string {
    if (logText.endsWith(previousLatest)) {
      return logText.substring(0, logText.length - previousLatest.length) + nextLatest;
    }
    let previousLatestTail = AgentExecutionController.limitFloatLog(previousLatest);
    if (previousLatestTail.length > 0 && logText.endsWith(previousLatestTail)) {
      return logText.substring(0, logText.length - previousLatestTail.length) + nextLatest;
    }
    return '';
  }

  private static getStorageString(key: string): string {
    let value: Object | string | number | boolean | null =
      AppStorage.get(key) as Object | string | number | boolean | null;
    return typeof value === 'string' ? value : '';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
