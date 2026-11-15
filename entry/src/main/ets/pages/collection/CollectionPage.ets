import { JSON as ArkJSON } from '@kit.ArkTS';
import { CollectionFormDivider, CollectionFormInput, CollectionFormAction,
  CollectionSourceRow } from '../../components/CollectionFormControls';
import { FrostedPage } from '../../components/FrostedPage';
import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PersonalInfoSection } from './PersonalInfoSection';
import { WechatAutoSummarySettings, WechatCollectionForm } from '../../utils/wechat/WechatAutoSummarySettings';
import {
  CollectionGroupViewModel,
  CollectionViewModel
} from '../../datamanager/DataManagerTypes';
import { collectionViewModelByTabIndex, createEmptyCollectionViewModels } from '../../datamanager/DataManagerFacade';
import { dataManagerInfo } from '../../datamanager/DataManagerLog';
import { DEBUG_ENABLED_STORAGE_KEY } from '../../utils/DebugSettings';
import { memorySceneConfigs, normalizeMemorySceneId, WorkflowSceneConfig, PERSONAL_INFO_MEMORY_SCENE_ID } from '../../utils/WorkflowSceneConfig';
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

interface CollectionGroupRouteParams {
  tabIndex: number;
  groupId: string;
}

// 足迹汇总页：按场景展示采集数据、图库分析和聊天提取的信息。
// collectionModule 由 Index.ets 通过 @Link 传入，保证底部 tab 与页面内状态共享。
@Component
export struct CollectionPage {
  @StorageProp(DEBUG_ENABLED_STORAGE_KEY) private debugEnabled: boolean = false;
  private pageScroller: Scroller = new Scroller();
  private scenes: WorkflowSceneConfig[] = memorySceneConfigs();
  @Link collectionModule: number;
  @Prop secretaryNote: string = '';
  @Prop navigationBottomInset: number = 0;
  @Prop viewModels: CollectionViewModel[] = createEmptyCollectionViewModels();
  @Prop refreshing: boolean = false;
  @Prop calendarSourceSyncReady: boolean = false;
  @Prop mailSourceSyncReady: boolean = false;
  @Prop sourceSyncPending: string = '';
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
  @State private allScenesExpanded: boolean = false;
  @State private scenePreviewCount: number = 3;
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
  onQuickSyncCalendar: () => void = (): void => {};
  onQuickSyncMail: () => void = (): void => {};
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

  private visibleScenes(): WorkflowSceneConfig[] {
    if (this.allScenesExpanded || this.scenePreviewCount >= this.scenes.length) { return this.scenes; }
    const visible = this.scenes.slice(0, this.scenePreviewCount);
    const selected = this.scenes.find((scene: WorkflowSceneConfig): boolean => this.isActiveCollectionScene(scene));
    if (selected && !visible.includes(selected)) { visible[visible.length - 1] = selected; }
    return visible;
  }

