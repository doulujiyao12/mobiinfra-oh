import { AppTheme } from '../utils/AppTheme';
import { MemorySupplementItem } from '../utils/MemorySupplement';

@Component
export struct MemorySupplementCard {
  @Prop items: MemorySupplementItem[] = [];
  @State private expanded: boolean = false;

  @Builder private MemoryRow(item: MemorySupplementItem, index: number) {
    Column({ space: 8 }) {
      Row({ space: 9 }) {
        Text((index + 1).toString()).fontSize(11).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#6573A8'))
          .width(21).height(21).textAlign(TextAlign.Center).borderRadius(7).backgroundColor(AppTheme.background('#EDF0FA'))
        Text(item.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#25304A'))
          .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Text(item.content).fontSize(14).lineHeight(22).fontColor(AppTheme.text('#485367')).width('100%')
      Row({ space: 7 }) {
        Text(item.source).fontSize(11).fontColor(AppTheme.text('#858D9B'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.date) { Text(item.date.replace(/-/g, '.')).fontSize(11).fontColor(AppTheme.text('#858D9B')) }
      }.width('100%')
      if (item.subject || item.status) {
        Text([item.subject, item.status].filter((value: string): boolean => !!value).join(' · '))
          .fontSize(11).fontColor(AppTheme.text('#6376A1')).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
      .backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(14)
  }

  build() {
    Column({ space: this.expanded ? 12 : 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Text('忆').fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#6272B7'))
            .width(28).height(28).textAlign(TextAlign.Center).borderRadius(9).backgroundColor(AppTheme.background('#E9EDF9'))
          Text('已补充 ' + this.items.length + ' 条相关记忆').fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#475578')).layoutWeight(1)
          Text(this.expanded ? '收起' : '展开').fontSize(12).fontColor(AppTheme.text('#7480A0'))
          Text(this.expanded ? '⌃' : '⌄').fontSize(18).fontColor(AppTheme.text('#7480A0')).width(14).textAlign(TextAlign.Center)
        }.width('100%').constraintSize({ minHeight: 36 })
      }.width('100%').padding(0).backgroundColor(Color.Transparent)
        .onClick((): void => { this.expanded = !this.expanded; })
        .accessibilityText((this.expanded ? '收起' : '展开查看') + this.items.length + '条补充记忆')
      if (this.expanded) {
        Column({ space: 10 }) {
          ForEach(this.items, (item: MemorySupplementItem, index: number) => { this.MemoryRow(item, index); },
            (_item: MemorySupplementItem, index: number): string => index.toString())
        }.width('100%')
      }
    }.width('96%').alignItems(HorizontalAlign.Start).padding(12).borderRadius(18)
      .backgroundColor(AppTheme.background('#F2F4FA')).margin({ top: 10, bottom: 14 })
  }
}
