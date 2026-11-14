import { AppTheme } from '../../utils/AppTheme';
import { RecordingCalendarView } from './RecordingCalendarView';
import { RecordingCalendarWeek, recordingCalendarMonth, recordingCalendarMonthTitle, recordingCalendarWeeks,
  recordingCalendarWeekIndex, shiftRecordingCalendarMonth } from '../../utils/recording/RecordingCalendar';
import { recordingSearchDate } from '../../utils/recording/RecordingSearch';
import { recordingTime } from '../../utils/recording/RecordingTypes';
import { RecordingWatchItem, watchRecordingDay, watchRecordingDateCounts, filterWatchRecordings,
  selectWatchRecordings } from '../../utils/recording/RecordingWatchSelection';

@Component
export struct WatchRecordingPickerView {
  @Prop @Watch('refreshCalendar') items: RecordingWatchItem[] = [];
  @Prop selectedIds: string[] = [];
  @Prop busy: boolean = false;
  @Prop autoAnalyze: boolean = true;
  @State private month: string = recordingCalendarMonth(new Date());
  @State private day: string = recordingSearchDate(new Date());
  @State private scope: string = 'day';
  @State private weeks: RecordingCalendarWeek[] = [];
  @State private weekIndex: number = 0;
  onAutoAnalyzeChange: (value: boolean) => void = (_value: boolean): void => {};
  onSelectionChange: (ids: string[]) => void = (_ids: string[]): void => {};
  onSync: () => void = (): void => {};