  private syncLabel(): string {
    const label = this.currentView().lastUpdatedLabel;
    return label === '暂无同步' ? label : '最近同步 ' + label;
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
    Button(label, { type: ButtonType.Normal }).height(44).layoutWeight(1).fontSize(14)
      .fontWeight(this.wechatMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor($r('app.color.ui_text_primary'))
      .backgroundColor(this.wechatMode === mode ? $r('app.color.ui_surface') : Color.Transparent)
      .borderRadius(9).onClick((): void => {
        if (this.wechatAutoSummaryRunning) { return; }
        this.wechatMode = mode; this.saveWechatForm();
      })
  }

  @Builder WechatFields() {
    Column() {
      Row({ space: 3 }) {
        this.WechatModeButton('最近联系人', WECHAT_AUTO_SUMMARY_MODE_RECENT)
        this.WechatModeButton('指定联系人', WECHAT_AUTO_SUMMARY_MODE_TARGET)
      }.width('100%').padding(3).backgroundColor($r('app.color.ui_surface_soft')).borderRadius(12)
    }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
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

  @Builder SectionHeading(title: string) {
    Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ui_text_primary'))
      .maxLines(2).layoutWeight(1)
  }

  @Builder SecretaryHeader() {
    Row() {
      Image($r('app.media.collection_secretary')).width(92).height(98).objectFit(ImageFit.Contain)
        .flexShrink(0).accessibilityLevel('no')
      Shape() {
        Path().commands('M 15 0 C 13 7 8 12 0 13 C 4 17 10 19 15 18 Z')
          .fill($r('app.color.ui_surface')).strokeWidth(0)
      }.viewPort({ x: 0, y: 0, width: '15px', height: '20px' }).width(15).height(20)
        .margin({ right: -1 }).flexShrink(0).accessibilityLevel('no')
      Column({ space: 5 }) {
        Text('小 C 手记').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_accent_purple'))
        Text(this.secretaryNote || '我还在了解你。等有了足够的记录，再和你说说我的发现。')
          .fontSize(16).lineHeight(24).fontColor($r('app.color.ui_text_primary')).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 15, right: 15, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.ui_surface'))
        .borderRadius(22)
    }.width('100%')
  }

  @Builder SceneChoice(scene: WorkflowSceneConfig) {
    Button(scene.label, { type: ButtonType.Capsule }).fontSize(15)
      .fontWeight(this.isActiveCollectionScene(scene) ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.isActiveCollectionScene(scene) ? $r('app.color.ui_text_on_fill') : $r('app.color.ui_text_secondary'))
      .backgroundColor(this.isActiveCollectionScene(scene) ? $r('app.color.ui_surface_emphasized') : $r('app.color.ui_surface_soft'))
      .constraintSize({ minHeight: 40 }).padding({ left: 13, right: 13 }).margin({ right: 6, bottom: 6 })
      .accessibilityText(scene.label + (this.isActiveCollectionScene(scene) ? '，已选中' : ''))
      .onClick((): void => {
        if (!this.isActiveCollectionScene(scene)) {
          this.collectionModule = scene.sceneId;
          this.groupPageIndex = 0;
        }
      })
  }

  @Builder CollectionOverview() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        this.SectionHeading('按领域查看')
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 7 }) {
            if (this.refreshing) {
              LoadingProgress().width(16).height(16).color($r('app.color.ui_accent_blue'))
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16)
                .fontColor([$r('app.color.ui_accent_blue')])
            }
            Text(this.refreshing ? '同步中' : '同步').fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ui_accent_blue'))
          }
        }.constraintSize({ minHeight: 44 }).padding({ left: 12, right: 4 }).flexShrink(0)
          .backgroundColor(Color.Transparent).enabled(!this.refreshing)
          .accessibilityText(this.refreshing ? '正在同步记录' : '同步记录')
          .onClick((): void => {
            if (this.refreshing) { return; }
            dataManagerInfo(`Collection sync tapped: refreshing=${this.refreshing}, tab=${this.collectionModule}`);
            this.onRefresh();
          })
      }.width('100%')
      Column() {
        this.ScenePicker()
        CollectionFormDivider()
        if (this.collectionModule === PERSONAL_INFO_MEMORY_SCENE_ID) {
          PersonalInfoSection()
        }
        if (this.collectionModule !== PERSONAL_INFO_MEMORY_SCENE_ID || this.groupCount() > 0) {
          this.RecordsSection()
        }
      }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(20).clip(true)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder ScenePicker() {
    Column({ space: 2 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(this.visibleScenes(), (scene: WorkflowSceneConfig) => {
          this.SceneChoice(scene)
        }, (scene: WorkflowSceneConfig): string => scene.tabId)
        if (this.scenePreviewCount < this.scenes.length) {
          Button({ type: ButtonType.Capsule }) {
            Row({ space: 4 }) {
              Text(this.allScenesExpanded ? '收起' : '全部领域').fontSize(14).fontColor($r('app.color.ui_accent_blue'))
              SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.ui_accent_blue')])
                .rotate({ angle: this.allScenesExpanded ? 180 : 0 })
            }
          }.constraintSize({ minHeight: 40 }).padding({ left: 6, right: 8 }).margin({ bottom: 6 })
            .backgroundColor(Color.Transparent).accessibilityText(this.allScenesExpanded ? '收起领域列表' : '展开全部领域')
            .onClick((): void => { this.allScenesExpanded = !this.allScenesExpanded; })
        }
      }.width('100%').onAreaChange((_old: Area, area: Area): void => {
        // Reserve room for the longer personal-info label and the disclosure.
        const count = Math.min(this.scenes.length, Math.max(2, Math.floor((Number(area.width) - 116) / 64)));
        if (this.scenePreviewCount !== count) { this.scenePreviewCount = count; }
      })
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(this.currentView().countLabel + '记录 · ' + this.groupCount() + ' 个主题')
          .fontSize(13).fontColor($r('app.color.ui_text_secondary')).margin({ right: 10 })
        Text(this.syncLabel()).fontSize(13).fontColor($r('app.color.ui_text_muted'))
      }.width('100%')
    }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 12 }).alignItems(HorizontalAlign.Start)
  }

  @Builder AnalysisShortcut(title: string, image: Resource, start: string, end: string, route: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        Image(image).width(34).height(34).padding(6).objectFit(ImageFit.Contain)
          .linearGradient({ angle: 135, colors: [[start, 0], [end, 1]] }).borderRadius(10)
          .flexShrink(0).accessibilityLevel('no')
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
          .flexShrink(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').justifyContent(FlexAlign.Center)
    }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ left: 6, right: 6, top: 8, bottom: 8 })
      .borderRadius(0).backgroundColor(Color.Transparent).accessibilityText(title)
      .onClick((): void => { router.pushUrl({ url: route }); })
  }

  @Builder AnalysisShortcuts() {
    Row() {
      this.AnalysisShortcut('图库分析', $r('app.media.source_gallery'), '#329AA2', '#28618A', 'pages/gallery/GalleryPage')
      Divider().vertical(true).height(26).strokeWidth(0.5).color($r('app.color.ui_border'))
      this.AnalysisShortcut('录音分析', $r('app.media.source_recording_white'), '#D96B56', '#AC425F', 'pages/recording/RecordingPage')
    }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(18).clip(true)
  }

  @Builder TopicTile(group: CollectionGroupViewModel) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          if (group.thumbnailUri) {
            Image(group.thumbnailUri).width(24).height(24).objectFit(ImageFit.Cover).borderRadius(6)
              .accessibilityLevel('no')
          } else {
            SymbolGlyph($r('sys.symbol.rectangle_stack')).fontSize(16).fontColor([$r('app.color.ui_accent_blue')])
              .accessibilityLevel('no')
          }
          Text(group.meta).fontSize(12).fontColor($r('app.color.ui_text_secondary')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(11).fontColor([$r('app.color.ui_text_muted')])
        }.width('100%')
        Text(group.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (group.source || group.time) {
          Text(this.groupSubtitle(group)).fontSize(12).fontColor($r('app.color.ui_text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ minHeight: 90 }).padding(12)
      .borderRadius(13).backgroundColor($r('app.color.ui_surface_soft'))
      .accessibilityText([group.title, this.groupSubtitle(group), group.meta].join('，'))
      .onClick((): void => {
        const params: CollectionGroupRouteParams = { tabIndex: this.collectionModule, groupId: group.id };
        router.pushUrl({ url: 'pages/collection/CollectionGroupDetailPage', params: params });
      })
  }

  @Builder PageArrow(offset: number, label: string, symbol: Resource) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol).fontSize(15).fontColor([$r('app.color.ui_text_secondary')])
    }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
      .enabled(this.currentGroupPageIndex() + offset >= 0 && this.currentGroupPageIndex() + offset < this.groupPageCount())
      .accessibilityText(label).onClick((): void => { this.setGroupPage(this.currentGroupPageIndex() + offset); })
  }

  @Builder RecordsSection() {
    Column({ space: 6 }) {
      Row() {
        Text('从记录中整理').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ui_text_secondary')).layoutWeight(1)
        if (this.shouldShowGroupPagination()) {
          this.PageArrow(-1, '上一页', $r('sys.symbol.chevron_left'))
          Text(`${this.currentGroupPageIndex() + 1} / ${this.groupPageCount()}`)
            .fontSize(13).fontColor($r('app.color.ui_text_secondary')).maxLines(1)
          this.PageArrow(1, '下一页', $r('sys.symbol.chevron_right'))
        }
      }.width('100%').constraintSize({ minHeight: 24 })
      if (this.groupCount() === 0) {
        Text('这个领域还没有记录').fontSize(15).fontColor($r('app.color.ui_text_secondary'))
          .width('100%').padding({ top: 8, bottom: 12 })
      } else {
        GridRow({ columns: 2, gutter: 8,
          breakpoints: { value: ['310vp'], reference: BreakpointsReference.ComponentSize } }) {
          ForEach(this.currentPageGroups(), (group: CollectionGroupViewModel) => {
            GridCol({ span: { xs: 2, sm: this.groupCount() > 1 ? 1 : 2 } }) {
              this.TopicTile(group)
            }
          }, (group: CollectionGroupViewModel): string =>
            ArkJSON.stringify([group.id, group.title, group.source, group.time, group.meta, group.thumbnailUri]))
        }.width('100%')
      }
    }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 14 })
  }

  @Builder CollectionSourceEntries() {
    Column({ space: 8 }) {
      Row() {
        this.SectionHeading('数据来源')
        Button('管理').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_accent_blue'))
          .height(44).padding({ left: 12, right: 4 }).backgroundColor(Color.Transparent)
          .accessibilityText('管理和新增采集源').onClick(this.onOpenDataCollectionSettings)
      }.width('100%')
      Column() {
        CollectionSourceRow({ title: '日历分析', icon: $r('app.media.source_calendar'),
          showSync: true, syncEnabled: this.calendarSourceSyncReady && !this.refreshing && !this.sourceSyncPending,
          syncing: this.sourceSyncPending === 'calendar', onSync: this.onQuickSyncCalendar,
          tint: '#FF9500', onOpen: (): void => { this.onOpenCalendarAnalysis(); } })
        CollectionFormDivider()
        CollectionSourceRow({ title: '邮箱分析', icon: $r('app.media.source_mail'),
          showSync: true, syncEnabled: this.mailSourceSyncReady && !this.refreshing && !this.sourceSyncPending,
          syncing: this.sourceSyncPending === 'mail', onSync: this.onQuickSyncMail,
          onOpen: (): void => { this.onOpenMailAnalysis(); } })
      }.width('100%').backgroundColor($r('app.color.ui_surface')).borderRadius(18).clip(true)
    }.width('100%')
  }

  @Builder WechatAutoSummaryCard() {
    Column({ space: 8 }) {
      Row() { this.SectionHeading('微信快速采集') }.width('100%').constraintSize({ minHeight: 36 })
      Column() {
        this.WechatCaptureContent()
      }.width('100%').padding({ top: 12 }).backgroundColor($r('app.color.ui_surface')).borderRadius(18).clip(true)
      if (this.wechatFormError || this.wechatAutoSummaryStatus) {
        Text(this.wechatFormError || this.wechatAutoSummaryStatus).fontSize(13).lineHeight(20)
          .fontColor(this.wechatFormError || this.wechatAutoSummaryStatus.startsWith('采集失败') ?
            $r('app.color.ui_accent_red') : $r('app.color.ui_text_secondary')).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder PageHeader() {
    AppHeader({ title: '汇总' })
  }

  @Builder PageContent() {
    Scroll(this.pageScroller) {
      Column({ space: 16 }) {
        GridRow({ columns: 12, gutter: { x: 20, y: 14 },
          breakpoints: { value: ['620vp'], reference: BreakpointsReference.ComponentSize } }) {
          GridCol({ span: { xs: 12, sm: 7 } }) { this.SecretaryHeader() }
          GridCol({ span: { xs: 12, sm: 5 } }) { this.AnalysisShortcuts() }
        }.width('100%').alignItems(ItemAlign.Center)
        GridRow({ columns: 12, gutter: { x: 20, y: 24 },
          breakpoints: { value: ['620vp'], reference: BreakpointsReference.ComponentSize } }) {
          GridCol({ span: { xs: 12, sm: 7 } }) {
            this.CollectionOverview()
          }
          GridCol({ span: { xs: 12, sm: 5 } }) {
            Column({ space: 20 }) {
              this.CollectionSourceEntries()
              if (this.wechatAutoSummaryEnabled === 'true') {
                this.WechatAutoSummaryCard()
              }
              if (this.debugEnabled) {
                Button('完整检查记忆数据').fontSize(14).fontColor($r('app.color.ui_text_secondary'))
                  .height(44).backgroundColor(Color.Transparent).enabled(!this.refreshing).onClick(this.onFullCheck)
              }
            }.width('100%')
          }
        }.width('100%').alignItems(ItemAlign.Start)
      }.width('92%').constraintSize({ maxWidth: 940 })
        .padding({ top: APP_HEADER_CONTENT_GAP, bottom: this.navigationBottomInset + 24 })
    }.width('100%').height('100%').align(Alignment.Top)
      .backgroundColor($r('app.color.ui_page_background')).clip(false)
  }

  build() {
    FrostedPage({
      pageBackgroundColor: '#F6F8FC',
      scrollers: [this.pageScroller],
      headerBuilder: (): void => { this.PageHeader(); },
      contentBuilder: (): void => { this.PageContent(); }
    })
  }
}
