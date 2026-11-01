import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppTheme, APP_DARK_MODE_KEY } from '../utils/AppTheme';
import { CollectionFormGroup, CollectionFormDivider, CollectionFormSwitch, CollectionFormAction } from './CollectionFormControls';
import { CalendarMemoryStore } from '../utils/calendar/CalendarMemoryStore';
import { CalendarMemoryService } from '../utils/calendar/CalendarMemoryService';
import { CalendarMemorySettings, CalendarSource, calendarSourceSelected, defaultCalendarSettings } from '../utils/calendar/CalendarMemoryPolicy';

@Component
export struct CalendarMemoryPanel {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @Prop memoryRefreshing: boolean = false;
  onSync: () => Promise<void> = async (): Promise<void> => {};
  onMemoryChanged: () => Promise<void> = async (): Promise<void> => {};
  @State private settings: CalendarMemorySettings = defaultCalendarSettings();
  @State private sources: CalendarSource[] = [];
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private failed: boolean = false;

  private store(): CalendarMemoryStore {
    return new CalendarMemoryStore((getContext(this) as common.Context).filesDir);
  }

  aboutToAppear(): void { this.reload(); }

  private reload(): void {
    this.settings = this.store().settings();
    let snapshot = this.store().snapshot();
    this.sources = snapshot.sources;
    this.failed = snapshot.error.length > 0;
    this.status = snapshot.error || (snapshot.syncedAt ?
      '上次读取 ' + new Date(snapshot.syncedAt).toLocaleString() + ' · ' + snapshot.occurrences.length + ' 项安排' :
      '尚未读取日历，开启后需系统授权');
  }

  private async synchronize(): Promise<void> {
    if (this.busy || this.memoryRefreshing) { return; }
    this.busy = true;
    this.failed = false;
    this.status = '正在读取日历…';
    try {
      await this.onSync();
      this.reload();
    } catch (e) {
      this.failed = true;
      this.status = (e as Error).message;
    } finally { this.busy = false; }
  }

  private async toggleEnabled(enabled: boolean): Promise<void> {
    if (this.busy || this.memoryRefreshing) { return; }
    if (enabled) {
      this.busy = true;
      try {
        await CalendarMemoryService.requestAccess(getContext(this) as common.UIAbilityContext);
        let next = this.store().settings();
        next.enabled = true;
        this.store().saveSettings(next);
        this.store().markConfigured();
        this.settings = next;
      } catch (e) {
        this.status = (e as Error).message;
        this.failed = true;
        this.settings = this.store().settings();
        return;
      } finally { this.busy = false; }
      await this.synchronize();
    } else {
      let next = this.store().settings();
      next.enabled = false;
      this.store().saveSettings(next);
      this.store().markConfigured();
      this.reload();
      await this.onMemoryChanged();
    }
  }

  private async changeProfile(enabled: boolean): Promise<void> {
    let next = this.store().settings();
    next.profileEnabled = enabled;
    this.store().saveSettings(next);
    this.settings = next;
    this.busy = true;
    try { await this.onMemoryChanged(); } finally { this.busy = false; }
  }

  private async selectSource(source: CalendarSource): Promise<void> {
    let next = this.store().settings();
    if (next.excludedCalendarIds.indexOf(source.id) < 0) { next.excludedCalendarIds.push(source.id); }
    else { next.excludedCalendarIds = next.excludedCalendarIds.filter((id: number): boolean => id !== source.id); }
    this.store().saveSettings(next);
    this.settings = next;
    await this.synchronize();
  }

  private async changeRange(days: number): Promise<void> {
    let next = this.store().settings();
    next.pastDays = days;
    this.store().saveSettings(next);
    this.settings = next;
    await this.synchronize();
  }

  private async clearMemory(): Promise<void> {
    let answer = await promptAction.showDialog({ title: '清除日历记忆？',
      message: '关闭日历接入并清除本App内的日程副本和提醒，再同步移除相关画像依据。系统日历不会被修改。',
      buttons: [{ text: '取消', color: '#7C8496' }, { text: '清除', color: '#D54A59' }] });
    if (answer.index !== 1) { return; }
    this.busy = true;
    try { this.store().clear(); this.reload(); await this.onMemoryChanged(); }
    finally { this.busy = false; }
  }

