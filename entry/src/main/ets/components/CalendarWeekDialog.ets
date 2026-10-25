import { ComponentContent, UIContext } from '@kit.ArkUI';
import { AppTheme, APP_DARK_MODE_KEY } from '../utils/AppTheme';
import { HomeRecommendationViewModel } from '../datamanager/DataManagerTypes';
import { CalendarAgenda, CalendarAgendaGroup, calendarAgenda, calendarAgendaTime } from '../utils/calendar/CalendarMemoryPolicy';
import { showToastSafely } from '../utils/PromptSafe';
import { AppLogger } from '../utils/AppLogger';

class CalendarWeekParams {
  items: HomeRecommendationViewModel[] = [];
  includeCompleted: boolean = false;
  errorMessage: string = '';
  onCompleted: (id: string, completed: boolean) => void = (_id: string, _completed: boolean): void => {};
  onFinish: (openSettings: boolean) => void = (_openSettings: boolean): void => {};
}

@Component
struct CalendarWeekContent {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  params: CalendarWeekParams = new CalendarWeekParams();
  @State private includeCompleted: boolean = false;
  @State private expandedId: string = '';
  @State private completedIds: string[] = [];
  @State private now: number = Date.now();
  private timer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.includeCompleted = this.params.includeCompleted;
    this.completedIds = this.params.items.filter((item: HomeRecommendationViewModel): boolean => item.completed)
      .map((item: HomeRecommendationViewModel): string => item.id);
    this.timer = setInterval(() => { this.now = Date.now(); }, 60000);
  }
  aboutToDisappear(): void { if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; } }

  private agenda(): CalendarAgenda {
    // Completion changes only dialog-owned copies. The callback persists the
    // single occurrence; never mutate a parent @Prop item or a system event.
    let items = this.params.items.map((item: HomeRecommendationViewModel): HomeRecommendationViewModel => {
      let copy: HomeRecommendationViewModel = {
        id: item.id, title: item.title, desc: item.desc, meta: item.meta, tag: item.tag, domain: item.domain,
        color: item.color, imageRefs: item.imageRefs, thumbnailUri: item.thumbnailUri,
        sourceEventIds: item.sourceEventIds, detail: item.detail, agentTask: item.agentTask,
        completed: this.completedIds.indexOf(item.id) >= 0, calendarStart: item.calendarStart,
        calendarEnd: item.calendarEnd, calendarAllDay: item.calendarAllDay, calendarLocation: item.calendarLocation
      };
      return copy;
    });
    return calendarAgenda(items, this.now, false, this.includeCompleted);
  }

  private setCompleted(item: HomeRecommendationViewModel, completed: boolean): void {
    try {
      this.params.onCompleted(item.id, completed);
      this.completedIds = this.completedIds.filter((id: string): boolean => id !== item.id);
      if (completed) { this.completedIds = this.completedIds.concat([item.id]); }
    } catch (e) { showToastSafely('标记未保存，请重试'); }
  }

  @Builder EventRow(item: HomeRecommendationViewModel, date: string) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text(calendarAgendaTime(item, date, this.now)).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.text('#6372D8')).width(46)
        Column({ space: 4 }) {
          Text(item.title).fontSize(15).lineHeight(22).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#273148')).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if ((item.calendarLocation || '').length > 0) {
            Text(item.calendarLocation || '').fontSize(12).fontColor(AppTheme.text('#7C8496'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.expandedId === item.id ? '⌃' : '›').fontSize(20).fontColor(AppTheme.text('#98A2B3')).width(20)
      }.width('100%').constraintSize({ minHeight: 64 })
        .opacity(item.completed ? 0.6 : 1)
        .onClick(() => { this.expandedId = this.expandedId === item.id ? '' : item.id; })
      if (this.expandedId === item.id) {
        Text(item.detail).fontSize(13).lineHeight(21).fontColor(AppTheme.text('#60697C')).width('100%')
        Row({ space: 8 }) {
          Checkbox({ name: item.id }).select(item.completed).width(18).height(18).margin(0)
            .selectedColor(AppTheme.filledBackground('#6372D8'))
            .onChange((completed: boolean) => { this.setCompleted(item, completed); })
          Text('已处理').fontSize(13).fontColor(AppTheme.text('#7C8496')).layoutWeight(1)
            .onClick(() => { this.setCompleted(item, !item.completed); })
        }.width('100%').padding({ top: 4, bottom: 12 })
      }
      Divider().color(AppTheme.border('#E9ECF3')).strokeWidth(1)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16 })
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('未来一周的提醒').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Text('关闭').fontSize(14).fontColor(AppTheme.text('#7C8496')).padding({ top: 8, bottom: 8 })
          .onClick(() => { this.params.onFinish(false); })
      }.width('100%')
      Row() {
        Text('明天' + this.agenda().tomorrowCount + '项 · 未来7天共' + this.agenda().weekCount + '项')
          .fontSize(12).fontColor(AppTheme.text('#7C8496')).layoutWeight(1)
        Text(this.includeCompleted ? '全部 ▾' : '未完成 ▾').fontSize(12).fontColor(AppTheme.text('#6372D8'))
          .padding({ left: 10, top: 6, bottom: 6 }).onClick(() => { this.includeCompleted = !this.includeCompleted; })
      }.width('100%')
      if (this.params.errorMessage.length > 0) {
        Text('日历暂未更新，请到日历分析中重新授权或同步。').fontSize(13).lineHeight(21)
          .fontColor(AppTheme.text('#D54A59')).width('100%')
      }
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.agenda().groups.length === 0 && this.params.errorMessage.length === 0) {
            Text('这一周暂时没有待处理的日历安排～').fontSize(14).lineHeight(23)
              .fontColor(AppTheme.text('#7C8496')).width('100%').margin({ top: 30 })
          }
          ForEach(this.agenda().groups, (group: CalendarAgendaGroup) => {
            Column({ space: 6 }) {
              Text(group.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#7C8496'))
                .width('100%').padding({ left: 16, right: 16 })
              Column() {
                ForEach(group.items, (item: HomeRecommendationViewModel) => { this.EventRow(item, group.date) },
                  (item: HomeRecommendationViewModel): string => item.id)
              }.width('100%').backgroundColor(AppTheme.background(Color.White)).borderRadius(18).clip(true)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (group: CalendarAgendaGroup): string => group.date + ':' + group.items.map(
            (item: HomeRecommendationViewModel): string => item.id + '-' + String(item.completed)).join('|'))
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Text('管理日历与记忆').fontSize(13).fontColor(AppTheme.text('#6372D8')).width('100%')
        .padding({ top: 8, bottom: 8 }).onClick(() => { this.params.onFinish(true); })
    }.width('100%').constraintSize({ maxWidth: 600 }).height('86%').padding(20)
      .alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.pageBackground()).borderRadius(28)
  }
}

