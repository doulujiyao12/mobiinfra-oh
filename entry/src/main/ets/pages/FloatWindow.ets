@Entry
@Component
struct FloatWindow {
  @StorageLink('floatText') floatText: string = 'AI Agent 运行中...'

  build() {
    Row() {
      Column() {
        Text(this.floatText)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding(4)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .borderRadius(10)
  }
}
