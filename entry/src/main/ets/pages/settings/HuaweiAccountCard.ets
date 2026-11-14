import { AppTheme } from '../../utils/AppTheme';
import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { showToastSafely } from '../../utils/PromptSafe';
import { HuaweiAccountSession } from '../../utils/HuaweiAccountSession';

const HUAWEI_LOGIN_CANCELLED: number = 1001502012;
const HUAWEI_LOGIN_NETWORK_ERROR: number = 1001502005;
const HUAWEI_LOGIN_FINGERPRINT_ERROR: number = 1001500001;
const HUAWEI_LOGIN_CONFIG_ERROR: number = 401;

@Component
export struct HuaweiAccountCard {
  @Link sessionActive: boolean;
  private loginController: loginComponentManager.LoginWithHuaweiIDButtonController =
    new loginComponentManager.LoginWithHuaweiIDButtonController();
  private loginButtonParams: loginComponentManager.LoginWithHuaweiIDButtonParams = {
    style: loginComponentManager.Style.BUTTON_RED,
    borderRadius: 24,
    loginType: loginComponentManager.LoginType.ID,
    supportDarkMode: true,
    textAndIconStyle: true
  };

  aboutToAppear(): void {
    this.loginController.onClickLoginWithHuaweiIDButton(
      (error: BusinessError, credential: loginComponentManager.HuaweiIDCredential): void => {
        if (error) {
          this.handleLoginError(error);
          return;
        }
        let context = this.getUIContext().getHostContext();
        if (context === undefined) {
          showToastSafely('无法保存登录状态，请重试');
          return;
        }
        try {
          HuaweiAccountSession.recordLogin(context, credential.openID);
          this.sessionActive = true;
          showToastSafely('华为账号登录成功');
        } catch (e) {
          this.sessionActive = false;
          showToastSafely('登录状态保存失败，请重试', 2500);
        }
      }
    );
    let context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      HuaweiAccountSession.refresh(context).catch((): void => {
        showToastSafely('暂时无法确认账号状态，请检查网络后重试', 2500);
      });
    }
  }

  private handleLoginError(error: BusinessError): void {
    if (error.code === HUAWEI_LOGIN_CANCELLED) {
      return;
    }
    if (error.code === HUAWEI_LOGIN_NETWORK_ERROR) {
      showToastSafely('网络连接异常，请稍后重试');
      return;
    }
    if (error.code === HUAWEI_LOGIN_FINGERPRINT_ERROR) {
      showToastSafely('应用签名校验失败，请检查 AppGallery Connect 配置', 2500);
      return;
    }
    if (error.code === HUAWEI_LOGIN_CONFIG_ERROR) {
      showToastSafely('华为账号登录尚未完成应用配置', 2500);
      return;
    }
    showToastSafely(`登录暂时不可用（${error.code}）`, 2200);
  }

  private clearLocalSession(): void {
    let context = this.getUIContext().getHostContext();
    if (context === undefined) {
      showToastSafely('无法更新登录状态，请重试');
      return;
    }
    try {
      HuaweiAccountSession.logout(context);
      this.sessionActive = false;
      showToastSafely('已退出本应用账号状态');
    } catch (e) {
      showToastSafely('退出状态保存失败，请重试', 2500);
    }
  }

  @Builder AccountContent() {
    Row({ space: 14 }) {
      Image($r('app.media.settings_account')).width(52).height(52).padding(11).borderRadius(26)
        .objectFit(ImageFit.Contain).backgroundColor($r('app.color.ui_surface_soft'))
      Column({ space: 6 }) {
        Text('华为账号').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
          .width('100%')
        Text(this.sessionActive ? '已登录' : '未登录').fontSize(13).fontColor($r('app.color.ui_text_secondary'))
          .width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.sessionActive) {
        Button('退出登录')
          .height(40).fontSize(14)
          .fontColor($r('app.color.ui_accent_blue')).backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 0 })
          .onClick(() => { this.clearLocalSession(); })
      }
    }.width('100%').alignItems(VerticalAlign.Center)
    if (!this.sessionActive) {
      LoginWithHuaweiIDButton({
        params: this.loginButtonParams,
        controller: this.loginController
      })
        .width('100%')
        .height(44).margin({ top: 18 })
    }
  }

  build() {
    Column() {
      this.AccountContent()
    }
    .width('100%')
    .padding(20)
    .backgroundColor(AppTheme.background(Color.White))
    .borderRadius(22)
  }
}
