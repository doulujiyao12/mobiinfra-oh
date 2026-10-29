import { AppTheme, APP_DARK_MODE_KEY } from '../../utils/AppTheme';
import { CollectionFormGroup, CollectionFormDivider, CollectionFormInput, CollectionFormAction,
  CollectionSourceRow } from '../../components/CollectionFormControls';
import { FrostedPage } from '../../components/FrostedPage';
import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { WechatAutoSummarySettings, WechatCollectionForm } from '../../utils/wechat/WechatAutoSummarySettings';
import {
  CollectionGroupViewModel,
  CollectionViewModel
} from '../../datamanager/DataManagerTypes';
import { collectionViewModelByTabIndex, createEmptyCollectionViewModels } from '../../datamanager/DataManagerFacade';
import { dataManagerInfo } from '../../datamanager/DataManagerLog';
import { DEBUG_ENABLED_STORAGE_KEY } from '../../utils/DebugSettings';
import { memorySceneConfigs, normalizeMemorySceneId, WorkflowSceneConfig } from '../../utils/WorkflowSceneConfig';
import {
  DEFAULT_WECHAT_AUTO_SUMMARY_DAYS,
  DEFAULT_WECHAT_AUTO_SUMMARY_ENABLED,
  DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO,
  DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS,
  DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES,
  DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES,
  DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED,
  DEFAULT_WECHAT_AUTO_SUMMARY_WAIT,
  normalizeWechatAutoSummaryDays,
  normalizeWechatAutoSummaryHistorySwipeRatio,
  normalizeWechatAutoSummaryMaxContacts,
  normalizeWechatAutoSummaryMaxHistorySwipes,
  normalizeWechatAutoSummaryMode,
  normalizeWechatAutoSummaryStableSwipes,
  normalizeWechatAutoSummarySwipeSpeed,
  normalizeWechatAutoSummaryWait,
  validateWechatAutoSummaryRequest,
  WechatAutoSummaryRequest,
  WECHAT_AUTO_SUMMARY_MODE_RECENT,
  WECHAT_AUTO_SUMMARY_MODE_TARGET
} from '../../utils/wechat/WechatAutoSummaryTypes';

const COLLECTION_GROUPS_PER_PAGE: number = 5;
const COLLECTION_SECTION_GAP: number = 18;

// 足迹汇总页：按场景展示采集数据、图库分析和聊天提取的信息。
// collectionModule 由 Index.ets 通过 @Link 传入，保证底部 tab 与页面内状态共享。
@Component
export struct CollectionPage {
  @StorageProp(DEBUG_ENABLED_STORAGE_KEY) private debugEnabled: boolean = false;
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  private pageScroller: Scroller = new Scroller();
  @Link collectionModule: number;
  @Prop viewModels: CollectionViewModel[] = createEmptyCollectionViewModels();
  @Prop refreshing: boolean = false;
  @StorageLink('wechatAutoSummaryEnabled') wechatAutoSummaryEnabled: string = DEFAULT_WECHAT_AUTO_SUMMARY_ENABLED;
  @StorageLink('wechatAutoSummaryDefaultDays') wechatAutoSummaryDefaultDays: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_DAYS;
  @StorageLink('wechatAutoSummaryDefaultMaxContacts') wechatAutoSummaryDefaultMaxContacts: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_MAX_CONTACTS;
  @StorageLink('wechatAutoSummarySwipeSpeed') wechatAutoSummarySwipeSpeed: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_SWIPE_SPEED;
  @StorageLink('wechatAutoSummaryHistorySwipeRatio') wechatAutoSummaryHistorySwipeRatio: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_HISTORY_SWIPE_RATIO;
  @StorageLink('wechatAutoSummaryStableSwipes') wechatAutoSummaryStableSwipes: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_STABLE_SWIPES;
  @StorageLink('wechatAutoSummaryMaxHistorySwipes') wechatAutoSummaryMaxHistorySwipes: string =
    DEFAULT_WECHAT_AUTO_SUMMARY_MAX_HISTORY_SWIPES;
  @StorageLink('wechatAutoSummaryWait') wechatAutoSummaryWait: string = DEFAULT_WECHAT_AUTO_SUMMARY_WAIT;
  @Prop wechatAutoSummaryRunning: boolean = false;
  @Prop wechatAutoSummaryCanStop: boolean = false;
  @Prop wechatAutoSummaryStatus: string = '';
  @State private groupPageIndex: number = 0;
  @StorageLink('wechatAutoSummaryCollectionMode') wechatMode: string = WECHAT_AUTO_SUMMARY_MODE_RECENT;
  @StorageLink('wechatAutoSummaryCollectionDaysInput') wechatDaysInput: string = '';
  @StorageLink('wechatAutoSummaryCollectionMaxContactsInput') wechatMaxContactsInput: string = '';
  @StorageLink('wechatAutoSummaryCollectionTargetContactInput') wechatTargetContactInput: string = '';
  @State private wechatFormError: string = '';
  onRefresh: () => void = () => {};
  onFullCheck: () => void = () => {};
  onOpenDataCollectionSettings: () => void = () => {};
  onOpenCalendarAnalysis: () => void = () => {};
  onOpenMailAnalysis: () => void = () => {};
  onRunWechatAutoSummary: (request: WechatAutoSummaryRequest) => Promise<void> =
    async (request: WechatAutoSummaryRequest) => {};
  onStopWechatAutoSummary: () => void = (): void => {};

