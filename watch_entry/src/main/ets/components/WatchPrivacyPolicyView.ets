import { common } from '@kit.AbilityKit';
import { WatchTheme } from '../theme/WatchTheme';
import { WATCH_PRIVACY_APP_NAME, WATCH_PRIVACY_DEVELOPER, WATCH_PRIVACY_CONTACT,
  WATCH_PRIVACY_POLICY_URL } from '../config/WatchPrivacyPolicy';

@Component
export struct WatchPrivacyPolicyView {
  @State private message: string = '';
  onBack: () => void = (): void => {};

  private async openPolicy(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(WATCH_PRIVACY_POLICY_URL);
      this.message = '';
    } catch (_) { this.message = '可用手机扫描二维码，查看完整隐私政策。'; }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          Text('开发者隐私政策').fontSize(16).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
            .width('100%').textAlign(TextAlign.Center)
          Text(WATCH_PRIVACY_APP_NAME + ' · ' + WATCH_PRIVACY_DEVELOPER).fontSize(12).fontColor(WatchTheme.textSecondary)
            .width('100%').textAlign(TextAlign.Center)
          QRCode(WATCH_PRIVACY_POLICY_URL).width('100%').aspectRatio(1).padding(8)
            .color(Color.Black).backgroundColor(Color.White).accessibilityText('开发者隐私政策网址二维码')
          Text('手机扫码查看完整政策').fontSize(12).fontColor(WatchTheme.textSecondary)
            .width('100%').textAlign(TextAlign.Center)
          Button('打开完整政策').width('100%').height(34).fontSize(12).padding(0)
            .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface)
            .onClick((): void => { this.openPolicy(); })
          if (this.message) {
            Text(this.message).fontSize(12).fontColor(WatchTheme.textSecondary).width('100%').textAlign(TextAlign.Center)
          }
          Text('联系开发者：' + WATCH_PRIVACY_CONTACT).fontSize(11).fontColor(WatchTheme.textMuted)
            .width('100%').textAlign(TextAlign.Center)
          Button('返回').width('100%').height(34).fontSize(13).padding(0)
            .fontColor(WatchTheme.text).backgroundColor(WatchTheme.surface).onClick(this.onBack)
        }.width('100%').padding(8)
      }.width('70%').height('70%').scrollBar(BarState.Auto).clip(true)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(WatchTheme.background)
  }
}
