import { LengthMetrics } from '@kit.ArkUI';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { HomeCategoryIcon } from '../../components/HomeCategoryIcon';
import { HomeTaskExecutionSheet } from '../../components/HomeTaskExecutionSheet';
import { HomeProfileViewModel, HomeRecommendationViewModel, CollectionImageViewModel } from '../../datamanager/DataManagerTypes';
import { createEmptyHomeProfileViewModel } from '../../datamanager/DataManagerFacade';
import { showCalendarWeekDialog } from '../../components/CalendarWeekDialog';
import { showMailTodayDialog } from '../../components/MailTodayDialog';
import { showToastSafely } from '../../utils/PromptSafe';
import { HomeTaskSuggestion, homeTaskSuggestionCategoryLabel } from './HomeTaskSuggestion';
import { homeReminderSupportsCodex } from './HomeCodexHandoff';
import { HomeComfortChatMessage, HomeComfortConcern } from './HomeEmotionalSupport';
import { HomeComfortSection, SecretaryChatInvitation } from './HomeComfortSection';
import { HomeComfortChatStore } from './HomeComfortChatStore';
import { HomeNote, HomeNoteFilter, HomeNoteSource, SecretaryAssignment, SecretaryJob, SecretaryRoute,
  canReassignJob, homeIdeaArt, homeNoteBoard, homeNoteSources, homeNoteTask, planHomeNote,
  recommendedHomeRoute, secretaryRouteLabel, secretaryStatus } from './HomeSecretary';
import { HomeSecretaryDesk } from './HomeSecretaryDesk';
import { SecretaryNoteCard } from './SecretaryNoteCard';
import { SecretaryPortrait } from './SecretaryPortrait';

@Component
export struct HomePage {
  @Prop active: boolean = false;
  @Prop navigationBottomInset: number = 0;
  @ObjectLink comfortChatStore: HomeComfortChatStore;
  @ObjectLink desk: HomeSecretaryDesk;
  @Prop profile: HomeProfileViewModel = createEmptyHomeProfileViewModel();
  @Prop taskSuggestions: HomeTaskSuggestion[] = [];
  @Prop taskSuggestionsLoading: boolean = false;
  @Prop taskSuggestionError: string = '';
  @Prop comfortConcerns: HomeComfortConcern[] = [];
  @Prop comfortConcernsLoading: boolean = false;
  @Prop comfortConcernError: string = '';
  onRefreshTaskSuggestions: () => Promise<void> = async (): Promise<void> => {};
  onRefreshComfortConcerns: () => Promise<void> = async (): Promise<void> => {};
  onSendComfortMessage: (concern: HomeComfortConcern, history: HomeComfortChatMessage[]) => Promise<string> =
    async (): Promise<string> => '';
  onSetRecommendationCompleted: (id: string, completed: boolean) => void = (): void => {};
  onDailyReview: () => void = (): void => {};
  onDelegate: (note: HomeNote, assignment: SecretaryAssignment, retry: boolean) => Promise<void> = async (): Promise<void> => {};
  onOpenJob: (job: SecretaryJob) => void = (): void => {};
  onOpenMailSettings: () => void = (): void => {};
  onOpenCalendarSettings: () => void = (): void => {};
  onMailChanged: () => void = (): void => {};

  @State private filter: HomeNoteFilter = 'all';
  @State private noteAnchor: number = 0;
  @State private boardColumns: number = 2;
  @State private boardRows: number = 2;
  @State private showCompleted: boolean = false;
  @State private sheetOpen: boolean = false;
  @State private choosingRoute: boolean = false;
  private reassigning: boolean = false;
  @State private topicsExpanded: boolean = false;
  @State private sourcesExpanded: boolean = false;
  @State private compactHeader: boolean = false;
  @State private selected: HomeNote | null = null;
  @State private lifted: HomeNote | null = null;
  @State private overSecretary: boolean = false;
  @State private bubble: string = '';
  @State private bubbleInvitesChat: boolean = false;
  @State private invitation: SecretaryChatInvitation = { sequence: 0, concernId: '' };
  private tapCount: number = 0;
  private bubbleConcernId: string = '';
  private bubbleTimer: number = -1;
  private sourceOpen: boolean = false;
  private pageScroller: Scroller = new Scroller();

  aboutToDisappear(): void {
    clearTimeout(this.bubbleTimer);
    this.endDrag();
    this.bubble = '';
  }

