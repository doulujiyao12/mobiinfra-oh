import { AppTheme, APP_DARK_MODE_KEY } from '../../utils/AppTheme';
import { RecordingCalendarDay, RecordingCalendarWeek } from '../../utils/recording/RecordingCalendar';

@Component
export struct RecordingCalendarView {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @Prop monthTitle: string = '';
  @Prop weeks: RecordingCalendarWeek[] = [];
  @Prop selectedDay: string = '';
  @Prop weekIndex: number = 0;
  @Prop interactive: boolean = true;
  @State private expanded: boolean = false;
  onMonthShift: (offset: number) => void = (_offset: number): void => {};
  onDaySelect: (key: string) => void = (_key: string): void => {};
  onWeekChange: (index: number) => void = (_index: number): void => {};

  private dayColor(day: RecordingCalendarDay): ResourceColor {
    return this.selectedDay === day.key ? Color.White : AppTheme.text(day.today ? '#007AFF' : day.inMonth ? '#424B5A' : '#A3A9B4');
  }
  @Builder private Week(week: RecordingCalendarWeek) {
    Row({ space: 5 }) {
      ForEach(week.days, (day: RecordingCalendarDay) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 3 }) {
            Text(String(day.day)).fontSize(18).fontWeight(this.selectedDay === day.key ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.dayColor(day))
            Text(day.weekday).fontSize(11).fontColor(this.dayColor(day))
            Row().width(4).height(4).borderRadius(2).opacity(day.hasRecord ? 1 : 0)
              .backgroundColor(this.selectedDay === day.key ? Color.White : AppTheme.text('#007AFF'))
          }.width('100%').justifyContent(FlexAlign.Center)
        }.layoutWeight(1).height(this.expanded ? 64 : 72).padding(0).borderRadius(26)
          .backgroundColor(this.selectedDay === day.key ? AppTheme.filledBackground('#007AFF') : AppTheme.background('#EDEFF5'))
          .accessibilityText(day.key + (day.hasRecord ? '，有录音' : '，无录音') + (this.selectedDay === day.key ? '，已选中' : ''))
          .onClick((): void => { this.expanded = false; this.onDaySelect(day.key); })
      }, (day: RecordingCalendarDay): string => day.key)
    }.width('100%').height(this.expanded ? 64 : 76)
  }
  build() {
    Column({ space: 12 }) {
      Row() {
        Button('‹').fontSize(28).width(36).height(36).padding(0).fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
          .accessibilityText('上个月').onClick((): void => { this.onMonthShift(-1); })
        Button(this.monthTitle + (this.expanded ? '  ⌃' : '  ⌄')).fontSize(18).fontWeight(FontWeight.Medium)
          .layoutWeight(1).height(40).fontColor(AppTheme.text('#172033')).backgroundColor(Color.Transparent)
          .accessibilityText(this.expanded ? '收起整月日历' : '展开整月日历')
          .onClick((): void => { this.expanded = !this.expanded; })
        Button('›').fontSize(28).width(36).height(36).padding(0).fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
          .accessibilityText('下个月').onClick((): void => { this.onMonthShift(1); })
      }.width('100%')
      if (this.expanded) {
        Column({ space: 7 }) {
          ForEach(this.weeks, (week: RecordingCalendarWeek) => { this.Week(week); }, (week: RecordingCalendarWeek): string => week.key)
        }.width('100%')
      } else {
        Swiper() {
          ForEach(this.weeks, (week: RecordingCalendarWeek) => { this.Week(week); }, (week: RecordingCalendarWeek): string => week.key)
        }.width('100%').height(76).index(this.weekIndex).indicator(false).loop(false)
          .onChange((index: number): void => { this.onWeekChange(index); })
      }
    }.width('100%').padding({ bottom: 8 }).enabled(this.interactive)
  }
}
