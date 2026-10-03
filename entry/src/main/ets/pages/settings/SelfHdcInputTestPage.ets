import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { showToastSafely } from '../../utils/PromptSafe';
import { AgentExecutionController } from '../../utils/AgentExecutionController';
import { WorkflowJsonMap } from '../../utils/WorkflowTypes';
import { SelfHdcTaskSettings } from '../../utils/selfhdc/SelfHdcTaskSettings';
import { SelfHdcTestRunner } from '../../utils/selfhdc/SelfHdcTestRunner';
import { PhoneHdcWorkflowBridge } from '../../utils/selfhdc/PhoneHdcWorkflowBridge';
import { SelfHdcSetupGuard } from '../../utils/selfhdc/SelfHdcSetupGuard';

interface InputProbePayload {
  action: string;
  x?: number;
  y?: number;
  text?: string;
  target_element?: string;
  submit_enter?: boolean;
  key?: string;
}

@Entry
@Component
struct SelfHdcInputTestPage {
  @State private text: string = 'existing-text';
  @State private running: boolean = false;
  @State private result: string = '先点击测试输入框一次校准坐标，再开始测试。';
  @State private pointText: string = '尚未校准';
  private x: number = -1;
  private y: number = -1;
  private clicks: number = 0;
  private submits: number = 0;
  private cancelled: boolean = false;
  private bridge: PhoneHdcWorkflowBridge | null = null;

  aboutToDisappear(): void { if (this.running) { this.stop(); } }

  private stop(): void {
    this.cancelled = true;
    this.bridge?.cancel();
  }