  aboutToAppear(): void {
    try {
      let form = WechatAutoSummarySettings.load(getContext(this) as common.Context);
      this.wechatMode = form.mode;
      this.wechatDaysInput = form.daysInput;
      this.wechatMaxContactsInput = form.maxContactsInput;
      this.wechatTargetContactInput = form.targetContactInput;
      this.wechatFormError = '';
    } catch (e) {
      this.wechatFormError = '采集参数读取失败：' + (e as Error).message;
    }
  }

  private saveWechatForm(): boolean {
    let form = new WechatCollectionForm();
    form.mode = normalizeWechatAutoSummaryMode(this.wechatMode);
    form.daysInput = this.wechatDaysInput;
    form.maxContactsInput = this.wechatMaxContactsInput;
    form.targetContactInput = this.wechatTargetContactInput;
    try {
      WechatAutoSummarySettings.save(getContext(this) as common.Context, form);
      this.wechatFormError = '';
      return true;
    } catch (e) {
      this.wechatFormError = '采集参数未保存：' + (e as Error).message;
      return false;
    }
  }

  private currentView(): CollectionViewModel {
    return collectionViewModelByTabIndex(this.viewModels, this.collectionModule);
  }

  private getCollectionTitle(): string {
    return this.currentView().title;
  }

  private getCollectionCount(): string {
    return this.currentView().countLabel;
  }

  private getCollectionSyncTime(): string {
    return this.currentView().lastUpdatedLabel;
  }

  private groupCount(): number {
    return this.currentView().groups.length;
  }

  private groupPageCount(): number {
    return Math.max(1, Math.ceil(this.groupCount() / COLLECTION_GROUPS_PER_PAGE));
  }

  private currentGroupPageIndex(): number {
    let maxPageIndex = this.groupPageCount() - 1;
    if (this.groupPageIndex < 0) {
      return 0;
    }
    if (this.groupPageIndex > maxPageIndex) {
      return maxPageIndex;
    }
    return this.groupPageIndex;
  }

  private currentPageGroups(): CollectionGroupViewModel[] {
    let start = this.currentGroupPageIndex() * COLLECTION_GROUPS_PER_PAGE;
    return this.currentView().groups.slice(start, start + COLLECTION_GROUPS_PER_PAGE);
  }

  private setGroupPage(index: number): void {
    let maxPageIndex = this.groupPageCount() - 1;
    let nextIndex = Math.max(0, Math.min(index, maxPageIndex));
    this.groupPageIndex = nextIndex;
  }

  private shouldShowGroupPagination(): boolean {
    return this.groupCount() > COLLECTION_GROUPS_PER_PAGE;
  }

  private isActiveCollectionScene(scene: WorkflowSceneConfig): boolean {
    return normalizeMemorySceneId(this.collectionModule) === scene.sceneId;
  }

  private groupSubtitle(group: CollectionGroupViewModel): string {
    let source = group.source.trim();
    let time = group.time.trim();
    if (source.length === 0) {
      return time;
    }
    if (time.length === 0) {
      return source;
    }
    return source + ' · ' + time;
  }

  private wechatInputOrDefault(input: string, fallback: string): string {
    let text = input.trim();
    if (text.length > 0) {
      return text;
    }
    return fallback;
  }

