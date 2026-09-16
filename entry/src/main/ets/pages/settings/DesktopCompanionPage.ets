import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import {
  DESKTOP_COMPANION_APP_NAME,
  DESKTOP_COMPANION_DOWNLOAD_URL,
  DESKTOP_COMPANION_EXTRACT_CODE
} from '../../config/DesktopCompanionConfig';
import { showToastSafely } from '../../utils/PromptSafe';

@Entry
@Component
struct DesktopCompanionPage {
  private async openDownloadPage(): Promise<void> {
    try {
      let context = getContext(this) as common.UIAbilityContext;
      await context.openLink(DESKTOP_COMPANION_DOWNLOAD_URL);
    } catch (e) {
      showToastSafely('无法打开浏览器，请复制链接后手动访问', 2200);
    }
  }

  private async copyDownloadLink(): Promise<void> {
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, DESKTOP_COMPANION_DOWNLOAD_URL);
      await pasteboard.getSystemPasteboard().setData(data);
      showToastSafely('下载链接已复制', 1500);
    } catch (e) {
      showToastSafely('复制失败，请长按链接手动复制', 1800);
    }
  }

  build() {
    Column() {
      Row() {
        Button('‹')
          .width(42)
          .height(42)
          .fontSize(28)
          .fontColor('#11182F')
          .backgroundColor(Color.White)
          .borderRadius(14)
          .onClick(() => { router.back(); })
        Column() {
          Text('桌面端 App')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .width('100%')
          Text('下载与使用说明')
            .fontSize(12)
            .fontColor('#7B8290')
            .width('100%')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
      }
      .width('92%')
      .margin({ top: 18, bottom: 10 })

      Scroll() {
        Column() {
          Column() {
            Row() {
              Text('PC')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .width(52)
                .height(52)
                .textAlign(TextAlign.Center)
                .backgroundColor('#4F68FF')
                .borderRadius(16)
              Column() {
                Text(DESKTOP_COMPANION_APP_NAME)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#151A28')
                  .width('100%')
                  .maxLines(2)
                Text('配合移动端完成任务执行与设备自动化')
                  .fontSize(12)
                  .fontColor('#7B8290')
                  .width('100%')
                  .maxLines(2)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })
            }
            .width('100%')

            Text('下载链接')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#30384C')
              .width('100%')
              .margin({ top: 22 })
            Text(DESKTOP_COMPANION_DOWNLOAD_URL)
              .fontSize(13)
              .lineHeight(20)
              .fontColor('#4F68FF')
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .backgroundColor('#F4F7FF')
              .borderRadius(12)
              .margin({ top: 8 })
              .onClick(async () => { await this.openDownloadPage(); })
            Text('提取码：' + DESKTOP_COMPANION_EXTRACT_CODE)
              .fontSize(13)
              .fontColor('#555D70')
              .width('100%')
              .margin({ top: 10 })

            Row({ space: 10 }) {
              Button('复制链接')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontColor('#4F68FF')
                .backgroundColor('#EEF1FF')
                .borderRadius(14)
                .onClick(async () => { await this.copyDownloadLink(); })
              Button('打开下载页面')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .backgroundColor('#4F68FF')
                .borderRadius(14)
                .onClick(async () => { await this.openDownloadPage(); })
            }
            .width('100%')
            .margin({ top: 20 })
          }
          .width('92%')
          .alignItems(HorizontalAlign.Start)
          .padding(18)
          .backgroundColor(Color.White)
          .borderRadius(20)

          Column() {
            Text('使用前请确认')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#151A28')
              .width('100%')
            Text('1. 在电脑上下载安装并启动 ClawMate 桌面端 App。\n2. 确保手机与电脑的连接配置正常。\n3. 返回移动端，在任务页执行任务或在聊天页点击“下发任务”。')
              .fontSize(13)
              .lineHeight(21)
              .fontColor('#667085')
              .width('100%')
              .margin({ top: 10 })
          }
          .width('92%')
          .alignItems(HorizontalAlign.Start)
          .padding(18)
          .backgroundColor(Color.White)
          .borderRadius(20)
          .margin({ top: 14, bottom: 30 })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F8FF')
  }
}
