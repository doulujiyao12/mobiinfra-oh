import { common } from '@kit.AbilityKit';
import { AgentExecutionController } from '../AgentExecutionController';
import { PhoneHdcWorkflowBridge } from './PhoneHdcWorkflowBridge';
import { SelfHdcTaskSettings } from './SelfHdcTaskSettings';
import { SelfHdcTestRunner } from './SelfHdcTestRunner';
import { phoneAgentLogText } from './PhoneAgentPolicy';
import { DebugSettings } from '../DebugSettings';

// Shared lifecycle for chat Agent loops and chat GUI tools. The actual device backend is also used by task workflows.
export class PhoneHdcRunSession {
  private context: common.UIAbilityContext;
  private runMode: string;
  private cancelExecution: () => Promise<void>;
  private bridge: PhoneHdcWorkflowBridge | null = null;
  private ownsLog: boolean = false;
  private cancelled: boolean = false;
  private executionStarted: boolean = false;
  private cancelPromise: Promise<void> | null = null;
  private outcome: string = 'success';
  private message: string = '任务执行完成';

  constructor(context: common.UIAbilityContext, runMode: string, cancelExecution: () => Promise<void>) {
    this.context = context; this.runMode = runMode; this.cancelExecution = cancelExecution;
  }

  record(message: string): void {
    if (!this.ownsLog || !DebugSettings.isEnabled()) { return; }
    message = phoneAgentLogText(message);
    let hub = SelfHdcTestRunner.shared();
    if (message.length <= 6000) { hub.recordExternal(message); return; }
    let parts = Math.ceil(message.length / 5500);
    for (let index = 0; index < parts; index++) {
      hub.recordExternal('AGENT_LOG_PART ' + (index + 1) + '/' + parts + '\n' + message.substring(index * 5500, (index + 1) * 5500));
    }
  }

  setResult(outcome: string, message: string): void { this.outcome = outcome; this.message = message; }

  private checkStopped(): void {
    if (this.bridge?.hasExpired()) { throw new Error('PHONE_HDC_BACKGROUND_EXPIRED: 系统后台额度已到期'); }
    if (this.cancelled || AgentExecutionController.isCancelRequested()) {
      throw new Error('PHONE_HDC_CANCELLED: 手机任务已停止');
    }
  }

  async requestCancellation(): Promise<void> {
    if (!this.ownsLog) { return; }
    this.cancelled = true;
    this.bridge?.cancel();
    // The controller invokes both registered handlers; native cleanup must only be requested once.
    if (this.cancelPromise === null) { this.cancelPromise = this.cancelOnce(); }
    await this.cancelPromise;
  }

  private async cancelOnce(): Promise<void> {
    this.record('CANCEL phone session; stop HDC immediately and wait for model cleanup before releasing busy state');
    AgentExecutionController.returnToApp();
    if (this.executionStarted) { await this.cancelExecution(); }
  }

  async run<T>(title: string, execute: (bridge: PhoneHdcWorkflowBridge) => Promise<T>,
    prepare: () => Promise<void> = async (): Promise<void> => {}, returnOnSuccess: boolean = true): Promise<T> {
    let hub = SelfHdcTestRunner.shared();
    hub.initialize(this.context.filesDir);
    if (hub.snapshot().running || AgentExecutionController.isExecutionActive()) {
      throw new Error('PHONE_HDC_BUSY: 已有手机测试或 GUI 任务正在执行');
    }
    try {
      this.ownsLog = true;
      hub.beginExternal(this.context.filesDir, title, '', (): void => {
        AgentExecutionController.requestCancellation();
      }, this.runMode);
      AgentExecutionController.beginExecution(title + ' · 手机自控准备中');
      let settings = await SelfHdcTaskSettings.refreshLocalIp(this.context.filesDir, this.runMode);
      hub.setExternalEndpoint(settings.ip + ':' + settings.port);
      this.record('CONNECTION ipMode=' + (settings.autoIp ? 'auto-wifi' : 'manual') + ' ip=' + settings.ip +
        ' port=' + settings.port + ' portSource=manual; settings=我的 → 手机 HDC');
      this.record('IP_STATUS ' + (AppStorage.get<string>('selfHdcIpStatus') || '未读取检测状态'));
      this.checkStopped();
      this.record('STAGE_BEGIN model-preparation');
      // Load a local model before requesting the limited background quota.
      await prepare();
      this.checkStopped();
      this.record('STAGE_BEGIN HDC-connect');
      this.bridge = new PhoneHdcWorkflowBridge(this.context, settings, (message: string): void => { this.record(message); },
        (): void => { AgentExecutionController.requestCancellation(); });
      await this.bridge.open();
      this.checkStopped();
      this.record('STAGE_BEGIN agent-execution mode=' + this.runMode);
      this.executionStarted = true;
      let result = await execute(this.bridge);
      this.checkStopped();
      return result;
    } catch (e) {
      let error = e as Error;
      this.outcome = this.bridge?.hasExpired() ? 'failed' : (this.cancelled ? 'cancelled' : 'failed');
      this.message = error.message;
      this.record('PHONE_RUN_FAILED outcome=' + this.outcome + ' error=' + error.message);
      throw error;
    } finally {
      try {
        if (this.cancelPromise !== null) { await this.cancelPromise; }
      } catch (e) { this.record('CANCEL_CLEANUP_FAILED ' + (e as Error).message); }
      if (this.bridge && (returnOnSuccess || this.outcome !== 'success')) {
        try { await this.bridge.returnHost(); }
        catch (e) { this.record('RETURN_APP_FAILED ' + (e as Error).message + '；请手动返回 App'); }
      }
      this.bridge?.close();
      this.bridge = null;
      AgentExecutionController.finishExecution('手机执行 ' + this.outcome);
      try { hub.finishExternal(this.outcome, this.message); }
      finally { this.ownsLog = false; }
    }
  }
}
