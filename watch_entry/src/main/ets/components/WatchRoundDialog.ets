import { WatchTheme } from '../theme/WatchTheme';

// A taller inscribed rectangle gives the scroll viewport room above fixed actions.
// It still fits inside a round display: .68² + .72² < 1.
export const WATCH_DIALOG_WIDTH_PERCENT: number = 68;
export const WATCH_DIALOG_HEIGHT_PERCENT: number = 72;

@Component
export struct WatchRoundDialog {
  @Prop title: string = '';
  @Prop cancelLabel: string = '取消';
  @Prop confirmLabel: string = '确认';
  @Prop dangerous: boolean = false;
  @Prop busy: boolean = false;
  @Prop showContentAction: boolean = false;
  onCancel: () => void = (): void => {};
  onConfirm: () => void = (): void => {};
  @BuilderParam contentBuilder: () => void = this.Empty;
  @BuilderParam contentActionBuilder: () => void = this.Empty;
  @Builder private Empty() { Column() {} }

  build() {
    Column() {
      Column({ space: 8 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
          .width('100%').textAlign(TextAlign.Center).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(0)
        Scroll() {
          Column({ space: 8 }) { this.contentBuilder() }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical)
          .enableScrollInteraction(true).scrollBar(BarState.Auto).clip(true)
        if (this.showContentAction) {
          Column() { this.contentActionBuilder() }.width('100%').flexShrink(0)
        }
        Row({ space: 8 }) {
          Button(this.cancelLabel).fontSize(13).height(34).layoutWeight(1).padding(0)
            .fontColor(WatchTheme.textSecondary).backgroundColor(WatchTheme.background).enabled(!this.busy)
            .onClick(this.onCancel)
          Button(this.confirmLabel).fontSize(13).height(34).layoutWeight(1).padding(0)
            .fontColor(this.dangerous ? WatchTheme.danger : WatchTheme.onPrimary)
            .backgroundColor(this.dangerous ? WatchTheme.dangerSurface : WatchTheme.primary).enabled(!this.busy)
            .onClick(this.onConfirm)
        }.width('100%').flexShrink(0)
      }.width(WATCH_DIALOG_WIDTH_PERCENT + '%').height(WATCH_DIALOG_HEIGHT_PERCENT + '%')
        .padding(12).borderRadius(24).backgroundColor(WatchTheme.surface)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      // Default lets the Scroll/buttons receive touch while blocking the covered UI.
      .backgroundColor('#B3000000').hitTestBehavior(HitTestMode.Default)
  }
}