  private countLabel(): string {
    const count = this.profile.recommendations.filter((item: HomeRecommendationViewModel): boolean => !item.completed).length;
    const label = count > 0 ? '替你记着 ' + count + ' 件事' : '今天暂无待办';
    const canDrag = this.taskSuggestions.length > 0 || this.profile.recommendations.some((item: HomeRecommendationViewModel): boolean =>
      !item.completed && homeReminderSupportsCodex(item));
    return !this.compactHeader && canDrag ? label + ' · 长按事项拖给我' : label;
  }

  private board(): HomeNote[] {
    return homeNoteBoard(this.profile.recommendations, this.taskSuggestions, this.filter, this.showCompleted);
  }

  private resizeHome(width: number, height: number): void {
    if (!(width > 0 && height > 0)) { return; }
    this.compactHeader = height < 520;
    this.boardColumns = width >= 840 ? 4 : (width >= 600 ? 3 : 2);
    this.boardRows = width >= 600 && height - this.navigationBottomInset >= 800 ? 3 : 2;
  }

  private pageSize(): number { return this.boardColumns * this.boardRows; }

  private currentPage(count: number = this.board().length): number {
    return Math.floor(Math.min(this.noteAnchor, Math.max(0, count - 1)) / this.pageSize());
  }

  private pageCount(): number { return Math.ceil(this.board().length / this.pageSize()); }

  private turnPage(by: number): void {
    const count = this.board().length;
    const last = Math.max(0, Math.ceil(count / this.pageSize()) - 1);
    this.noteAnchor = Math.max(0, Math.min(this.currentPage(count) + by, last)) * this.pageSize();
  }

  private visibleNotes(): HomeNote[] {
    const notes = this.board();
    const start = this.currentPage(notes.length) * this.pageSize();
    return notes.slice(start, start + this.pageSize());
  }

  private currentNote(): HomeNote | undefined {
    if (!this.selected) { return undefined; }
    return homeNoteBoard(this.profile.recommendations, this.taskSuggestions, 'all', true)
      .find((note: HomeNote): boolean => note.key === this.selected?.key);
  }

  private inspect(note: HomeNote): void {
    this.selected = note;
    this.sourcesExpanded = false;
    this.choosingRoute = false;
    this.reassigning = false;
    this.sheetOpen = true;
  }

  private endDrag(): void {
    this.lifted = null;
    this.overSecretary = false;
  }

  private speak(text: string, invite: boolean = false, concernId: string = ''): void {
    clearTimeout(this.bubbleTimer);
    this.bubble = text;
    this.bubbleInvitesChat = invite;
    this.bubbleConcernId = concernId;
    this.bubbleTimer = setTimeout((): void => { this.bubble = ''; this.bubbleInvitesChat = false; }, 5500);
  }

  private greet(): void {
    const turn = this.tapCount++;
    if (turn % 4 === 2 && this.comfortConcerns.length > 0) {
      const concern = this.comfortConcerns[Math.floor(turn / 4) % this.comfortConcerns.length];
      this.speak(concern.opening || concern.title, true, concern.id);
    } else if (turn % 4 === 1) {
      this.speak('来陪我聊聊吗？', true);
    } else if (turn % 4 === 3) {
      this.speak('忙了一天，辛苦啦。想聊聊今天吗？', true);
    } else { this.speak('有什么事想交给我？'); }
  }

  private accept(note: HomeNote, retry: boolean = false): void {
    const existing = this.desk.find(note.key);
    this.inspect(note);
    if (!note.canDelegate || (retry ? !existing || !canReassignJob(existing) : !!existing || note.completed)) { return; }
    this.reassigning = retry;
    this.choosingRoute = true;
  }

  private confirmAssignment(route: SecretaryRoute, draft: string): void {
    if (!this.sheetOpen || !this.choosingRoute) { return; }
    const note = this.currentNote();
    if (!note || (note.completed && !this.reassigning)) { throw new Error('这件事已更新，请重新打开'); }
    const assignment = planHomeNote(note, route, draft);
    this.choosingRoute = false;
    this.sheetOpen = false;
    this.speak('收到，交给' + secretaryRouteLabel(route) + '办理。');
    this.onDelegate(note, assignment, this.reassigning).then((): void => {
      const job = this.desk.find(note.key);
      if (job) { this.speak(job.message); }
    }).catch((e: Error): void => {
      this.speak(e.message || '暂时无法交办，请稍后再试。');
    });
  }

