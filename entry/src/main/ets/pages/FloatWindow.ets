@Entry
@Component
struct FloatWindow {
  @StorageLink('floatText') @Watch('onTextChange') floatText: string = 'AI Agent 运行中...'
  private scroller: Scroller = new Scroller()

  onTextChange(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom)
    }, 50)
  }

  build() {
    Column() {
      Scroll(this.scroller) {
        Text(this.floatText)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .padding(4)
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .borderRadius(10)
  }
}
