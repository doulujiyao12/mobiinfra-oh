import { AppTheme } from '../../utils/AppTheme';
import { RecordingSummary, RecordingSummarySection, recordingTime } from '../../utils/recording/RecordingTypes';
import { RECORDING_LOCAL_SUMMARY_MAX_ITEMS, uniqueRecordingSummaryItems } from '../../utils/recording/RecordingSummaryLists';

@Component
export struct RecordingSummaryView {
  @Prop summary: RecordingSummary = { title: '', overview: '', keyPoints: [], decisions: [], actionItems: [], openQuestions: [], model: '', generatedAt: '' };
  @State private visibleParts: number = 8;
  @Builder private Section(title: string, items: string[]) {
    if (items.length > 0) {
      Column({ space: 12 }) {
        Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).width('100%')
        ForEach(uniqueRecordingSummaryItems(items,
          this.summary.source === 'local' ? RECORDING_LOCAL_SUMMARY_MAX_ITEMS : 12), (item: string, index: number) => {
          Row({ space: 12 }) {
            Text('•').fontSize(18).fontColor(AppTheme.text('#5260ED')).width(12)
            Text(item).fontSize(17).lineHeight(28).fontColor(AppTheme.text('#394154')).layoutWeight(1).copyOption(CopyOptions.InApp)
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (item: string, index: number): string => String(index) + item)
      }.width('100%').margin({ top: 24 })
    }
  }
  @Builder private Contents(summary: RecordingSummary) {
    Text(summary.overview).fontSize(18).lineHeight(30).fontColor(AppTheme.text('#394154')).width('100%').copyOption(CopyOptions.InApp)
    this.Section('值得记下', summary.keyPoints)
    this.Section('已达成的结论', summary.decisions)
    this.Section('接下来要做', summary.actionItems)
    this.Section('有待确认', summary.openQuestions)
  }
  build() {
    Column({ space: 12 }) {
      Text(this.summary.title).fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      if (this.summary.source === 'local') {
        Text('本地摘要 · ' + (this.summary.sections?.length || 0) + '/' + (this.summary.partCount || 0) + ' 段' +
          (this.summary.complete === false ? ' · 尚未完成' : ''))
          .fontSize(14).fontColor(AppTheme.text('#8E8E93')).width('100%')
        ForEach((this.summary.sections || []).slice(0, this.visibleParts), (part: RecordingSummarySection) => {
          Column({ space: 12 }) {
            Divider().color(AppTheme.border('#EDF0F5')).margin({ top: 14, bottom: 8 })
            Text('第 ' + (part.index + 1) + ' 段 · ' + recordingTime(part.start) + '–' + recordingTime(part.end))
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#5260ED')).width('100%')
            this.Contents(part.summary)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (part: RecordingSummarySection): string => String(part.index) + part.summary.generatedAt)
        if ((this.summary.sections?.length || 0) > this.visibleParts) {
          Button('继续阅读').fontSize(16).height(44).backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5260ED'))
            .onClick((): void => { this.visibleParts += 8; })
        }
      } else {
        Text('云端摘要').fontSize(14).fontColor(AppTheme.text('#8E8E93')).width('100%')
        this.Contents(this.summary)
      }
      Text('根据转写文字整理，请结合原录音核对。').fontSize(14).lineHeight(22).fontColor(AppTheme.text('#8E8E93'))
        .width('100%').margin({ top: 24 })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