  private drop(event: DragEvent): void {
    const note = this.lifted;
    this.endDrag();
    const current = note ? this.board().find((n: HomeNote): boolean => n.key === note.key) : undefined;
    if (!current || !current.canDelegate || current.completed) {
      event.setResult(DragResult.DRAG_FAILED);
      return;
    }
    event.setResult(DragResult.DRAG_SUCCESSFUL);
    this.accept(current);
  }

  private async openSource(calendar: boolean): Promise<void> {
    if (this.sourceOpen) { return; }
    this.sourceOpen = true;
    try {
      if (calendar) {
        if (await showCalendarWeekDialog(this.getUIContext(), this.profile.recommendations, true,
          this.profile.calendarError || '', this.onSetRecommendationCompleted)) { this.onOpenCalendarSettings(); }
      } else if (await showMailTodayDialog(this.getUIContext(), this.onMailChanged)) { this.onOpenMailSettings(); }
    } catch (e) { showToastSafely('暂时无法打开：' + (e as Error).message); }
    finally { this.sourceOpen = false; }
  }

  private refreshIdeas(): void {
    if (this.taskSuggestionsLoading) { return; }
    this.onRefreshTaskSuggestions().catch((e: Error): void => { showToastSafely(e.message || '推荐更新失败'); });
  }

  private toggleTopics(): void {
    this.topicsExpanded = !this.topicsExpanded;
    if (this.topicsExpanded) {
      this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    }
  }

  @Builder Greeting() {
    if (this.lifted) {
      Text(this.overSecretary ? '松手，交给我' : '拖到我这里').fontSize(21).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ui_accent_purple'))
    } else if (this.bubble) {
      Row({ space: 3 }) {
        Text(this.bubble).fontSize(15).lineHeight(21).maxLines(this.compactHeader ? 2 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.ui_text_primary')).layoutWeight(1)
        if (this.bubbleInvitesChat) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.ui_accent_purple')])
        }
      }.padding({ left: 12, right: 10, top: 8, bottom: 8 }).backgroundColor($r('app.color.ui_soft_purple'))
        .borderRadius({ topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16 })
        .onClick((): void => {
          if (this.bubbleInvitesChat) {
            this.invitation = { sequence: this.invitation.sequence + 1, concernId: this.bubbleConcernId };
          }
          this.bubble = '';
        })
    } else {
      Text() {
        Span('我是小C').fontSize(this.compactHeader ? 21 : 25).fontWeight(FontWeight.Bold)
        Span('，你的专属秘书').fontSize(16)
      }.lineHeight(31).fontColor($r('app.color.ui_text_primary'))
      Text(this.countLabel()).fontSize(13).lineHeight(20)
        .fontColor($r('app.color.ui_text_secondary'))
    }
  }

