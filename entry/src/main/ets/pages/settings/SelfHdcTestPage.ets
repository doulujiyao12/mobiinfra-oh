import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { showToastSafely } from '../../utils/PromptSafe';
import { applyPageStatusBar } from '../../utils/PageStatusBar';
import { DEBUG_ENABLED_STORAGE_KEY } from '../../utils/DebugSettings';
import { selfHdcReadText } from '../../utils/selfhdc/SelfHdcFiles';
import { SelfHdcTaskSettings } from '../../utils/selfhdc/SelfHdcTaskSettings';
import { SelfHdcSetupGuard } from '../../utils/selfhdc/SelfHdcSetupGuard';
import { PHONE_HDC_SETUP_GUIDE } from '../../utils/selfhdc/SelfHdcSetupPolicy';
import {
  SelfHdcTestRunner, SelfHdcTestState
} from '../../utils/selfhdc/SelfHdcTestRunner';

@Entry
@Component
struct SelfHdcTestPage {
  private pageScroller: Scroller = new Scroller();
  onPageShow(): void {
    applyPageStatusBar(this.getUIContext(), '#F4F8FF');
  }

  onPageHide(): void {
    applyPageStatusBar(this.getUIContext(), '#FFFFFF');
  }

  @StorageProp(DEBUG_ENABLED_STORAGE_KEY) @Watch('onDebugEnabledChanged') private debugEnabled: boolean = false;
  @StorageLink('selfHdcTaskIp') private ip: string = '';
  @StorageLink('selfHdcTaskPort') private port: string = '';
  @StorageLink('selfHdcTaskAutoIp') private autoIp: boolean = true;
  @StorageLink('selfHdcLocalAddresses') private localAddresses: string = '正在读取本机网络地址…';
  @StorageLink('selfHdcIpStatus') private ipStatus: string = '';
  @State private refreshingIp: boolean = false;
  @State private result: SelfHdcTestState = new SelfHdcTestState();
  @State private pageError: string = '';
  private runner: SelfHdcTestRunner = SelfHdcTestRunner.shared();
  private observer: (state: SelfHdcTestState) => void = (state: SelfHdcTestState): void => {
    this.result = state;
  };

  aboutToAppear(): void {
    try {
      this.runner.initialize((getContext(this) as common.UIAbilityContext).filesDir);
      this.runner.subscribe(this.observer);
      let saved = SelfHdcTaskSettings.load((getContext(this) as common.UIAbilityContext).filesDir);
      this.ip = saved.ip; this.port = saved.port; this.autoIp = saved.autoIp;
    } catch (e) { this.pageError = '初始化日志目录失败：' + (e as Error).message; }
    this.refreshIp();
  }

  aboutToDisappear(): void {
    this.runner.unsubscribe(this.observer);
  }

  private onDebugEnabledChanged(): void {
    this.result = this.runner.snapshot();
  }

  private async start(connectionOnly: boolean): Promise<void> {
    if (this.refreshingIp || !this.saveConnection()) { return; }
    this.pageError = '';
    try {
      if (!await SelfHdcSetupGuard.ensure(this.getUIContext(),
        (getContext(this) as common.UIAbilityContext).filesDir, 'phone-hdc-test', false)) { return; }
      await this.runner.run(getContext(this) as common.UIAbilityContext, {
        ip: this.ip, port: this.port, connectionOnly: connectionOnly
      });
    } catch (e) { this.pageError = (e as Error).message; }
  }

  private saveConnection(): boolean {
    if (this.result.running) { return false; }
    try {
      let filesDir = (getContext(this) as common.UIAbilityContext).filesDir;
      let settings = SelfHdcTaskSettings.load(filesDir);
      settings.ip = this.ip.trim(); settings.port = this.port.trim(); settings.autoIp = this.autoIp;
      SelfHdcTaskSettings.save(filesDir, settings);
      this.pageError = '';
      return true;
    } catch (e) { this.pageError = '连接设置保存失败：' + (e as Error).message; return false; }
  }

  private async refreshIp(): Promise<void> {
    if (this.refreshingIp) { return; }
    this.refreshingIp = true;
    try {
      await SelfHdcTaskSettings.refreshLocalIp((getContext(this) as common.UIAbilityContext).filesDir, 'phone-hdc-settings');
    } catch (e) { this.pageError = '检测 IP 失败：' + (e as Error).message; }
    finally { this.refreshingIp = false; }
  }

