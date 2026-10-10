export const APP_HEADER_HEIGHT: number = 56;
// 标题高度由导航容器避让；内容只需额外保留这段呼吸间距。
export const APP_HEADER_CONTENT_GAP: number = 16;

// 标题内容保持透明，由 FrostedPage 统一提供固定位置和背景模糊。
@Component
export struct AppHeader {
  @Prop title: string = '';
  icon: Resource = $r('app.media.header_companion');
  @Prop showIcon: boolean = false;
  @Prop avatarUri: string = '';
  @Prop circularAvatar: boolean = false;
  @StorageLink('pcServerConnected') pcServerConnected: boolean = false;
  @Prop pcServerVisible: boolean = false;
  @Prop showBackButton: boolean = false;
  @Prop actionLabel: string = '';
  onIconClick: () => void = () => {};
  onBackClick: () => void = () => {};
  onActionClick: () => void = () => {};

  private pcServerLabel(): string {
    return this.pcServerConnected ? 'PC 已连接' : 'PC 未连接';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#172033')
        .lineHeight(28)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ left: this.showIcon || this.pcServerVisible ? 88 :
          (this.showBackButton || this.actionLabel.length > 0 ? 56 : 0),
          right: this.showIcon || this.pcServerVisible ? 88 :
          (this.showBackButton || this.actionLabel.length > 0 ? 56 : 0) })

      Row() {
        if (this.showBackButton) {
          Button('‹')
            .width(42)
            .height(40)
            .fontSize(28)
            .fontColor('#11182F')
            .backgroundColor(Color.White)
            .borderRadius(14)
            .accessibilityText('返回')
            .onClick(() => { this.onBackClick(); })
        } else if (this.showIcon) {
          Stack({ alignContent: Alignment.Center }) {
            if (this.avatarUri.length > 0) {
              Image(this.avatarUri)
                .width(34)
                .height(34)
                .objectFit(this.circularAvatar ? ImageFit.Cover : ImageFit.Contain)
                .borderRadius(this.circularAvatar ? 17 : 0)
            } else {
              Image(this.icon)
                .width(34)
                .height(34)
                .objectFit(this.circularAvatar ? ImageFit.Cover : ImageFit.Contain)
                .borderRadius(this.circularAvatar ? 17 : 0)
            }
          }
          .width(40)
          .height(40)
          .backgroundColor(this.circularAvatar ? '#EEF2FF' : Color.Transparent)
          .borderRadius(this.circularAvatar ? 20 : 0)
          .border({
            width: this.circularAvatar ? 1 : 0,
            color: this.circularAvatar ? '#FFFFFF' : Color.Transparent
          })
          .shadow({
            radius: this.circularAvatar ? 8 : 0,
            color: this.circularAvatar ? '#160D2A63' : Color.Transparent,
            offsetX: 0,
            offsetY: this.circularAvatar ? 3 : 0
          })
          .clip(this.circularAvatar)
          .onClick(() => {
            this.onIconClick();
          })
        }
        Blank()

        if (this.pcServerVisible) {
          Row() {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(this.pcServerConnected ? '#22B07D' : '#A7AFBD')
              .margin({ right: 5 })
            Text(this.pcServerLabel())
              .fontSize(11)
              .fontColor(this.pcServerConnected ? '#167456' : '#747B87')
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
          }
          .alignItems(VerticalAlign.Center)
          .width(80)
          .justifyContent(FlexAlign.End)
        } else if (this.actionLabel.length > 0) {
          Button(this.actionLabel)
            .width(56)
            .height(40)
            .fontSize(12)
            .padding({ left: 8, right: 8 })
            .fontWeight(FontWeight.Medium)
            .fontColor('#276EF1')
            .backgroundColor('#EEF4FF')
            .borderRadius(14)
            .accessibilityText(this.actionLabel)
            .onClick(() => { this.onActionClick(); })
        }
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height(APP_HEADER_HEIGHT)
    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
  }
}