  private async waitFor(check: () => boolean, label: string): Promise<void> {
    let deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      if (this.cancelled) { throw new Error('PHONE_HDC_CANCELLED: 输入验证已停止'); }
      if (check()) { SelfHdcTestRunner.shared().recordExternal('INPUT_ASSERT ' + label + ' PASS'); return; }
      await new Promise<void>((resolve): void => { setTimeout(resolve, 100); });
    }
    throw new Error('PHONE_HDC_INPUT_ASSERT: ' + label + '；HDC 返回成功但控件未产生预期变化');
  }

  private async action(payload: InputProbePayload): Promise<void> {
    if (!this.bridge) { throw new Error('No phone bridge'); }
    await this.bridge.guiAction(payload as Object as WorkflowJsonMap);
  }

  private async run(): Promise<void> {
    let hub = SelfHdcTestRunner.shared();
    if (this.x < 0 || this.y < 0) { showToastSafely('请先点测试输入框校准坐标', 2000); return; }
    if (hub.snapshot().running || AgentExecutionController.isExecutionActive()) {
      showToastSafely('请先结束已有任务或测试', 2000); return;
    }
    if (!await SelfHdcSetupGuard.ensure(this.getUIContext(),
      (getContext(this) as common.UIAbilityContext).filesDir, 'input-diagnostic-start', false)) { return; }
    if (hub.snapshot().running || AgentExecutionController.isExecutionActive()) {
      showToastSafely('请先结束已有任务或测试', 2000); return;
    }
    let x = this.x; let y = this.y;
    let ownsLog = false; let overlayToken = false;
    this.running = true; this.cancelled = false; this.result = '正在验证…';
    this.text = 'existing-text';
    try {
      let context = getContext(this) as common.UIAbilityContext;
      let settings = new SelfHdcTaskSettings();
      let settingsError = '';
      try { settings = await SelfHdcTaskSettings.refreshLocalIp(context.filesDir, 'input-diagnostic'); }
      catch (e) { settingsError = (e as Error).message; }
      if (hub.snapshot().running || AgentExecutionController.isExecutionActive()) { throw new Error('已有任务或测试正在执行'); }
      hub.beginExternal(context.filesDir, '输入能力诊断', settings.ip + ':' + settings.port, (): void => { this.stop(); });
      ownsLog = true;
      if (settingsError) { throw new Error('PHONE_HDC_SETTINGS: ' + settingsError); }
      if (this.cancelled) { throw new Error('PHONE_HDC_CANCELLED: 输入验证已停止'); }
      overlayToken = await AgentExecutionController.hideCaptureOverlay();
      if (this.cancelled) { throw new Error('PHONE_HDC_CANCELLED: 输入验证已停止'); }
      this.bridge = new PhoneHdcWorkflowBridge(context, settings, (event: string): void => { hub.recordExternal(event); },
        (): void => {}, false);
      await this.bridge.open();
      hub.recordExternal('INPUT_PROBE calibrated physicalPoint=' + x + ',' + y);
      let previousClicks = this.clicks;
      await this.action({ action: 'click', x: x, y: y, target_element: '测试输入框' });
      await this.waitFor((): boolean => this.clicks > previousClicks, 'HDC click reached test field');
      await this.action({ action: 'click_input', x: x, y: y, text: 'SELF_HDC_INPUT_A', submit_enter: false });
      await this.waitFor((): boolean => this.text === 'SELF_HDC_INPUT_A', 'activate and replace ASCII input');
      let expected = '手机 HDC A\'B "C" $() ; & \\ 中文🙂';
      await this.action({ action: 'input', text: expected, submit_enter: false });
      await this.waitFor((): boolean => this.text === expected, 'remember focus, replace Chinese and shell metacharacters');
      let previousSubmits = this.submits;
      await this.action({ action: 'keyevent', key: 'ENTER' });
      await this.waitFor((): boolean => this.submits > previousSubmits, 'ENTER delivered to test field');
      await this.bridge.screenshot();
      this.result = '点击、聚焦、替换输入、中文/特殊字符和回车验证通过。日志已保存到我的 → 手机 HDC。';
      hub.finishExternal('success', this.result);
    } catch (e) {
      this.result = (e as Error).message;
      if (ownsLog) { hub.recordExternal('INPUT_PROBE_FAILED ' + this.result); hub.finishExternal(this.cancelled ? 'cancelled' : 'failed', this.result); }
    } finally {
      this.bridge?.close(); this.bridge = null;
      if (ownsLog) {
        await AgentExecutionController.restoreCaptureOverlay(overlayToken);
      }
      this.running = false;
    }
  }

  @Builder PageHeader() {
    AppHeader({ title: '手机 HDC 输入能力诊断', showBackButton: true,
      onBackClick: (): void => { if (!this.running) { router.back(); } } })
  }

  @Builder PageContent() {
    Column({ space: 14 }) {
      Text('先点测试输入框一次，再点开始。运行时不要手动操作输入框；测试使用任务的同一桥接，并检查实际收到的点击、文字和回车。')
        .fontSize(13).lineHeight(21).width('90%')
      Text(this.pointText).fontSize(12).fontColor('#667085').height(26)
      TextInput({ text: this.text, placeholder: '测试输入框' }).width('90%').height(48)
        .enterKeyType(EnterKeyType.Done)
        .onClick((event: ClickEvent): void => {
          this.x = Math.floor(vp2px(event.displayX));
          this.y = Math.floor(vp2px(event.displayY));
          this.pointText = '已校准屏幕像素坐标：' + this.x + ',' + this.y;
          this.clicks++;
        })
        .onChange((value: string): void => { this.text = value; })
        .onSubmit((): void => { this.submits++; })
      Button(this.running ? '停止测试' : '开始点击与输入验证').width('90%').height(44)
        .onClick(async (): Promise<void> => { if (this.running) { this.stop(); } else { await this.run(); } })
      Text(this.result).width('90%').fontSize(13).lineHeight(20).maxLines(5)
      Button('返回日志页面').height(38).enabled(!this.running).onClick(() => { router.back(); })
    }.width('100%').height('100%').padding({ top: APP_HEADER_CONTENT_GAP + 14, bottom: 30 })
  }

  build() {
    Column() {
      FrostedPage({
        pageBackgroundColor: '#F4F8FF',
        headerBuilder: (): void => { this.PageHeader(); },
        contentBuilder: (): void => { this.PageContent(); }
      })
    }
    .width('100%')
    .height('100%')
  }
}
