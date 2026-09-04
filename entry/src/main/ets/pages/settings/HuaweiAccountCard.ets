import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { showToastSafely } from '../../utils/PromptSafe';

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
      (error: BusinessError, _credential: loginComponentManager.HuaweiIDCredential): void => {
        if (error) {
          this.handleLoginError(error);
          return;
        }
        this.sessionActive = true;
        showToastSafely('华为账号登录成功');
      }
    );
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
    this.sessionActive = false;
    showToastSafely('已退出本应用账号状态');
  }

  @Builder AccountContent() {
    if (this.sessionActive) {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.header_mine'))
            .width(28)
            .height(28)
            .objectFit(ImageFit.Contain)
        }
        .width(42)
        .height(42)
        .borderRadius(14)
        .backgroundColor('#F1F2FF')

        Text('华为账号')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#11182F')
          .margin({ left: 12 })

        Blank()

        Button('退出登录')
          .height(36)
          .fontSize(13)
          .fontColor('#5B5CE2')
          .backgroundColor('#F1F2FF')
          .borderRadius(18)
          .padding({ left: 16, right: 16 })
          .onClick(() => { this.clearLocalSession(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    } else {
      LoginWithHuaweiIDButton({
        params: this.loginButtonParams,
        controller: this.loginController
      })
        .width('100%')
        .height(48)
    }
  }

  build() {
    Column() {
      this.AccountContent()
    }
    .width('92%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(20)
    .border({ width: 1, color: '#E9EDF5' })
    .shadow({ radius: 12, color: '#100F1E3A', offsetX: 0, offsetY: 4 })
    .margin({ top: 8 })
  }
}