  private async copyLogs(): Promise<void> {
    if (!this.debugEnabled) { return; }
    try {
      let filesDir = (getContext(this) as common.UIAbilityContext).filesDir;
      if (!this.result.logPath.startsWith(filesDir + '/self_hdc/runs/')) {
        throw new Error('没有可复制的测试日志');
      }
      let log = selfHdcReadText(this.result.logPath, 4 * 1024 * 1024);
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, log));
      showToastSafely('完整手机执行日志已复制', 1800);
    } catch (e) { showToastSafely('复制失败：' + (e as Error).message, 2500); }
  }

  private statusText(): string {
    if (this.result.running) { return '执行中 · ' + this.result.stage; }
    switch (this.result.outcome) {
      case 'success': return '执行完成';
      case 'failed': return '执行失败 · ' + this.result.stage;
      case 'cancelled': return '执行已停止';
      case 'interrupted': return '上次执行中断';
      default: return '等待开始';
    }
  }

  private clearLogs(): void {
    if (!this.debugEnabled) { return; }
    try { this.runner.clearLogs(); showToastSafely('手机测试和任务日志已清空', 1800); }
    catch (e) { showToastSafely('清空失败：' + (e as Error).message, 2200); }
  }

  private async openInputTest(): Promise<void> {
    if (this.refreshingIp || !this.saveConnection()) { return; }
    try {
      if (!await SelfHdcSetupGuard.ensure(this.getUIContext(),
        (getContext(this) as common.UIAbilityContext).filesDir, 'phone-hdc-input-page', false)) { return; }
      await router.pushUrl({ url: 'pages/settings/SelfHdcInputTestPage' });
    } catch (e) { this.pageError = (e as Error).message; }
  }

  @Builder private SectionTitle(title: string) {
    Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#11182F').width('100%')
  }

  @Builder private ScreenshotCard(title: string, path: string) {
    Column() {
      this.SectionTitle(title)
      Image('file://' + path)
        .width('100%').height(360).objectFit(ImageFit.Contain).borderRadius(12).margin({ top: 10 })
      Text(path).fontSize(10).fontColor('#7B8290').width('100%').margin({ top: 8 })
    }
    .width('92%').padding(18).alignItems(HorizontalAlign.Start)
    .backgroundColor(Color.White).borderRadius(18).margin({ top: 14 })
  }

  @Builder PageHeader() {
    AppHeader({ title: '手机 HDC', showBackButton: true, onBackClick: (): void => { router.back(); } })
  }

  @Builder PageContent() {
    Scroll(this.pageScroller) {
      Column() {
        Column() {
          this.SectionTitle('无线调试地址')
          Text(PHONE_HDC_SETUP_GUIDE + '\n首次连接时，请手动允许系统调试授权弹窗。')
            .fontSize(13).lineHeight(21).fontColor('#667085').width('100%').margin({ top: 10 })
          Text('本机 IPv4：' + this.localAddresses)
            .fontSize(12).fontColor('#667085').width('100%').margin({ top: 12 })
          Row({ space: 10 }) {
            Text('自动更新手机 Wi-Fi IP').fontSize(13).fontColor('#475467').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoIp }).enabled(!this.result.running)
              .onChange((value: boolean): void => {
                this.autoIp = value;
                if (this.saveConnection()) { this.refreshIp(); }
              })
          }.width('100%').margin({ top: 12 })
          TextInput({ text: this.ip, placeholder: '手机 IPv4 地址' })
            .height(46).fontSize(14).enabled(!this.result.running && !this.autoIp).margin({ top: 10 })
            .onChange((value: string): void => { this.ip = value; this.saveConnection(); })
          TextInput({ text: this.port, placeholder: '无线调试连接端口' })
            .type(InputType.Number).height(46).fontSize(14).enabled(!this.result.running).margin({ top: 10 })
            .onChange((value: string): void => { this.port = value; this.saveConnection(); })
          Text(this.ipStatus || '每次启动、回到 App 和连接前自动检测 Wi-Fi IP。')
            .fontSize(12).lineHeight(19).fontColor('#667085').width('100%').margin({ top: 10 })
          Button(this.refreshingIp ? '正在检测 IP…' : '立即检测手机 IP').height(34).fontSize(12)
            .enabled(!this.result.running && !this.refreshingIp).margin({ top: 8 })
            .onClick(async (): Promise<void> => { await this.refreshIp(); })
          Text('修改即保存，任务页共用这里的设置。需使用回环或其他手动地址时，关闭自动更新。')
            .fontSize(12).lineHeight(19).fontColor('#7B8290').width('100%').margin({ top: 8 })
          Text('请填写 HDC 调试连接端口；不要填写配对码端口或桌面服务端口。端口可能在重新开启无线调试后变化。')
            .fontSize(12).lineHeight(19).fontColor('#7B8290').width('100%').margin({ top: 10 })
          Row({ space: 10 }) {
            Button('仅测试连接').layoutWeight(1).height(44).fontSize(14)
              .backgroundColor('#EEF1FF').fontColor('#4F68FF').enabled(!this.result.running && !this.refreshingIp)
              .onClick(async (): Promise<void> => { await this.start(true); })
            Button('开始完整测试').layoutWeight(1).height(44).fontSize(14)
              .backgroundColor('#4F68FF').fontColor(Color.White).enabled(!this.result.running && !this.refreshingIp)
              .onClick(async (): Promise<void> => { await this.start(false); })
          }.width('100%').margin({ top: 18 })
          if (this.result.running) {
            Button('停止执行').width('100%').height(42).fontSize(14).backgroundColor('#FFF0ED').fontColor('#B54708')
              .margin({ top: 10 }).onClick(() => { this.runner.cancel(); })
          }
          Button('验证点击 / 聚焦 / 文本输入').width('100%').height(40).fontSize(13)
            .enabled(!this.result.running && !this.refreshingIp).margin({ top: 10 })
            .onClick(async (): Promise<void> => { await this.openInputTest(); })
          if (this.pageError) {
            Text(this.pageError).fontSize(12).fontColor('#B42318').width('100%').margin({ top: 10 })
          }
        }.width('92%').padding(18).alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(18)

        Column() {
          this.SectionTitle('测试动作')
          Text('打开支付宝 → 保存截图 → 向上滑动一次 → 保存对照截图 → 返回本 App。所有设备动作都通过手机端 HDC 会话发送。')
            .fontSize(13).lineHeight(21).fontColor('#667085').width('100%').margin({ top: 10 })
          Text('测试期间请不要手动切换应用。系统授权、后台运行或 HDC 协议不兼容时会停止，并保留失败阶段。')
            .fontSize(12).lineHeight(19).fontColor('#7B8290').width('100%').margin({ top: 10 })
        }.width('92%').padding(18).alignItems(HorizontalAlign.Start)
          .backgroundColor(Color.White).borderRadius(18).margin({ top: 14 })

        Column() {
          this.SectionTitle(this.statusText())
          if (this.debugEnabled) {
            Button('清空日志').height(36).fontSize(13).enabled(!this.result.running)
              .backgroundColor('#FFF0ED').fontColor('#B54708').margin({ top: 10 })
              .onClick(() => { this.clearLogs(); })
          }
          if (this.result.endpoint) {
            Text('直连地址：' + this.result.endpoint).fontSize(12).fontColor('#667085').width('100%').margin({ top: 8 })
          }
          if (this.result.message) {
            Text(this.result.message).fontSize(13).lineHeight(21).fontColor('#30384C').width('100%').margin({ top: 10 })
          }
          if (this.debugEnabled && this.result.logPath) {
            Text('日志：' + this.result.logPath).fontSize(11).fontColor('#7B8290').width('100%').margin({ top: 10 })
            Button('复制完整日志').height(38).fontSize(13).backgroundColor('#EEF1FF').fontColor('#4F68FF')
              .margin({ top: 10 }).onClick(async (): Promise<void> => { await this.copyLogs(); })
          }
          if (this.debugEnabled) {
            Text(this.result.logs.length > 0 ? this.result.logs.join('\n') : '执行后会在这里显示连接、授权和动作日志。')
              .fontSize(10).lineHeight(16).fontColor('#475467').width('100%').copyOption(CopyOptions.InApp)
              .margin({ top: 12 }).padding(12).backgroundColor('#F6F8FC').borderRadius(10)
          }
        }.width('92%').padding(18).alignItems(HorizontalAlign.Start)
          .backgroundColor(Color.White).borderRadius(18).margin({ top: 14 })
        if (this.result.beforeImage) { this.ScreenshotCard('首张截图', this.result.beforeImage) }
        if (this.result.afterImage) { this.ScreenshotCard('最近截图', this.result.afterImage) }
        if (this.debugEnabled) {
          Text('手机测试和任务日志在 self_hdc/runs。清空日志保留授权密钥、连接配置和截图；执行中不可清空。')
            .fontSize(11).lineHeight(18).fontColor('#7B8290').width('92%').margin({ top: 16, bottom: 30 })
        }
      }.width('100%').padding({ top: APP_HEADER_CONTENT_GAP })
    }.width('100%').height('100%').clip(false)
  }

  build() {
    Column() {
      FrostedPage({
        pageBackgroundColor: '#F4F8FF',
        scrollers: [this.pageScroller],
        headerBuilder: (): void => { this.PageHeader(); },
        contentBuilder: (): void => { this.PageContent(); }
      })
    }
    .width('100%')
    .height('100%')
  }
}
