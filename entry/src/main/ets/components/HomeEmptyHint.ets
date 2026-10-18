import { AppTheme } from '../utils/AppTheme';

@Component
export struct HomeEmptyHint {
  @Prop messageText: string = '';
  @Prop illustration: Resource = $r('app.media.home_explorer_mascot');
  @Prop accentTone: string = '#5968FF';
  @Prop loading: boolean = false;
  @Prop linkLabel: string = '去派任务';
  onOpen: () => void = (): void => {};

  build() {
    Row({ space: 12 }) {
      Stack() {
        if (this.loading) {
          LoadingProgress().width(28).height(28).color(AppTheme.text(this.accentTone))
        } else {
          Image(this.illustration).width(76).height(76).objectFit(ImageFit.Contain)
            .accessibilityText('背着小背包、朝手机出发的卡通猫伙伴')
        }
      }.width(76).height(76)
      Column({ space: 2 }) {
        Text(this.messageText).fontSize(15).lineHeight(22).fontColor(AppTheme.text('#343A4B'))
          .width('100%')
        if (!this.loading) {
          Button(this.linkLabel + ' ›', { type: ButtonType.Normal })
            .fontSize(13).fontColor(AppTheme.text(this.accentTone)).height(32)
            .padding({ left: 0, right: 8 }).borderRadius(8).backgroundColor(Color.Transparent)
            .onClick((): void => { this.onOpen(); })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Center)
      .padding({ left: 4, right: 4, top: 10, bottom: 10 })
  }
}