@Builder
function calendarWeekBuilder(params: CalendarWeekParams) { CalendarWeekContent({ params: params }) }

export async function showCalendarWeekDialog(uiContext: UIContext, items: HomeRecommendationViewModel[],
  includeCompleted: boolean, errorMessage: string,
  onCompleted: (id: string, completed: boolean) => void): Promise<boolean> {
  let params = new CalendarWeekParams();
  params.items = items; params.includeCompleted = includeCompleted; params.errorMessage = errorMessage;
  params.onCompleted = onCompleted;
  let content: ComponentContent<CalendarWeekParams> | null = null;
  let openSettings = false;
  let finish: (value: boolean) => void = (_value: boolean): void => {};
  let disappeared = new Promise<boolean>((resolve): void => { finish = resolve; });
  params.onFinish = (settings: boolean): void => {
    openSettings = settings;
    if (content !== null) {
      uiContext.getPromptAction().closeCustomDialog(content).catch((error: Error): void => {
        AppLogger.warnCause('Calendar', 'Cannot close week dialog', error);
        showToastSafely('弹窗关闭失败，请点击外部关闭后重试');
      });
    }
  };
  content = new ComponentContent(uiContext, wrapBuilder(calendarWeekBuilder), params);
  try {
    await uiContext.getPromptAction().openCustomDialog(content, {
      alignment: DialogAlignment.Bottom, autoCancel: true,
      onDidDisappear: (): void => { finish(openSettings); }
    });
    return await disappeared;
  } finally { content.dispose(); }
}