  aboutToAppear(): void {
    if (!this.items.some((item: RecordingWatchItem): boolean => watchRecordingDay(item) === this.day) && this.items.length > 0) {
      this.day = watchRecordingDay(this.items[0]); this.month = this.day.slice(0, 7);
    }
    this.refreshCalendar();
  }
  private refreshCalendar(): void {
    this.weeks = recordingCalendarWeeks(this.month, watchRecordingDateCounts(this.items));
    this.weekIndex = recordingCalendarWeekIndex(this.weeks, this.day || this.month + '-01');
  }
  private visibleItems(): RecordingWatchItem[] {
    if (this.scope === 'all') { return this.items; }
    if (this.scope === 'month') {
      return this.items.filter((item: RecordingWatchItem): boolean => watchRecordingDay(item).slice(0, 7) === this.month);
    }
    return filterWatchRecordings(this.items, this.day);
  }
  private chooseDay(key: string): void {
    if (this.busy) { return; }
    this.day = key; this.month = key.slice(0, 7); this.scope = 'day'; this.refreshCalendar();
  }
  private shiftMonth(offset: number): void {
    if (this.busy) { return; }
    this.month = shiftRecordingCalendarMonth(this.month, offset); this.day = ''; this.scope = 'month'; this.refreshCalendar();
  }
  private chooseToday(): void {
    if (this.busy) { return; }
    const today = recordingSearchDate(new Date()); this.chooseDay(today);
    this.onSelectionChange(selectWatchRecordings(this.items, this.selectedIds,
      filterWatchRecordings(this.items, today).map((item: RecordingWatchItem): string => item.id), true));
  }
  private allVisibleSelected(): boolean {
    const visible = this.visibleItems().filter((item: RecordingWatchItem): boolean => item.localState !== 'audio-deleted');
    return visible.length > 0 && visible.every((item: RecordingWatchItem): boolean => this.selectedIds.includes(item.id));
  }
  private toggleVisible(): void {
    if (this.busy) { return; }
    this.onSelectionChange(selectWatchRecordings(this.items, this.selectedIds,
      this.visibleItems().map((item: RecordingWatchItem): string => item.id), !this.allVisibleSelected()));
  }
  private toggleItem(item: RecordingWatchItem): void {
    if (this.busy || item.localState === 'audio-deleted') { return; }
    this.onSelectionChange(selectWatchRecordings(this.items, this.selectedIds, [item.id], !this.selectedIds.includes(item.id)));
  }
  private clock(item: RecordingWatchItem): string {
    const date = new Date(item.createdAt);
    return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
  }
  private selectionLabel(): string {
    const days: Set<string> = new Set<string>();
    for (const item of this.items) { if (this.selectedIds.includes(item.id)) { days.add(watchRecordingDay(item)); } }
    return '已选 ' + this.selectedIds.length + ' 条' + (days.size > 1 ? ' · ' + days.size + ' 天' : '');
  }
  @Builder private Calendar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('选择今天').fontSize(14).height(34).padding({ left: 12, right: 12 })
          .fontColor(AppTheme.text('#007AFF')).backgroundColor(AppTheme.background('#EAF0FB'))
          .onClick((): void => { this.chooseToday(); })
        Button('全部日期').fontSize(14).height(34).padding({ left: 12, right: 12 })
          .fontColor(AppTheme.text(this.scope === 'all' ? '#007AFF' : '#737D90')).backgroundColor(Color.Transparent)
          .onClick((): void => { this.scope = 'all'; this.day = ''; })
      }.width('100%').enabled(!this.busy)
      RecordingCalendarView({ monthTitle: recordingCalendarMonthTitle(this.month), weeks: this.weeks,
        selectedDay: this.scope === 'day' ? this.day : '', weekIndex: this.weekIndex, interactive: !this.busy,
        onMonthShift: (offset: number): void => { this.shiftMonth(offset); },
        onDaySelect: (key: string): void => { this.chooseDay(key); },
        onWeekChange: (index: number): void => { this.weekIndex = index; } })
      Row() {
        Text((this.scope === 'day' ? this.day.replace(/-/g, '/') : this.scope === 'month' ? '本月录音' : '全部录音') +
          ' · ' + this.visibleItems().length + ' 条').fontSize(13).fontColor(AppTheme.text('#737D90')).layoutWeight(1)
        Button(this.allVisibleSelected() ? '取消全选' : '全选').fontSize(14).height(36).padding({ left: 8, right: 0 })
          .fontColor(AppTheme.text('#007AFF')).backgroundColor(Color.Transparent).enabled(!this.busy && this.visibleItems().length > 0)
          .onClick((): void => { this.toggleVisible(); })
      }.width('100%')
    }.width('100%')
  }
  @Builder private Item(item: RecordingWatchItem) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(this.selectedIds.includes(item.id) ? '✓' : '').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(Color.White).textAlign(TextAlign.Center).width(24).height(24).borderRadius(12)
          .backgroundColor(this.selectedIds.includes(item.id) ? AppTheme.filledBackground('#007AFF') : Color.Transparent)
          .border({ width: this.selectedIds.includes(item.id) ? 0 : 1.5, color: AppTheme.border('#B8BFCA') })
        Column({ space: 6 }) {
          Text(item.title || '手表录音 ' + this.clock(item)).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#172033')).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text((this.scope === 'day' ? this.clock(item) : watchRecordingDay(item).replace(/-/g, '/') + ' ' + this.clock(item)) +
            ' · ' + recordingTime(item.durationMs / 1000) + ' · ' + (item.bytes / 1024 / 1024).toFixed(1) + ' MB')
            .fontSize(12).fontColor(AppTheme.text('#737D90')).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.localState !== 'new') {
            Text(item.localState === 'audio-deleted' ? '本机已移除音频' : '已同步').fontSize(12)
              .fontColor(AppTheme.text('#737D90')).width('100%')
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(AppTheme.background('#F4F5FA'))
      .enabled(!this.busy && item.localState !== 'audio-deleted')
      .accessibilityText((item.title || '手表录音') + ' ' + watchRecordingDay(item) + ' ' + this.clock(item) +
        (item.localState === 'audio-deleted' ? '，本机已移除音频' : this.selectedIds.includes(item.id) ? '，已选中' : '，未选中'))
      .onClick((): void => { this.toggleItem(item); })
  }
  build() {
    Column({ space: 12 }) {
      List({ space: 10 }) {
        ListItem() { this.Calendar() }
        if (this.visibleItems().length === 0) {
          ListItem() {
            Text('这段时间没有已完成的录音').fontSize(15).fontColor(AppTheme.text('#737D90'))
              .width('100%').textAlign(TextAlign.Center).padding({ top: 24, bottom: 24 })
          }
        }
        ForEach(this.visibleItems(), (item: RecordingWatchItem) => {
          ListItem() { this.Item(item) }
        }, (item: RecordingWatchItem): string => item.id)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      Row() {
        Text(this.selectionLabel()).fontSize(14).fontColor(AppTheme.text('#737D90')).layoutWeight(1)
        Button('清空').fontSize(14).height(36).padding({ left: 12, right: 0 }).backgroundColor(Color.Transparent)
          .fontColor(AppTheme.text('#007AFF')).enabled(!this.busy && this.selectedIds.length > 0)
          .onClick((): void => { this.onSelectionChange([]); })
      }.width('100%')
      Row() {
        Text('自动转写与摘要').fontSize(15).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoAnalyze }).enabled(!this.busy).selectedColor(AppTheme.filledBackground('#007AFF'))
          .onChange((value: boolean): void => { this.onAutoAnalyzeChange(value); })
      }.width('100%')
      Button('同步已选录音' + (this.selectedIds.length > 0 ? '（' + this.selectedIds.length + '）' : ''))
        .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium).borderRadius(24)
        .fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#007AFF'))
        .enabled(!this.busy && this.selectedIds.length > 0).onClick(this.onSync)
    }.width('100%').height('100%')
  }
}
