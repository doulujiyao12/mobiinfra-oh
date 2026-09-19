import { AppHeader } from '../../components/AppHeader';
import { promptAction, router } from '@kit.ArkUI';
import {
  CollectionGroupViewModel,
  CollectionViewModel
} from '../../datamanager/DataManagerTypes';
import { collectionViewModelByTabIndex, createEmptyCollectionViewModels } from '../../datamanager/DataManagerFacade';
import { dataManagerInfo } from '../../datamanager/DataManagerLog';
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
  @Prop wechatAutoSummaryStatus: string = '';
  @State private groupPageIndex: number = 0;
  @StorageLink('wechatAutoSummaryCollectionMode') wechatMode: string = WECHAT_AUTO_SUMMARY_MODE_RECENT;
  @StorageLink('wechatAutoSummaryCollectionDaysInput') wechatDaysInput: string = '';
  @StorageLink('wechatAutoSummaryCollectionMaxContactsInput') wechatMaxContactsInput: string = '';
  @StorageLink('wechatAutoSummaryCollectionTargetContactInput') wechatTargetContactInput: string = '';
  onRefresh: () => void = () => {};
  onOpenDataCollectionSettings: () => void = () => {};
  onRunWechatAutoSummary: (request: WechatAutoSummaryRequest) => Promise<void> =
    async (request: WechatAutoSummaryRequest) => {};

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

  private wechatDefaultSummaryText(): string {
    if (this.wechatMode === WECHAT_AUTO_SUMMARY_MODE_TARGET) {
      return '当前默认：近 ' + this.wechatAutoSummaryDefaultDays + ' 天，指定联系人模式';
    }
    return '当前默认：近 ' + this.wechatAutoSummaryDefaultDays + ' 天，最近 ' +
      this.wechatAutoSummaryDefaultMaxContacts + ' 个联系人';
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

  @Builder WechatModeButton(label: string, mode: string) {
    Button(label)
      .height(38)
      .layoutWeight(1)
      .fontSize(13)
      .fontColor(this.wechatMode === mode ? Color.White : '#4F68FF')
      .backgroundColor(this.wechatMode === mode ? '#4F68FF' : '#EEF3FF')
      .borderRadius(10)
      .onClick(() => {
        if (this.wechatAutoSummaryRunning) {
          return;
        }
        this.wechatMode = mode;
      })
  }

  @Builder WechatInput(label: string, value: string, placeholder: string, onValueChange: (value: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor('#6F7684')
        .width('100%')
        .maxLines(1)
      TextInput({ placeholder: placeholder, text: value })
        .height(42)
        .width('100%')
        .fontSize(13)
        .fontColor('#161B28')
        .backgroundColor('#F2F5FC')
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .enabled(!this.wechatAutoSummaryRunning)
        .margin({ top: 6 })
        .onChange((input: string) => { onValueChange(input); })
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder WechatAutoSummaryCard() {
    if (this.wechatAutoSummaryEnabled === 'true') {
      Column() {
        Text('微信消息自动汇总')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#151A28')
          .width('100%')
          .maxLines(1)
        Text('调用 PC 侧采集服务读取微信会话，保存原始产物并写入 daily-log。')
          .fontSize(12)
          .fontColor('#6F7684')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
        Text(this.wechatDefaultSummaryText())
          .fontSize(12)
          .fontColor('#4F68FF')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })

        Row() {
          this.WechatModeButton('最近联系人', WECHAT_AUTO_SUMMARY_MODE_RECENT)
          Blank().width(10)
          this.WechatModeButton('指定联系人', WECHAT_AUTO_SUMMARY_MODE_TARGET)
        }
        .width('100%')
        .margin({ top: 14 })

        this.WechatInput('时间范围（天）', this.wechatDaysInput, '默认 ' + this.wechatAutoSummaryDefaultDays,
          (value: string) => { this.wechatDaysInput = value; })
        if (this.wechatMode === WECHAT_AUTO_SUMMARY_MODE_RECENT) {
          this.WechatInput('最近联系人数量', this.wechatMaxContactsInput,
            '默认 ' + this.wechatAutoSummaryDefaultMaxContacts,
            (value: string) => { this.wechatMaxContactsInput = value; })
        } else {
          this.WechatInput('指定联系人', this.wechatTargetContactInput, '请输入微信联系人名称',
            (value: string) => { this.wechatTargetContactInput = value; })
        }

        Button(this.wechatAutoSummaryRunning ? '采集中' : '开始采集')
          .height(44)
          .width('100%')
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(this.wechatAutoSummaryRunning ? '#A9B0C2' : '#4F68FF')
          .borderRadius(12)
          .enabled(!this.wechatAutoSummaryRunning)
          .margin({ top: 16 })
          .onClick(async () => {
            // 点击时即时归一化并校验，避免设置页默认值和卡片输入不一致。
            let request = this.buildWechatRequest();
            let error = validateWechatAutoSummaryRequest(request);
            if (error.length > 0) {
              this.showWechatToast(error);
              return;
            }
            await this.onRunWechatAutoSummary(request);
          })

        if (this.wechatAutoSummaryStatus.length > 0) {
          Text(this.wechatAutoSummaryStatus)
            .fontSize(12)
            .fontColor(this.wechatAutoSummaryStatus.startsWith('采集失败') ? '#B42318' : '#52606D')
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 10 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('92%')
      .constraintSize({ maxWidth: 720 })
      .padding(18)
      .backgroundColor(Color.White)
      .border({ width: 1, color: '#E8ECF3' })
      .borderRadius(20)
      .margin({ top: COLLECTION_SECTION_GAP })
    }
  }

  @Builder CollectTab(scene: WorkflowSceneConfig) {
    // 顶部分段控制器，切换后所有统计卡片和列表内容通过 collectionModule 派生。
    Column() {
      Text(scene.label)
        .fontSize(14)
        .fontWeight(this.isActiveCollectionScene(scene) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.isActiveCollectionScene(scene) ? '#6657E8' : '#4E5668')
        .height(34)
        .textAlign(TextAlign.Center)
        .maxLines(1)
      Row()
        .width(this.isActiveCollectionScene(scene) ? 26 : 0)
        .height(3)
        .backgroundColor('#7669FF')
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
        .backgroundColor('#F0F3F8')
        .borderRadius(14)
        .border({ width: 1, color: '#E7EBF2' })
    } else {
      Column() {
        Text('暂无图片')
          .fontSize(10)
          .fontColor('#8A92A3')
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .width(60)
      .height(60)
      .backgroundColor('#F0F3F8')
      .borderRadius(14)
      .border({ width: 1, color: '#E7EBF2' })
    }
  }

  @Builder TimelineMarker() {
    Stack({ alignContent: Alignment.Center }) {
      Divider()
        .vertical(true)
        .height(86)
        .strokeWidth(1)
        .color('#D9DDEA')
      Row()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor('#8173FF')
        .border({ width: 2, color: Color.White })
        .shadow({ radius: 4, color: '#307669FF', offsetX: 0, offsetY: 1 })
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
          .fontColor('#161C2D')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.groupSubtitle(group))
          .fontSize(12)
          .fontColor('#7A8292')
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
          .fontColor('#242A38')
          .maxLines(1)
        Text('›')
          .fontSize(25)
          .fontColor('#A2A8B5')
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
        Text('暂无已整理记录').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#151A28')
        Text('点击同步，整理采集数据及近 7 天未处理的聊天信息')
          .fontSize(12).fontColor('#7C8494').textAlign(TextAlign.Center).margin({ top: 6 })
      }.width('100%').height(92).justifyContent(FlexAlign.Center)
    } else {
      Column() {
        ForEach(this.currentPageGroups(), (group: CollectionGroupViewModel, index: number) => {
          this.GroupRow(group)
          if (index < this.currentPageGroups().length - 1) {
            Divider()
              .strokeWidth(1)
              .color('#E8EBF1')
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
          .fontColor(this.currentGroupPageIndex() > 0 ? '#8066FF' : '#A7ADBA')
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Color.Transparent)
          .enabled(this.currentGroupPageIndex() > 0)
          .onClick(() => {
            this.setGroupPage(this.currentGroupPageIndex() - 1);
          })
        Text(`${this.currentGroupPageIndex() + 1}/${this.groupPageCount()}`)
          .fontSize(13)
          .fontColor('#6D7481')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .maxLines(1)
        Button('下一页')
          .fontSize(12)
          .fontColor(this.currentGroupPageIndex() < this.groupPageCount() - 1 ? '#8066FF' : '#A7ADBA')
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Color.Transparent)
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
      .fontColor('#7F8592')
      .maxLines(1)
  }

  @Builder CollectionActionRow(icon: string, title: string, description: string,
    accentColor: string, softColor: string, onTap: () => void) {
    Row() {
      Text(icon)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(accentColor)
        .width(38)
        .height(38)
        .textAlign(TextAlign.Center)
        .backgroundColor(softColor)
        .borderRadius(12)
      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(description)
          .fontSize(11)
          .fontColor('#747C8C')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      Text('›')
        .fontSize(22)
        .fontColor('#A0A6B2')
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(68)
    .padding({ left: 14, right: 14 })
    .onClick(onTap)
  }

  @Builder CollectionOverview() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        Column() {
          Text('足迹概览')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#535C70')
            .maxLines(1)
          Row() {
            Text(this.getCollectionCount())
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor('#6C5CE7')
              .maxLines(1)
            Divider()
              .vertical(true)
              .height(32)
              .color('#DCE0EA')
              .margin({ left: 15, right: 15 })
            Text(this.groupCount().toString() + ' 个主题')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#232939')
              .maxLines(1)
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 8 })
          Row() {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor('#39C2B3')
              .margin({ right: 8 })
            Text('最近同步 ' + this.getCollectionSyncTime())
              .fontSize(12)
              .fontColor('#727A8B')
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
                .color('#7669FF')
            } else {
              Text('⟳')
                .width(32)
                .height(28)
                .fontSize(26)
                .lineHeight(28)
                .fontColor('#7669FF')
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
            .fontColor('#5F6575')
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .width(64)
        .height(64)
        .backgroundColor('#DFFFFFFF')
        .borderRadius(32)
        .border({ width: 1, color: '#C9D3DDF2' })
        .shadow({ radius: 10, color: '#141E2A58', offsetX: 0, offsetY: 4 })
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
    .backgroundColor('#F2F6FF')
    .backgroundImage($r('app.media.home_overview_background_compact'), ImageRepeat.NoRepeat)
    .backgroundImageSize(ImageSize.Cover)
    .borderRadius(24)
    .border({ width: 1, color: '#B8FFFFFF' })
    .clip(true)
    .shadow({ radius: 16, color: '#120D2A63', offsetX: 0, offsetY: 6 })
    .margin({ top: 16 })
  }

  build() {
    Scroll() {
      Column() {
        AppHeader({ title: '你的足迹', icon: $r('app.media.header_footprint_generated') })

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
              .fontColor('#151A28')
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
          this.CollectionActionRow('＋', '新增采集源', '连接更多平台与数据源',
            '#725CFF', '#F1EEFF', () => {
              this.onOpenDataCollectionSettings();
            })
          Divider()
            .color('#E8EBF2')
            .margin({ left: 64 })
          this.CollectionActionRow('图', '图库分析', '相册、截图 OCR 与分类整理',
            '#3F7FEF', '#EDF4FF', () => {
              router.pushUrl({ url: 'pages/gallery/GalleryPage' });
            })
        }
        .width('92%')
        .constraintSize({ maxWidth: 720 })
        .backgroundColor(Color.White)
        .border({ width: 1, color: '#E8ECF3' })
        .borderRadius(20)
        .clip(true)
        .margin({ top: COLLECTION_SECTION_GAP })
        Blank().height(110)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7FAFE')
  }
}