  @Builder AccessFields() {
    CollectionFormSwitch({ label: '接入系统日历', selected: this.settings.enabled,
      onChangeValue: (value: boolean): void => { this.toggleEnabled(value); } })
  }
  @Builder MemoryFields() {
    Row({ space: 12 }) {
      Text('历史读取范围').fontSize(16).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Select([{ value: '过去 30 天' }, { value: '过去 90 天' }, { value: '过去 365 天' }])
        .selected([30, 90, 365].indexOf(this.settings.pastDays)).value('过去 ' + this.settings.pastDays + ' 天')
        .font({ size: 15 }).fontColor(AppTheme.text('#60697C')).optionFont({ size: 15 })
        .backgroundColor(Color.Transparent).onSelect((index: number): void => { this.changeRange([30, 90, 365][index]); })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    CollectionFormDivider()
    CollectionFormSwitch({ label: '参与个人画像', selected: this.settings.profileEnabled,
      onChangeValue: (value: boolean): void => { this.changeProfile(value); } })
  }
  @Builder SourceFields() {
    ForEach(this.sources.filter((source: CalendarSource): boolean => source.type !== 'subscribed'), (source: CalendarSource) => {
      Row({ space: 12 }) {
        Text(source.name).fontSize(16).lineHeight(23).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Text(calendarSourceSelected(source, this.settings) ? '✓' : '○').fontSize(20)
          .fontColor(AppTheme.text(calendarSourceSelected(source, this.settings) ? '#007AFF' : '#A0A6B2')).width(26)
      }.width('100%').constraintSize({ minHeight: 54 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick((): void => { this.selectSource(source); })
        .accessibilityText(source.name + (calendarSourceSelected(source, this.settings) ? '，已选择' : '，未选择'))
      CollectionFormDivider()
    }, (source: CalendarSource): string => String(source.id))
    if (this.sources.filter((source: CalendarSource): boolean => source.type !== 'subscribed').length === 0) {
      Text('读取日历后，这里会显示可选择的来源。').fontSize(14).lineHeight(22)
        .fontColor(AppTheme.text('#747C8A')).width('100%').padding(16)
    }
  }
  @Builder SyncFields() {
    CollectionFormAction({ label: this.busy || this.memoryRefreshing ? '正在同步日历…' :
      (this.failed ? '重新授权并同步' : '读取并同步记忆'), onAction: (): void => {
        if (this.failed) { this.toggleEnabled(true); } else { this.synchronize(); }
      } })
  }

  @Builder ClearFields() {
    CollectionFormAction({ label: '清除日历记忆', destructive: true, centered: true,
      onAction: (): void => { this.clearMemory(); } })
  }

  build() {
    Column() {
      CollectionFormGroup({ footer: '开启后需要系统授权；点击汇总页“同步”时更新日程。',
        contentBuilder: (): void => { this.AccessFields(); } })
      if (this.settings.enabled) {
        CollectionFormGroup({ title: '记忆与提醒',
          footer: '未来日程读取 30 天，首页只提醒未来 7 天及进行中的安排。历史日程可供聊天检索；开启画像后使用记忆模型整理历史线索，未来计划不作为已完成经历。',
          contentBuilder: (): void => { this.MemoryFields(); } })
        CollectionFormGroup({ title: '日历来源', footer: '点击选择需要同步的日历。公共订阅日历不参与读取。',
          contentBuilder: (): void => { this.SourceFields(); } })
        CollectionFormGroup({ footer: this.status, contentBuilder: (): void => { this.SyncFields(); } })
      } else {
        Text(this.status).fontSize(12).lineHeight(20).fontColor(AppTheme.text(this.failed ? '#D54A59' : '#747C8A'))
          .width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 24 })
      }
      CollectionFormGroup({ footer: '只会清除本 App 的副本与画像依据，系统日历保持不变。',
        contentBuilder: (): void => { this.ClearFields(); } })
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(!this.busy && !this.memoryRefreshing)
  }
}