  @Builder SecretaryGroup() {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        this.Greeting()
        if (!this.lifted && !this.bubble) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.clock_arrow_2_circlepath')).fontSize(15).fontColor([$r('app.color.ui_text_muted')])
              Text('回顾你的一天').fontSize(13).fontColor($r('app.color.ui_text_secondary'))
            }
          }.height(36).padding({ left: 0, right: 8 }).backgroundColor(Color.Transparent)
            .onClick((): void => { this.onDailyReview(); })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column() {
        SecretaryPortrait({
          active: this.active, receiving: this.overSecretary,
          showHint: !this.bubble && !this.lifted && !this.topicsExpanded,
          onGreet: (): void => { this.greet(); }
        }).width('100%').layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Text('帮你解闷').fontSize(13).fontColor($r('app.color.ui_text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.ui_accent_purple')])
              .rotate({ angle: this.topicsExpanded ? 180 : 0 }).animation({ duration: 180, curve: Curve.EaseInOut })
          }
        }.width('100%').height(40).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.topicsExpanded ? '收起聊天话题' : '展开聊天话题').onClick((): void => { this.toggleTopics(); })
      }.width(this.compactHeader ? 100 : (this.boardColumns > 2 ? 164 : 135)).height('100%')
    }.width(this.boardColumns > 2 ? 430 : '100%').constraintSize({ maxWidth: this.boardColumns > 2 ? 430 : 398 })
      .height('100%').padding({ left: 18, right: 12 })
  }

  @Builder Header() {
    Row() {
      this.SecretaryGroup()
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .allowDrop(['general.plain-text'])
      .onDragEnter((): void => { this.overSecretary = this.lifted !== null; })
      .onDragLeave((): void => { this.overSecretary = false; })
      .onDrop((event: DragEvent): void => { this.drop(event); })
  }

  @Builder FilterTab(label: string, value: HomeNoteFilter) {
    Column({ space: 4 }) {
      Text(label).fontSize(15).fontWeight(this.filter === value ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.filter === value ? $r('app.color.ui_text_primary') : $r('app.color.ui_text_secondary'))
      Rect().width(15).height(2).radius(1)
        .fill(this.filter === value ? $r('app.color.ui_accent_purple') : Color.Transparent)
    }.height(44).padding({ left: 4, right: 4, top: 6 }).justifyContent(FlexAlign.Center)
      .accessibilityGroup(true).accessibilityText(label + (this.filter === value ? '，已选中' : ''))
      .onClick((): void => { this.filter = value; this.noteAnchor = 0; })
  }

  @Builder SourceButton(label: string, calendar: boolean) {
    Button(label, { type: ButtonType.Normal }).height(44).fontSize(15).fontColor($r('app.color.ui_text_secondary'))
      .backgroundColor(Color.Transparent).padding({ left: 6, right: 6 })
      .onClick((): void => { this.openSource(calendar); })
  }

  @Builder Board() {
    Column({ space: 12 }) {
      Row() {
        Scroll() {
          Row({ space: 2 }) {
            this.FilterTab('全部', 'all')
            this.FilterTab('为你提醒', 'reminder')
            this.FilterTab('猜你喜欢', 'suggestion')
            if (this.profile.mailReminder) { this.SourceButton('邮件', false) }
            if (this.profile.calendarEnabled) { this.SourceButton('日历', true) }
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          if (this.taskSuggestionsLoading) {
            LoadingProgress().width(18).height(18).color($r('app.color.ui_accent_purple'))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(19).fontColor([$r('app.color.ui_text_secondary')])
          }
        }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.taskSuggestionsLoading).accessibilityText('刷新猜你喜欢').onClick((): void => { this.refreshIdeas(); })
      }.width('100%')
      if (this.pageCount() > 0) {
        GridRow({ columns: this.boardColumns, gutter: { x: 10, y: 12 } }) {
          ForEach(this.visibleNotes(), (note: HomeNote) => {
            GridCol() {
              SecretaryNoteCard({
                note: note, status: this.jobLabel(note.key),
                onLift: (): void => { this.bubble = ''; this.lifted = note; },
                onRelease: (): void => { this.endDrag(); },
                onOpen: (): void => { this.inspect(note); }
              })
            }.height(150)
          }, (note: HomeNote): string => note.key + '/' + note.title + '/' + note.body + '/' + note.meta + '/' +
            (note.suggestion?.category || note.reminder?.tag || '') + '/' + String(note.completed) + '/' +
            String(note.canDelegate) + '/' + this.jobLabel(note.key))
        }.width('100%')
      } else {
        Text(this.filter === 'suggestion' ? (this.taskSuggestionsLoading ? '正在整理推荐' :
          (this.taskSuggestionError || '暂时没有新推荐')) : '暂时没有待办事项')
          .fontSize(16).fontColor($r('app.color.ui_text_secondary')).width('100%')
          .textAlign(TextAlign.Center).padding({ top: 25, bottom: 25 })
      }
      if (this.pageCount() > 1) {
        Row({ space: 4 }) {
          Button('‹').width(40).height(40).fontSize(22).backgroundColor(Color.Transparent)
            .fontColor($r('app.color.ui_text_secondary')).accessibilityText('上一页便签').enabled(this.currentPage() > 0)
            .onClick((): void => { this.turnPage(-1); })
          Text((this.currentPage() + 1) + ' / ' + this.pageCount()).fontSize(14)
            .fontColor($r('app.color.ui_text_secondary'))
          Button('›').width(40).height(40).fontSize(22).backgroundColor(Color.Transparent)
            .fontColor($r('app.color.ui_text_secondary')).accessibilityText('下一页便签')
            .enabled(this.currentPage() + 1 < this.pageCount())
            .onClick((): void => { this.turnPage(1); })
        }.width('100%').justifyContent(FlexAlign.Center)
      }
      if (this.filter !== 'suggestion' && this.profile.recommendations.some((item: HomeRecommendationViewModel): boolean =>
        item.completed && !item.id.startsWith('calendar:') && item.id !== 'mail:overview')) {
        Button(this.showCompleted ? '隐藏已完成' : '查看已完成').height(36).fontSize(13)
          .padding({ left: 4, right: 8 }).backgroundColor(Color.Transparent).fontColor($r('app.color.ui_text_muted'))
          .onClick((): void => { this.showCompleted = !this.showCompleted; this.noteAnchor = 0; })
      }
    }.width('92%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start)
  }

  private jobLabel(key: string): string {
    const job = this.desk.find(key);
    return job ? secretaryStatus(job.state) : '';
  }

  @Builder Content() {
    Scroll(this.pageScroller) {
      Column() {
        HomeComfortSection({ chatStore: this.comfortChatStore, concerns: this.comfortConcerns,
          expanded: this.topicsExpanded, loading: this.comfortConcernsLoading, errorMessage: this.comfortConcernError,
          invitation: this.invitation, onRefresh: this.onRefreshComfortConcerns, onSendMessage: this.onSendComfortMessage })
        this.Board()
        Blank().height(this.navigationBottomInset + 20)
      }.width('100%')
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
      // Keep sheet updates on the content node so dismissing a note leaves the animated title mounted.
      .bindSheet($$this.sheetOpen, this.SheetContent(), { height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true, showClose: true, backgroundColor: $r('app.color.ui_surface') })
  }

  @Builder Action(label: string, callback: () => void) {
    Button(label).width('100%').height(46).fontSize(16).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.ui_text_on_fill')).backgroundColor($r('app.color.ui_surface_emphasized'))
      .onClick(callback)
  }

  @Builder JobResult(job: SecretaryJob) {
    Column({ space: 7 }) {
      Text((job.route ? secretaryRouteLabel(job.route) + ' · ' : '') + secretaryStatus(job.state))
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.ui_accent_purple'))
      Text(job.message).fontSize(15).lineHeight(22).fontColor($r('app.color.ui_text_secondary'))
      if (job.sessionId) {
        Button('打开任务会话  ›').height(40).fontSize(14).backgroundColor(Color.Transparent)
          .fontColor($r('app.color.ui_accent_blue')).padding({ left: 0, right: 10 })
          .onClick((): void => { this.sheetOpen = false; this.onOpenJob(job); })
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder Sources(note: HomeNote, sources: HomeNoteSource[], images: CollectionImageViewModel[]) {
    if (sources.length > 0 || images.length > 0) {
      Column({ space: 12 }) {
        Divider().color($r('app.color.ui_border'))
        Button({ type: ButtonType.Normal }) {
          Row({ space: 9 }) {
            SymbolGlyph($r('sys.symbol.paperclip')).fontSize(16).fontColor([$r('app.color.ui_text_secondary')])
            Text('相关记录').fontSize(15).fontColor($r('app.color.ui_text_primary'))
            Blank()
            if (images.length > 0) {
              Text(images.length + ' 张图').fontSize(13).fontColor($r('app.color.ui_text_muted'))
            }
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(13).fontColor([$r('app.color.ui_text_muted')])
              .rotate({ angle: this.sourcesExpanded ? 180 : 0 }).animation({ duration: 150 })
          }.width('100%')
        }.width('100%').height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.sourcesExpanded ? '收起相关记录' : '展开相关记录')
          .onClick((): void => { this.sourcesExpanded = !this.sourcesExpanded; })
        if (this.sourcesExpanded) {
          if (images.length > 0) {
            Scroll() {
              Row({ space: 10 }) {
                ForEach(images, (image: CollectionImageViewModel) => {
                  if (image.available && image.uri) {
                    Image(image.uri).width(108).height(164).objectFit(ImageFit.Contain)
                      .backgroundColor($r('app.color.ui_surface_soft')).borderRadius(12)
                      .accessibilityText(image.label || '来源截图')
                  } else {
                    Text('原图暂不可用').fontSize(13).fontColor($r('app.color.ui_text_muted'))
                  }
                }, (image: CollectionImageViewModel): string => image.ref)
              }
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
          }
          ForEach(sources, (source: HomeNoteSource) => {
            Column({ space: 5 }) {
              if (source.meta) {
                Text(source.meta).fontSize(12).fontColor($r('app.color.ui_text_muted'))
              }
              if (source.title) {
                Text(source.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
              }
              if (source.text) {
                Text(source.text).fontSize(15).lineHeight(23).fontColor($r('app.color.ui_text_secondary'))
              }
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 12, right: 10, top: 3, bottom: 3 })
              .borderWidth({ left: 2 }).borderColor(note.suggestion ? $r('app.color.ui_soft_purple') : $r('app.color.ui_soft_gold'))
          }, (source: HomeNoteSource, index: number): string => index + '/' + source.title + '/' + source.text + '/' + source.meta)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder NoteDetail(note: HomeNote) {
    Column({ space: 18 }) {
      Row({ space: 12 }) {
        if (note.suggestion) {
          HomeCategoryIcon({ iconIndex: homeIdeaArt(note.suggestion.category), iconSize: 58 })
        }
        Column({ space: 7 }) {
          Row({ space: 7 }) {
            if (note.suggestion) {
              Text('猜你喜欢 · ' + homeTaskSuggestionCategoryLabel(note.suggestion.category))
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_accent_purple'))
            } else {
              SymbolGlyph($r('sys.symbol.bookmark_fill')).fontSize(16).fontColor([$r('app.color.ui_accent_gold')])
              Text(note.reminder?.tag || '为你提醒').fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ui_accent_gold'))
            }
            AiGeneratedBadge({ compact: true })
          }
          Text(note.title).fontSize(25).fontWeight(FontWeight.Bold).lineHeight(33).fontColor($r('app.color.ui_text_primary'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      if (note.meta) {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.bookmark')).fontSize(14).fontColor([$r('app.color.ui_accent_gold')])
          Text(note.meta).fontSize(14).fontColor($r('app.color.ui_text_secondary')).layoutWeight(1)
        }.width('100%')
      }
      if (note.body && note.body !== note.title) {
        Text(note.body).fontSize(17).lineHeight(27).fontColor($r('app.color.ui_text_secondary'))
      }
      ForEach(this.desk.jobs.filter((job: SecretaryJob): boolean => job.key === note.key), (job: SecretaryJob) => {
        this.JobResult(job)
        if (note.canDelegate && canReassignJob(job)) {
          this.Action('重新交办', (): void => { this.accept(note, true); })
        }
      }, (job: SecretaryJob): string => job.key + job.state + job.sessionId + (job.route || '') + job.message)
      if ((!this.desk.find(note.key) && note.canDelegate && !note.completed) || note.reminder) {
        Row({ space: 10 }) {
          if (!this.desk.find(note.key) && note.canDelegate && !note.completed) {
            Button('交给小C').layoutWeight(1).height(44).fontSize(16).fontWeight(FontWeight.Medium)
              .backgroundColor($r('app.color.ui_surface_emphasized')).fontColor($r('app.color.ui_text_on_fill'))
              .onClick((): void => { this.accept(note); })
          }
          if (note.reminder) {
            Button(note.completed ? '恢复待办' : '标为完成').height(44).fontSize(15)
              .backgroundColor($r('app.color.ui_surface_soft')).fontColor($r('app.color.ui_text_secondary'))
              .onClick((): void => {
                if (note.reminder) { this.onSetRecommendationCompleted(note.reminder.id, !note.completed); }
                this.sheetOpen = false;
              })
          }
        }.width('100%')
      }
      this.Sources(note, homeNoteSources(note), note.reminder?.imageRefs || [])
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder SheetContent() {
    Scroll() {
      Column({ space: 18 }) {
        if (this.currentNote()) {
          if (this.choosingRoute) {
            HomeTaskExecutionSheet({
              suggestion: homeNoteTask(this.currentNote()!), recommended: recommendedHomeRoute(this.currentNote()!),
              onExecute: (route: SecretaryRoute, draft: string): void => { this.confirmAssignment(route, draft); }
            })
          } else {
            this.NoteDetail(this.currentNote()!)
          }
        } else {
          Text('这件事已更新').fontSize(16).fontColor($r('app.color.ui_text_secondary'))
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 24, right: 24, top: 18, bottom: 30 })
    }.width('100%').height('100%').align(Alignment.Top)
  }

  build() {
    Navigation() {
      this.Content()
    }.mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: (): void => { this.Header(); }, height: this.compactHeader ? 124 : (this.boardColumns > 2 ? 208 : 190) }, {
        barStyle: BarStyle.STANDARD, backgroundColor: $r('app.color.ui_page_white'),
        paddingStart: LengthMetrics.vp(0), paddingEnd: LengthMetrics.vp(0)
      })
      .width('100%').height('100%').backgroundColor($r('app.color.ui_page_white'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .onAreaChange((_old: Area, area: Area): void => {
        this.resizeHome(parseFloat(area.width.toString()), parseFloat(area.height.toString()));
      })
  }
}
