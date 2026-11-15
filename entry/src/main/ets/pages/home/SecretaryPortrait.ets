@Component
export struct SecretaryPortrait {
  @Prop @Watch('updateBreathing') active: boolean = false;
  @Prop showHint: boolean = true;
  @Prop receiving: boolean = false;
  onGreet: () => void = (): void => {};
  @State private inhale: boolean = false;
  @State private nod: boolean = false;
  private visible: boolean = false;

  private updateBreathing(): void {
    const play = this.visible && this.active;
    if (this.inhale === play) { return; }
    this.getUIContext().animateTo({
      duration: play ? 1650 : 0, iterations: play ? -1 : 1, playMode: PlayMode.Alternate, curve: Curve.EaseInOut
    }, (): void => { this.inhale = play; });
  }

  private greet(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 125, curve: Curve.EaseOut, event: (): void => { this.nod = true; } },
      { duration: 235, curve: Curve.EaseInOut, event: (): void => { this.nod = false; } }
    ]);
    this.onGreet();
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // Idle breathing and the tap response animate separate layers, so a tap cannot cancel the loop.
      Stack() {
        Image($r('app.media.clawmate_secretary')).width('100%').height('100%').objectFit(ImageFit.Contain)
          .padding({ top: 13, bottom: 2 }).draggable(false)
          .scale({ x: this.inhale ? 1.012 : 1, y: this.inhale ? 1.024 : 1, centerY: '95%' })
          .translate({ y: this.inhale ? -2 : 0 })
      }.width('100%').height('100%')
        .rotate({ angle: this.nod ? -2.5 : 0, centerY: '82%' })
        .translate({ y: this.nod ? -4 : 0 })
      Text('点一点').fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_accent_purple'))
        .padding({ left: 9, right: 9, top: 3, bottom: 3 }).backgroundColor($r('app.color.ui_soft_purple'))
        .borderRadius({ topLeft: 12, topRight: 12, bottomLeft: 3, bottomRight: 12 })
        .margin({ top: 8, right: 2 })
        .opacity(this.inhale ? 1 : 0.78)
        .scale({ x: this.inhale ? 1.055 : 1, y: this.inhale ? 1.055 : 1 })
        .translate({ y: this.inhale ? -4 : 0 })
        .visibility(this.showHint ? Visibility.Visible : Visibility.Hidden)
        .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
    }.width('100%').height('100%').accessibilityGroup(true)
      .scale({ x: this.receiving ? 1.035 : 1, y: this.receiving ? 1.035 : 1 })
      .animation({ duration: 160, curve: Curve.EaseOut })
      .accessibilityText('小C，你的专属秘书。轻点打招呼').onClick((): void => { this.greet(); })
      .onVisibleAreaChange([0], (visible: boolean): void => {
        this.visible = visible;
        this.updateBreathing();
      })
  }
}