  private wechatDaysText(): string {
    return this.wechatInputOrDefault(this.wechatDaysInput, this.wechatAutoSummaryDefaultDays);
  }

  private wechatMaxContactsText(): string {
    return this.wechatInputOrDefault(this.wechatMaxContactsInput, this.wechatAutoSummaryDefaultMaxContacts);
  }

  private wechatCurrentSummaryText(): string {
    let days = normalizeWechatAutoSummaryDays(this.wechatDaysText());
    if (this.wechatMode === WECHAT_AUTO_SUMMARY_MODE_TARGET) {
      return '本次采集：近 ' + days + ' 天，指定联系人模式';
    }
    return '本次采集：近 ' + days + ' 天，最近 ' +
      normalizeWechatAutoSummaryMaxContacts(this.wechatMaxContactsText()) + ' 个联系人';
  }

  private buildWechatRequest(): WechatAutoSummaryRequest {
    let mode = normalizeWechatAutoSummaryMode(this.wechatMode);
    let targetContact = mode === WECHAT_AUTO_SUMMARY_MODE_TARGET ? this.wechatTargetContactInput.trim() : '';
    return {
      mode: mode,
      days: normalizeWechatAutoSummaryDays(this.wechatDaysText()),
      max_contacts: normalizeWechatAutoSummaryMaxContacts(this.wechatMaxContactsText()),
      target_contact: targetContact,
      swipe_speed: normalizeWechatAutoSummarySwipeSpeed(this.wechatAutoSummarySwipeSpeed),
      history_swipe_ratio: normalizeWechatAutoSummaryHistorySwipeRatio(this.wechatAutoSummaryHistorySwipeRatio),
      stable_swipes: normalizeWechatAutoSummaryStableSwipes(this.wechatAutoSummaryStableSwipes),
      max_history_swipes: normalizeWechatAutoSummaryMaxHistorySwipes(this.wechatAutoSummaryMaxHistorySwipes),
      wait: normalizeWechatAutoSummaryWait(this.wechatAutoSummaryWait)
    };
  }

  private showWechatToast(message: string): void {
    promptAction.showToast({ message: message, duration: 1600 });
  }

  private async beginWechatCollection(): Promise<void> {
    if (this.wechatAutoSummaryRunning) { this.onStopWechatAutoSummary(); return; }
    let request = this.buildWechatRequest();
    let error = validateWechatAutoSummaryRequest(request);
    if (error.length > 0) { this.showWechatToast(error); return; }
    if (!this.saveWechatForm()) { this.showWechatToast('采集参数保存失败，请重试'); return; }
    await this.onRunWechatAutoSummary(request);
  }

