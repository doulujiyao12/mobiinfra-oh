import { WatchTheme } from '../theme/WatchTheme';
import { scrollFromWatchAction } from '../services/WatchCrownFocus';

// A taller inscribed rectangle gives the scroll viewport room above fixed actions.
// It still fits inside a round display: .68² + .72² < 1.
export const WATCH_DIALOG_WIDTH_PERCENT: number = 68;
export const WATCH_DIALOG_HEIGHT_PERCENT: number = 72;

@Component
export struct WatchRoundDialog {
  private scroller: Scroller = new Scroller();
  private scrollFocused: boolean = false;
  @Prop title: string = '';
  @Prop cancelLabel: string = '取消';
  @Prop confirmLabel: string = '确认';
  @Prop dangerous: boolean = false;
  @Prop busy: boolean = false;
  @Prop showContentAction: boolean = false;
  @Prop showCancel: boolean = true;
  @Prop showFooterLeading: boolean = false;
  onCancel: () => void = (): void => {};
  onConfirm: () => void = (): void => {};
  onFocusRequest: () => void = (): void => {};
  @BuilderParam contentBuilder: () => void = this.Empty;
  @BuilderParam contentActionBuilder: () => void = this.Empty;
  @BuilderParam footerLeadingBuilder: () => void = this.Empty;
  @Builder private Empty() { Column() {} }

  private focusContent(): void {
    this.onFocusRequest();
  }

  build() {
    Column() {
      Column({ space: 8 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
          .width('100%').textAlign(TextAlign.Center).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(0)
          .id('watch-dialog-crown').focusable(true).defaultFocus(true)
          .onDigitalCrown((event: CrownEvent): void => {
            scrollFromWatchAction(event, this.scroller, false);
          })
          .onVisibleAreaChange([0.5], (visible: boolean): void => {
            if (visible) { this.focusContent(); }
          })
        Scroll(this.scroller) {
          Column({ space: 8 }) { this.contentBuilder() }.width('100%').padding({ right: 8 })
            .alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical)
          .enableScrollInteraction(true).scrollBar(BarState.On)
          .scrollBarWidth(3).scrollBarColor(WatchTheme.primaryLight).clip(true)
          .focusable(true).focusOnTouch(true)
          .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
          .onFocus((): void => { this.scrollFocused = true; })
          .onBlur((): void => { this.scrollFocused = false; })
          .onAppear((): void => { this.focusContent(); })
        if (this.showContentAction) {
          Column() { this.contentActionBuilder() }.width('100%').flexShrink(0)
        }
        Row({ space: 8 }) {
          if (this.showFooterLeading) { this.footerLeadingBuilder() }
          if (this.showCancel) {
            Button(this.cancelLabel).fontSize(13).height(34).layoutWeight(1).padding(0)
              .fontColor(WatchTheme.textSecondary).backgroundColor(WatchTheme.background).enabled(!this.busy)
              .onClick(this.onCancel)
          }
          Button(this.confirmLabel).fontSize(this.showFooterLeading ? 12 : 13).height(34).layoutWeight(1).padding(0)
            .fontColor(this.dangerous ? WatchTheme.danger : WatchTheme.onPrimary)
            .backgroundColor(this.dangerous ? WatchTheme.dangerSurface : WatchTheme.primary).enabled(!this.busy)
            .onClick(this.onConfirm)
        }.width('100%').flexShrink(0)
      }.width(WATCH_DIALOG_WIDTH_PERCENT + '%').height(WATCH_DIALOG_HEIGHT_PERCENT + '%')
        .padding(12).borderRadius(24).backgroundColor(WatchTheme.surface)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      // Default lets the Scroll/buttons receive touch while blocking the covered UI.
      .backgroundColor('#B3000000').hitTestBehavior(HitTestMode.Default)
      .onDigitalCrown((event: CrownEvent): void => {
        scrollFromWatchAction(event, this.scroller, this.scrollFocused);
      })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Up) { this.focusContent(); }
      })
  }
}