  @Builder WechatModeButton(label: string, mode: string) {
    Button(label, { type: ButtonType.Normal }).height(36).layoutWeight(1).fontSize(14)
      .fontWeight(this.wechatMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(AppTheme.text('#172033'))
      .backgroundColor(this.wechatMode === mode ? AppTheme.background(Color.White) : Color.Transparent)
      .borderRadius(9).onClick((): void => {
        if (this.wechatAutoSummaryRunning) { return; }
        this.wechatMode = mode; this.saveWechatForm();
      })
  }

  @Builder WechatFields() {
    Row({ space: 3 }) {
      this.WechatModeButton('最近联系人', WECHAT_AUTO_SUMMARY_MODE_RECENT)
      this.WechatModeButton('指定联系人', WECHAT_AUTO_SUMMARY_MODE_TARGET)
    }.width('100%').padding(3).backgroundColor(AppTheme.background('#F2F2F7')).borderRadius(12)
      .margin({ bottom: 8 })
    CollectionFormInput({ label: '时间范围（天）', value: this.wechatDaysInput,
      placeholder: '默认 ' + this.wechatAutoSummaryDefaultDays, inputType: InputType.Number,
      onChangeValue: (value: string): void => { this.wechatDaysInput = value; this.saveWechatForm(); } })
    CollectionFormDivider()
    if (this.wechatMode === WECHAT_AUTO_SUMMARY_MODE_RECENT) {
      CollectionFormInput({ label: '最近联系人数量', value: this.wechatMaxContactsInput,
        placeholder: '默认 ' + this.wechatAutoSummaryDefaultMaxContacts, inputType: InputType.Number,
        onChangeValue: (value: string): void => { this.wechatMaxContactsInput = value; this.saveWechatForm(); } })
    } else {
      CollectionFormInput({ label: '指定联系人', value: this.wechatTargetContactInput, placeholder: '请输入微信联系人名称',
        onChangeValue: (value: string): void => { this.wechatTargetContactInput = value; this.saveWechatForm(); } })
    }
  }

  @Builder WechatCaptureContent() {
    Column() {
      this.WechatFields()
    }.width('100%').enabled(!this.wechatAutoSummaryRunning)
    CollectionFormDivider()
    CollectionFormAction({ label: this.wechatAutoSummaryRunning ?
      (this.wechatAutoSummaryCanStop ? '停止采集' : '正在采集…') : '开始采集',
      destructive: this.wechatAutoSummaryCanStop,
      onAction: (): void => { this.beginWechatCollection(); } })
      .enabled(!this.wechatAutoSummaryRunning || this.wechatAutoSummaryCanStop)
  }

  @Builder WechatAutoSummaryCard() {
    if (this.wechatAutoSummaryEnabled === 'true') {
      Column() {
        CollectionFormGroup({ title: '微信快速采集', footer: '沿用任务页控制方式，采集结果可同步到个人记忆。',
          contentBuilder: (): void => { this.WechatCaptureContent(); } })
        if (this.wechatFormError.length > 0 || this.wechatAutoSummaryStatus.length > 0) {
          Text(this.wechatFormError || this.wechatAutoSummaryStatus).fontSize(12).lineHeight(20)
            .fontColor(AppTheme.text(this.wechatFormError || this.wechatAutoSummaryStatus.startsWith('采集失败') ? '#B42318' : '#747C8A'))
            .width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 16 })
        }
      }.width('92%').constraintSize({ maxWidth: 720 }).margin({ top: COLLECTION_SECTION_GAP })
    }
  }

  @Builder CollectTab(scene: WorkflowSceneConfig) {
    // 顶部分段控制器，切换后所有统计卡片和列表内容通过 collectionModule 派生。
    Column() {
      Text(scene.label)
        .fontSize(14)
        .fontWeight(this.isActiveCollectionScene(scene) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(AppTheme.text(this.isActiveCollectionScene(scene) ? '#6657E8' : '#4E5668'))
        .height(34)
        .textAlign(TextAlign.Center)
        .maxLines(1)
      Row()
        .width(this.isActiveCollectionScene(scene) ? 26 : 0)
        .height(3)
        .backgroundColor(AppTheme.background('#7669FF'))
        .borderRadius(2)
    }
      .justifyContent(FlexAlign.End)
      .height(42)
      .padding({ left: 14, right: 14 })
      .margin({ left: scene.sceneId === 0 ? 8 : 0 })
      .onClick(() => {
        this.collectionModule = scene.sceneId;
        this.groupPageIndex = 0;
      })
  }

  @Builder GroupThumbnail(group: CollectionGroupViewModel) {
    if (group.thumbnailUri.length > 0) {
      Image(group.thumbnailUri)
        .width(60)
        .height(60)
        .objectFit(ImageFit.Cover)
        .backgroundColor(AppTheme.background('#F0F3F8'))
        .borderRadius(14)
        .border({ width: 1, color: AppTheme.border('#E7EBF2') })
    } else {
      Column() {
        Text('暂无图片')
          .fontSize(10)
          .fontColor(AppTheme.text('#8A92A3'))
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .width(60)
      .height(60)
      .backgroundColor(AppTheme.background('#F0F3F8'))
      .borderRadius(14)
      .border({ width: 1, color: AppTheme.border('#E7EBF2') })
    }
  }

  @Builder TimelineMarker() {
    Stack({ alignContent: Alignment.Center }) {
      Divider()
        .vertical(true)
        .height(86)
        .strokeWidth(1)
        .color(AppTheme.border('#D9DDEA'))
      Row()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(AppTheme.background('#8173FF'))
        .border({ width: 2, color: AppTheme.border(Color.White) })
        .shadow({ radius: 4, color: AppTheme.shadow('#307669FF'), offsetX: 0, offsetY: 1 })
    }
    .width(20)
    .height(86)
  }

  @Builder GroupRow(group: CollectionGroupViewModel) {
    Row() {
      this.TimelineMarker()
      this.GroupThumbnail(group)
      Column() {
        Text(group.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text('#161C2D'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.groupSubtitle(group))
          .fontSize(12)
          .fontColor(AppTheme.text('#7A8292'))
          .margin({ top: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .height(72)
      .margin({ left: 13, right: 8 })
      Row() {
        Text(group.meta)
          .fontSize(14)
          .fontColor(AppTheme.text('#242A38'))
          .maxLines(1)
        Text('›')
          .fontSize(25)
          .fontColor(AppTheme.text('#A2A8B5'))
          .margin({ left: 9 })
      }
      .alignItems(VerticalAlign.Center)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(86)
    .onClick(() => {
      router.pushUrl({
        url: 'pages/collection/CollectionGroupDetailPage',
        params: {
          tabIndex: this.collectionModule,
          groupId: group.id
        }
      });
    })
  }

  @Builder CollectionRows() {
    if (this.groupCount() === 0) {
      Column() {
        Text('暂无已整理记录').fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#151A28'))
        Text('点击同步，整理采集数据及近 7 天未处理的聊天信息')
          .fontSize(12).fontColor(AppTheme.text('#7C8494')).textAlign(TextAlign.Center).margin({ top: 6 })
      }.width('100%').height(92).justifyContent(FlexAlign.Center)
    } else {
      Column() {
        ForEach(this.currentPageGroups(), (group: CollectionGroupViewModel, index: number) => {
          this.GroupRow(group)
          if (index < this.currentPageGroups().length - 1) {
            Divider()
              .strokeWidth(1)
              .color(AppTheme.border('#E8EBF1'))
              .margin({ left: 94 })
          }
        }, (group: CollectionGroupViewModel) => group.id)
      }
      .width('100%')
    }
  }

  @Builder GroupPagination() {
    if (this.shouldShowGroupPagination()) {
      Row() {
        Button('上一页')
          .fontSize(12)
          .fontColor(AppTheme.text(this.currentGroupPageIndex() > 0 ? '#8066FF' : '#A7ADBA'))
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor(AppTheme.background(Color.Transparent))
          .enabled(this.currentGroupPageIndex() > 0)
          .onClick(() => {
            this.setGroupPage(this.currentGroupPageIndex() - 1);
          })
        Text(`${this.currentGroupPageIndex() + 1}/${this.groupPageCount()}`)
          .fontSize(13)
          .fontColor(AppTheme.text('#6D7481'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .maxLines(1)
        Button('下一页')
          .fontSize(12)
          .fontColor(AppTheme.text(this.currentGroupPageIndex() < this.groupPageCount() - 1 ? '#8066FF' : '#A7ADBA'))
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor(AppTheme.background(Color.Transparent))
          .enabled(this.currentGroupPageIndex() < this.groupPageCount() - 1)
          .onClick(() => {
            this.setGroupPage(this.currentGroupPageIndex() + 1);
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
  }

  @Builder GroupRangeLabel() {
    Text(`共${this.groupCount()}组`)
      .fontSize(13)
      .fontColor(AppTheme.text('#7F8592'))
      .maxLines(1)
  }

  @Builder CollectionOverview() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        Column() {
          Text('足迹概览')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#535C70'))
            .maxLines(1)
          Row() {
            Text(this.getCollectionCount())
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.text('#6C5CE7'))
              .maxLines(1)
            Divider()
              .vertical(true)
              .height(32)
              .color(AppTheme.border('#DCE0EA'))
              .margin({ left: 15, right: 15 })
            Text(this.groupCount().toString() + ' 个主题')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.text('#232939'))
              .maxLines(1)
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 8 })
          Row() {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(AppTheme.background('#39C2B3'))
              .margin({ right: 8 })
            Text('最近同步 ' + this.getCollectionSyncTime())
              .fontSize(12)
              .fontColor(AppTheme.text('#727A8B'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .margin({ top: 9 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 1 }) {
          Stack({ alignContent: Alignment.Center }) {
            if (this.refreshing) {
              LoadingProgress()
                .width(22)
                .height(22)
                .color(AppTheme.text('#7669FF'))
            } else {
              Text('⟳')
                .width(32)
                .height(28)
                .fontSize(26)
                .lineHeight(28)
                .fontColor(AppTheme.text('#7669FF'))
                .textAlign(TextAlign.Center)
            }
          }
          .width(32)
          .height(28)

          Text(this.refreshing ? '整理中' : '同步')
            .width('100%')
            .height(18)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(AppTheme.text('#5F6575'))
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .width(64)
        .height(64)
        .backgroundColor(AppTheme.background('#DFFFFFFF'))
        .borderRadius(32)
        .border({ width: 1, color: AppTheme.border('#C9D3DDF2') })
        .shadow({ radius: 10, color: AppTheme.shadow('#141E2A58'), offsetX: 0, offsetY: 4 })
        .onClick(() => {
          dataManagerInfo(`Collection sync tapped: refreshing=${this.refreshing}, tab=${this.collectionModule}`);
          if (this.refreshing) {
            return;
          }
          this.onRefresh();
        })
      }
      .width('100%')
      .padding({ left: 22, right: 20 })
    }
    .width('92%')
    .constraintSize({ maxWidth: 720 })
    .height(128)
    .backgroundColor(AppTheme.background('#F2F6FF'))
    .backgroundImage(this.darkMode ? '' : $r('app.media.home_overview_background_compact'), ImageRepeat.NoRepeat)
    .backgroundImageSize(ImageSize.Cover)
    .borderRadius(24)
    .border({ width: 1, color: AppTheme.border('#B8FFFFFF') })
    .clip(true)
    .shadow({ radius: 16, color: AppTheme.shadow('#120D2A63'), offsetX: 0, offsetY: 6 })
    .margin({ top: 16 })
  }

  @Builder PageHeader() {
    AppHeader({ title: '你的足迹' })
  }

  @Builder CollectionSourceEntries() {
    CollectionSourceRow({ title: '新增采集源', detail: '管理已接入的数据来源', icon: $r('app.media.source_add'),
      tint: '#8E8E93', onOpen: (): void => { this.onOpenDataCollectionSettings(); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '图库分析', detail: '理解照片与截图中的内容', icon: $r('app.media.source_gallery'),
      tint: '#AF52DE', onOpen: (): void => { router.pushUrl({ url: 'pages/gallery/GalleryPage' }); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '日历分析', detail: '日程同步与一周安排', icon: $r('app.media.source_calendar'),
      tint: '#FF9500', onOpen: (): void => { this.onOpenCalendarAnalysis(); } })
    CollectionFormDivider()
    CollectionSourceRow({ title: '邮箱分析', detail: '邮箱设置与近三天邮件筛选', icon: $r('app.media.source_mail'),
      onOpen: (): void => { this.onOpenMailAnalysis(); } })
  }

  @Builder PageContent() {
    Scroll(this.pageScroller) {
      Column() {
        Scroll() {
          Row() {
            ForEach(memorySceneConfigs(), (scene: WorkflowSceneConfig) => {
              this.CollectTab(scene)
            }, (scene: WorkflowSceneConfig) => scene.tabId)
          }.padding({ left: 16, right: 16 })
        }
        .width('100%')
        .height(44)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .margin({ top: 8, bottom: 0 })

        this.CollectionOverview()

        Column() {
          Row() {
            Text(this.getCollectionTitle())
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.text('#151A28'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.GroupRangeLabel()
          }
          .width('100%')
          .margin({ bottom: 4 })
          this.CollectionRows()
          this.GroupPagination()
        }
        .width('92%')
        .constraintSize({ maxWidth: 720 })
        .margin({ top: 24 })

        this.WechatAutoSummaryCard()

        Column() {
          CollectionFormGroup({ title: '采集与分析',
            contentBuilder: (): void => { this.CollectionSourceEntries(); } })
        }.width('92%').constraintSize({ maxWidth: 720 }).margin({ top: COLLECTION_SECTION_GAP })
        if (this.debugEnabled) {
          Text('完整检查记忆数据')
            .fontSize(13)
            .fontColor(AppTheme.text('#727A8B'))
            .padding(16)
            .enabled(!this.refreshing)
            .onClick(() => { this.onFullCheck(); })
        }
        Blank().height(110)
      }
      .width('100%')
      .padding({ top: APP_HEADER_CONTENT_GAP })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background('#F7FAFE'))
    .clip(false)
  }

  build() {
    FrostedPage({
      pageBackgroundColor: '#F7FAFE',
      scrollers: [this.pageScroller],
      headerBuilder: (): void => { this.PageHeader(); },
      contentBuilder: (): void => { this.PageContent(); }
    })
  }
}
