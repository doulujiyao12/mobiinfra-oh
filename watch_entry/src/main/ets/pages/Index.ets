import { WatchState, RecordingInfo, RecordingDeleteResult, RecordingMode, RecordingSensitivity } from '../model/RecorderModels';
import { formatDuration } from '../core/Wav';
import { RecordingLibraryDay, recordingLibraryDays, recordingLibraryDateLabel, recordingsForLibraryDate } from '../core/RecordingLibrary';
import { recorderController } from '../services/RecorderController';
import { WatchTheme } from '../theme/WatchTheme';
import { SyncViewState } from '../sync/SyncProtocol';
import { phoneSyncController } from '../services/PhoneSyncController';
import { common } from '@kit.AbilityKit';
import { watchPrivacyConsent } from '../services/WatchPrivacyConsent';
import { WATCH_PRIVACY_APP_NAME, WATCH_PRIVACY_DEVELOPER, WATCH_PRIVACY_ACCEPTED_EVENT } from '../config/WatchPrivacyPolicy';
import { WatchRoundDialog } from '../components/WatchRoundDialog';
import { WatchPrivacyPolicyView } from '../components/WatchPrivacyPolicyView';
import { WatchPhoneGuide } from '../services/WatchPhoneGuide';
import { WatchCrownFocus } from '../services/WatchCrownFocus';

@Entry
@Component
struct Index {
  @State snapshot: WatchState = new WatchState();
  @State @Watch('restoreCrownFocus') screen: string = 'recorder';
  @State selected: RecordingInfo | undefined = undefined;
  @State sync: SyncViewState = new SyncViewState();
  @State libraryDate: string = '';
  @State selectionMode: boolean = false;
  @State selectedNames: string[] = [];
  @State libraryMessage: string = '';
  @State @Watch('restoreCrownFocus') private deletionTargets: RecordingInfo[] = [];
  @State @Watch('restoreCrownFocus') private privacyAccepted: boolean = false;
  @State private privacyBusy: boolean = false;
  @State private privacyError: string = '';
  @State @Watch('restoreCrownFocus') private policyVisible: boolean = false;
  @State @Watch('restoreCrownFocus') private phoneGuideVisible: boolean = false;
  @State private hidePhoneGuide: boolean = false;
  @State private phoneGuideBusy: boolean = false;
  @State private phoneGuideError: string = '';
  private phoneGuideSettings: WatchPhoneGuide | undefined = undefined;
  private pageActive: boolean = false;
  private pageVisible: boolean = false;
  private crownFocus: WatchCrownFocus = new WatchCrownFocus();
  private pageScroller: Scroller = new Scroller();
  private bars: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
  private sensitivities: RecordingSensitivity[] = ['sensitive', 'normal', 'strict'];

  aboutToAppear(): void {
    this.pageActive = true;
    this.privacyAccepted = watchPrivacyConsent.isAccepted();
    if (this.privacyAccepted) { this.preparePhoneGuide(); }
    recorderController.subscribe((value: WatchState) => {
      this.snapshot = value;
      if (this.selectedNames.length > 0) {
        this.selectedNames = this.selectedNames.filter((name: string): boolean => value.records.some((record: RecordingInfo): boolean => record.name === name));
      }
    });
    phoneSyncController.subscribe((value: SyncViewState) => { this.sync = value; });
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.onPageHide();
    recorderController.unsubscribe(); phoneSyncController.unsubscribe();
  }

  onPageShow(): void {
    this.pageVisible = true;
    this.restoreCrownFocus();
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.crownFocus.cancel();
  }

  private restoreCrownFocus(): void {
    if (!this.pageActive || !this.pageVisible) { return; }
    this.crownFocus.request(this.getUIContext(), (): string => {
      if (!this.pageActive || !this.pageVisible) { return ''; }
      return this.policyVisible ? 'watch-policy-scroll' :
        (!this.privacyAccepted || this.phoneGuideVisible || this.deletionTargets.length > 0 ?
          'watch-dialog-crown' : 'watch-page-scroll');
    });
  }

  private mainContentEnabled(): boolean {
    return this.deletionTargets.length === 0 && !this.phoneGuideVisible;
  }

  private preparePhoneGuide(): void {
    this.hidePhoneGuide = false;
    this.phoneGuideError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.phoneGuideSettings = new WatchPhoneGuide(context);
      this.phoneGuideVisible = this.phoneGuideSettings.shouldShow();
    } catch (_) { this.phoneGuideVisible = true; }
  }

  private async dismissPhoneGuide(): Promise<void> {
    if (this.phoneGuideBusy) { return; }
    this.phoneGuideBusy = true;
    this.phoneGuideError = '';
    try {
      if (this.hidePhoneGuide) {
        if (this.phoneGuideSettings === undefined) {
          this.phoneGuideSettings = new WatchPhoneGuide(this.getUIContext().getHostContext() as common.UIAbilityContext);
        }
        await this.phoneGuideSettings.dismissPermanently();
      }
      if (this.pageActive) { this.phoneGuideVisible = false; }
    } catch (_) {
      if (this.pageActive) { this.phoneGuideError = '选择未保存，请重试'; }
    } finally { if (this.pageActive) { this.phoneGuideBusy = false; } }
  }

  onBackPress(): boolean {
    if (this.policyVisible) { this.policyVisible = false; return true; }
    if (!this.privacyAccepted) { return this.privacyBusy; }
    if (this.phoneGuideVisible) { this.dismissPhoneGuide(); return true; }
    if (this.deletionTargets.length > 0) { this.deletionTargets = []; return true; }
    if (this.snapshot.status === 'deleting') { return true; }
    if (this.screen === 'dates') { this.screen = 'library'; return true; }
    if (this.screen === 'library' && this.selectionMode) { this.clearSelection(); return true; }
    if (this.screen === 'detail') {
      recorderController.stopPlayback().catch(() => {});
      this.screen = 'library';
      return true;
    }
    if (this.screen !== 'recorder') { this.screen = 'recorder'; return true; }
    return false;
  }

  private busy(): boolean {
    return this.snapshot.status === 'starting' || this.snapshot.status === 'stopping' ||
      this.snapshot.status === 'loading' || this.snapshot.status === 'deleting';
  }

  private recording(): boolean { return this.snapshot.status === 'recording'; }

  private modeLabel(): string { return this.snapshot.mode === 'speech' ? '人声' : '环境声音'; }

  private sensitivityFor(mode: RecordingMode): RecordingSensitivity {
    return mode === 'speech' ? this.snapshot.speechSensitivity : this.snapshot.soundSensitivity;
  }

  private sensitivityLabel(sensitivity: RecordingSensitivity): string {
    return sensitivity === 'sensitive' ? '灵敏' : (sensitivity === 'strict' ? '严格' : '正常');
  }

  private recordModeLabel(mode: string): string {
    return mode === 'speech' ? '人声' : (mode === 'sound' ? '声音' : '手动');
  }

  private statusLabel(): string {
    if (this.recording()) {
      if (this.snapshot.saving) { return '录音中'; }
      return this.snapshot.mode === 'speech' ? '等待人声' : '等待声音';
    }
    if (this.snapshot.status === 'starting') { return '准备中'; }
    if (this.snapshot.status === 'stopping') { return '保存中'; }
    if (this.snapshot.status === 'loading') { return '加载中'; }
    if (this.snapshot.status === 'deleting') { return '正在删除'; }
    if (this.snapshot.status === 'failed') { return '暂时无法录音'; }
    return '待录音';
  }

  private dateLabel(timestamp: number): string {
    const date: Date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日 ${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
  }

  private sizeLabel(bytes: number): string { return `${(bytes / 1024 / 1024).toFixed(1)} MB`; }

  private libraryRecords(): RecordingInfo[] { return recordingsForLibraryDate(this.snapshot.records, this.libraryDate); }

  private clearSelection(): void { this.selectedNames = []; this.selectionMode = false; }

  private chooseLibraryDate(key: string): void {
    if (this.busy() || (key && !recordingLibraryDays(this.snapshot.records).some((day: RecordingLibraryDay): boolean => day.key === key))) { return; }
    this.libraryDate = key; this.clearSelection(); this.libraryMessage = ''; this.screen = 'library';
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private toggleRecording(record: RecordingInfo): void {
    if (this.snapshot.status !== 'ready' || record.name === this.sync.currentId) { return; }
    this.selectedNames = this.selectedNames.indexOf(record.name) >= 0 ?
      this.selectedNames.filter((name: string): boolean => name !== record.name) : this.selectedNames.concat([record.name]);
  }

  private selectableRecords(): RecordingInfo[] {
    return this.libraryRecords().filter((record: RecordingInfo): boolean => record.name !== this.sync.currentId);
  }

  private allRecordsSelected(): boolean {
    const records: RecordingInfo[] = this.selectableRecords();
    return records.length > 0 && records.every((record: RecordingInfo): boolean => this.selectedNames.indexOf(record.name) >= 0);
  }

  private toggleAllRecords(): void {
    if (this.snapshot.status !== 'ready') { return; }
    this.selectedNames = this.allRecordsSelected() ? [] : this.selectableRecords().map((record: RecordingInfo): string => record.name);
  }

  private confirmSelectedDeletion(): void {
    const records: RecordingInfo[] = this.libraryRecords().filter((record: RecordingInfo): boolean => this.selectedNames.indexOf(record.name) >= 0);
    this.confirmDeletion(records);
  }

  private confirmDelete(record: RecordingInfo): void {
    this.confirmDeletion([record]);
  }

  private confirmDeletion(records: RecordingInfo[]): void {
    if (records.length === 0 || this.snapshot.status !== 'ready') { return; }
    this.deletionTargets = records.slice();
  }

  private deleteConfirmed(): void {
    if (this.deletionTargets.length === 0 || this.snapshot.status !== 'ready') { return; }
    const targets = this.deletionTargets.slice();
    this.deletionTargets = [];
    this.deleteFromLibrary(targets).catch(() => {});
  }

  private async agreePrivacy(): Promise<void> {
    if (this.privacyBusy) { return; }
    this.privacyBusy = true; this.privacyError = '';
    try {
      await watchPrivacyConsent.accept();
      if (!this.pageActive) { return; }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.eventHub.emit(WATCH_PRIVACY_ACCEPTED_EVENT);
      this.privacyAccepted = true;
      this.preparePhoneGuide();
    } catch (error) {
      if (this.pageActive) { this.privacyError = (error as Error).message; }
    } finally { if (this.pageActive) { this.privacyBusy = false; } }
  }

  private async declinePrivacy(): Promise<void> {
    if (this.privacyBusy) { return; }
    this.privacyBusy = true; this.privacyError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.terminateSelf();
    } catch (_) {
      if (this.pageActive) { this.privacyError = '暂时无法退出，可按返回键退出应用'; }
    } finally { if (this.pageActive) { this.privacyBusy = false; } }
  }

  private async deleteFromLibrary(records: RecordingInfo[]): Promise<void> {
    this.libraryMessage = ''; this.selected = undefined; this.screen = 'library';
    try {
      const result: RecordingDeleteResult = await recorderController.deleteRecordings(records);
      this.selectedNames = this.selectedNames.filter((name: string): boolean => result.deletedNames.indexOf(name) < 0);
      this.selectionMode = this.selectedNames.length > 0;
      this.libraryMessage = `已删除 ${result.deletedNames.length} 段录音` +
        (result.failedNames.length > 0 ? `，${result.failedNames.length} 段未删除` : '') +
        (result.protectedNames.length > 0 ? `，${result.protectedNames.length} 段正在同步，已保留` : '');
    } catch (error) { this.libraryMessage = (error as Error).message; }
  }

  @Builder
  waveform() {
    Row({ space: 3 }) {
      ForEach(this.bars, (index: number) => {
        Rect()
          .width(4)
          .height(this.recording() ? 6 + this.snapshot.level * (4 + (7 - Math.abs(index - 7)) * 2) : 5)
          .radius(2)
          .fill(this.recording() ? WatchTheme.primaryLight : WatchTheme.waveformIdle)
      }, (index: number) => index.toString())
    }
    .height(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  recorder() {
    Column({ space: 4 }) {
      Row({ space: 7 }) {
        Image($r('app.media.clawmate_mascot')).width(32).height(32)
          .sourceSize({ width: 128, height: 128 }).objectFit(ImageFit.Contain).accessibilityLevel('no')
        Text('ClawMate').fontSize(13).fontWeight(FontWeight.Medium).fontColor(WatchTheme.textSecondary)
      }.width('100%').height(32).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      Text(this.statusLabel()).fontSize(13).fontColor(this.recording() ? WatchTheme.primaryLight : WatchTheme.textSecondary)
      Text(formatDuration(this.snapshot.durationMs))
        .fontSize(36).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
        .fontFamily('monospace').maxLines(1).margin({ top: 2 })
        .accessibilityText('已保存时长 ' + formatDuration(this.snapshot.durationMs))
      this.waveform()
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.recording()) {
            Rect().width(12).height(12).radius(3).fill(WatchTheme.onPrimaryLight)
          } else {
            Circle().width(12).height(12).fill(WatchTheme.onPrimary)
          }
          Text(this.recording() ? '停止录音' : (this.busy() ? '请稍候' : '开始录音'))
            .fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.recording() ? WatchTheme.onPrimaryLight : WatchTheme.onPrimary)
        }.justifyContent(FlexAlign.Center)
      }
      .width('86%').height(40)
      .backgroundColor(this.recording() ? WatchTheme.primaryLight : WatchTheme.primary)
      .fontColor(this.recording() ? WatchTheme.onPrimaryLight : WatchTheme.onPrimary)
      .enabled(!this.busy() && this.snapshot.status !== 'failed')
      .onClick(() => {
        if (this.recording()) { recorderController.stop(); }
        else { recorderController.start().catch(() => {}); }
      })
      if (this.recording()) {
        Text(`监听 ${formatDuration(this.snapshot.listeningMs)}`)
          .fontSize(11).fontColor(WatchTheme.textMuted).margin({ top: 5 })
      } else {
        Button(`${this.modeLabel()} · ${this.sensitivityLabel(this.sensitivityFor(this.snapshot.mode))}`)
          .width('92%').height(30).fontSize(12)
          .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).margin({ top: 4 })
          .enabled(this.snapshot.status === 'ready')
          .onClick(() => { this.screen = 'mode'; })
        Button(`录音库 · ${this.snapshot.records.length}`)
          .width('80%').height(28).fontSize(12)
          .fontColor(WatchTheme.textSecondary).backgroundColor(WatchTheme.surface).margin({ top: 4 })
          .enabled(!this.busy())
          .onClick(() => { this.clearSelection(); this.libraryMessage = ''; recorderController.refresh(); this.screen = 'library'; })
      }
      if (this.snapshot.error.length > 0) {
        Text(this.snapshot.error).fontSize(12).fontColor(WatchTheme.error).textAlign(TextAlign.Center)
          .margin({ top: 8 }).width('90%')
      } else if (this.snapshot.notice.length > 0 && !this.recording()) {
        Text(this.snapshot.notice).fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
          .margin({ top: 5 }).width('90%')
      }
      Button('手机同步').width('80%').height(28).fontSize(12)
        .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface)
        .onClick(() => { this.screen = 'sync'; })
      Button('隐私政策').width('80%').height(26).fontSize(11).padding(0)
        .fontColor(WatchTheme.textMuted).backgroundColor(Color.Transparent)
        .onClick((): void => { this.policyVisible = true; })
    }.width('100%')
  }

  @Builder
  syncPage() {
    Column({ space: 10 }) {
      Text('手机同步').fontSize(20).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
      if (this.sync.peerName.length > 0) {
        Text(this.sync.peerName).fontSize(12).fontColor(WatchTheme.textMuted)
      }
      Text(this.sync.message).fontSize(14).fontColor(WatchTheme.primaryLight).textAlign(TextAlign.Center)
      if (this.sync.status === 'waiting') {
        Column({ space: 8 }) {
          this.PhoneConnectionInstructions()
        }.width('100%').padding(10).borderRadius(16).backgroundColor(WatchTheme.surface)
      }
      if (this.sync.status === 'transferring' || this.sync.status === 'awaiting_ack') {
        Text(`${Math.round(this.sync.progress)}%`).fontSize(30).fontColor(WatchTheme.text)
      }
      Text(`已同步 ${this.sync.syncedIds.length} 段`)
        .fontSize(12).fontColor(WatchTheme.textSecondary)
      Button('重新连接').width('90%').height(36).fontSize(14)
        .fontColor(WatchTheme.onPrimary).backgroundColor(WatchTheme.primary)
        .enabled(this.sync.status !== 'connecting' && this.sync.currentId.length === 0 && this.sync.status !== 'unsupported')
        .onClick(() => { phoneSyncController.reconnect().catch(() => {}); })
      Button('返回录音').height(32).fontSize(12).backgroundColor(Color.Transparent).fontColor(WatchTheme.textMuted)
        .onClick(() => { this.screen = 'recorder'; })
    }.width('100%')
  }

  @Builder
  sensitivityOptions(mode: RecordingMode) {
    Row({ space: 4 }) {
      ForEach(this.sensitivities, (sensitivity: RecordingSensitivity) => {
        Button(this.sensitivityLabel(sensitivity)).layoutWeight(1).height(32).padding(0).fontSize(13)
          .fontColor(this.sensitivityFor(mode) === sensitivity ? WatchTheme.onPrimary : WatchTheme.textSecondary)
          .backgroundColor(this.sensitivityFor(mode) === sensitivity ? WatchTheme.primary : WatchTheme.background)
          .enabled(this.snapshot.status === 'ready')
          .accessibilityText((mode === 'speech' ? '人声' : '环境声音') + '，' + this.sensitivityLabel(sensitivity) +
            (this.sensitivityFor(mode) === sensitivity ? '，已选择' : ''))
          .onClick((): void => { recorderController.selectSensitivity(mode, sensitivity).catch(() => {}); })
      }, (sensitivity: RecordingSensitivity): string => sensitivity)
    }.width('100%')
  }

  @Builder
  modePicker() {
    Column({ space: 10 }) {
      Text('录音模式').fontSize(20).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
      Column({ space: 6 }) {
        Button(this.snapshot.mode === 'sound' ? '✓ 环境声音' : '环境声音').fontSize(15).fontColor(WatchTheme.text)
          .width('100%').height(36).padding(0)
          .backgroundColor(this.snapshot.mode === 'sound' ? WatchTheme.primarySurface : Color.Transparent)
          .enabled(this.snapshot.status === 'ready')
          .onClick(() => { recorderController.selectMode('sound').catch(() => {}); })
        this.sensitivityOptions('sound')
      }.width('100%').padding(8).borderRadius(22).backgroundColor(WatchTheme.surface)
      Column({ space: 6 }) {
        Button(this.snapshot.mode === 'speech' ? '✓ 人声' : '人声').fontSize(15).fontColor(WatchTheme.text)
          .width('100%').height(36).padding(0)
          .backgroundColor(this.snapshot.mode === 'speech' ? WatchTheme.primarySurface : Color.Transparent)
          .enabled(this.snapshot.status === 'ready')
          .onClick(() => { recorderController.selectMode('speech').catch(() => {}); })
        this.sensitivityOptions('speech')
      }.width('100%').padding(8).borderRadius(22).backgroundColor(WatchTheme.surface)
      if (this.snapshot.error.length > 0) {
        Text(this.snapshot.error).fontSize(11).fontColor(WatchTheme.error).textAlign(TextAlign.Center)
      }
      Button('返回录音').height(36).width('85%').fontSize(13)
        .fontColor(WatchTheme.onPrimary).backgroundColor(WatchTheme.primary)
        .onClick(() => { this.screen = 'recorder'; })
    }.width('100%')
  }

  @Builder
  library() {
    Column({ space: 8 }) {
      Text('录音库').fontSize(20).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
        .width('100%').textAlign(TextAlign.Center).margin({ bottom: 4 })
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Text(recordingLibraryDateLabel(this.libraryDate)).fontSize(12).fontColor(WatchTheme.primaryLight)
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
            Text(`${this.libraryRecords().length} 段`).fontSize(10).fontColor(WatchTheme.textMuted).maxLines(1).flexShrink(0)
            Text('⌄').fontSize(12).fontColor(WatchTheme.primaryLight).flexShrink(0)
          }.width('100%').padding({ left: 10, right: 10 }).alignItems(VerticalAlign.Center)
        }.height(34).layoutWeight(1).padding(0).borderRadius(17)
          .backgroundColor(WatchTheme.surface).enabled(!this.busy()).accessibilityText('选择录音日期')
          .onClick(() => { this.screen = 'dates'; })
        Button(this.selectionMode ? '完成' : '多选').fontSize(12).width(50).height(34).padding(0).borderRadius(17)
          .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface)
          .enabled(!this.busy() && (this.selectionMode || this.libraryRecords().length > 0))
          .onClick(() => { if (this.selectionMode) { this.clearSelection(); } else { this.selectionMode = true; this.libraryMessage = ''; } })
      }.width('100%')
      if (this.selectionMode) {
        Row({ space: 8 }) {
          Button(this.allRecordsSelected() ? '取消全选' : '全选').height(34).fontSize(12).layoutWeight(1)
            .padding({ left: 4, right: 4 })
            .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface)
            .enabled(this.snapshot.status === 'ready' && this.selectableRecords().length > 0).onClick(() => { this.toggleAllRecords(); })
          Button(`删除 ${this.selectedNames.length}`).height(34).fontSize(12).layoutWeight(1)
            .padding({ left: 4, right: 4 })
            .fontColor(WatchTheme.danger).backgroundColor(WatchTheme.dangerSurface)
            .enabled(this.snapshot.status === 'ready' && this.selectedNames.length > 0).onClick(() => { this.confirmSelectedDeletion(); })
        }.width('100%')
      }
      if (this.snapshot.status === 'deleting') {
        Text('正在删除…').fontSize(12).fontColor(WatchTheme.primaryLight)
      } else if (this.libraryMessage || this.snapshot.error) {
        Text(this.libraryMessage || this.snapshot.error).fontSize(12).fontColor(WatchTheme.textSecondary).textAlign(TextAlign.Center)
      }
      if (this.libraryRecords().length === 0) {
        Image($r('app.media.clawmate_mascot')).width(48).height(48)
          .sourceSize({ width: 128, height: 128 }).objectFit(ImageFit.Contain).accessibilityLevel('no').margin({ top: 12 })
        Text(this.libraryDate ? '当天没有录音' : '还没有录音').fontSize(16).fontColor(WatchTheme.textSecondary)
      } else {
        ForEach(this.libraryRecords(), (record: RecordingInfo) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              if (this.selectionMode) {
                Text(this.selectedNames.indexOf(record.name) >= 0 ? '✓' : '○').fontSize(20).width(22).fontColor(WatchTheme.primaryLight)
              }
              Column({ space: 5 }) {
                Text(this.dateLabel(record.createdAt)).fontSize(14).fontColor(WatchTheme.text)
                Text(`${formatDuration(record.durationMs)} · ${this.sizeLabel(record.bytes)} · ${this.recordModeLabel(record.mode)}`)
                  .fontSize(10).fontColor(WatchTheme.textMuted)
                Text(this.sync.currentId === record.name ? '正在同步' :
                  (this.sync.syncedIds.indexOf(record.name) >= 0 ? '已同步' : '待同步'))
                  .fontSize(10).fontColor(WatchTheme.primaryLight)
              }.layoutWeight(1)
            }.width('100%').padding(12)
          }
          .width('100%').borderRadius(20)
          .backgroundColor(this.selectionMode && this.selectedNames.indexOf(record.name) >= 0 ? WatchTheme.primarySurface : WatchTheme.surface)
          .enabled(!this.busy() && (!this.selectionMode || record.name !== this.sync.currentId))
          .onClick(() => {
            if (this.selectionMode) { this.toggleRecording(record); }
            else { this.selected = record; this.screen = 'detail'; }
          })
        }, (record: RecordingInfo) => record.name)
      }
      Button('返回录音').height(36).width('85%').fontSize(13)
        .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).margin({ top: 6 })
        .enabled(!this.busy()).onClick(() => { this.clearSelection(); this.screen = 'recorder'; })
    }.width('100%')
  }

  @Builder
  libraryDatePicker() {
    Column({ space: 8 }) {
      Text('选择日期').fontSize(20).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
      Button(this.libraryDate === '' ? '✓ 全部日期' : '全部日期').width('100%').height(38).fontSize(14)
        .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).onClick(() => { this.chooseLibraryDate(''); })
      ForEach(recordingLibraryDays(this.snapshot.records), (day: RecordingLibraryDay) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text((this.libraryDate === day.key ? '✓ ' : '') + recordingLibraryDateLabel(day.key)).fontSize(13)
              .fontColor(WatchTheme.text).layoutWeight(1)
            Text(`${day.count} 段`).fontSize(11).fontColor(WatchTheme.textMuted)
          }.padding(12).width('100%')
        }.width('100%').borderRadius(20).backgroundColor(WatchTheme.surface).onClick(() => { this.chooseLibraryDate(day.key); })
      }, (day: RecordingLibraryDay): string => day.key)
      Button('返回录音库').height(34).fontSize(12).backgroundColor(Color.Transparent).fontColor(WatchTheme.textMuted)
        .onClick(() => { this.screen = 'library'; })
    }.width('100%')
  }

  @Builder
  detail() {
    Column({ space: 10 }) {
      if (this.selected !== undefined) {
        Text(this.dateLabel(this.selected.createdAt)).fontSize(17).fontColor(WatchTheme.text)
        Text(this.snapshot.playingName === this.selected.name ?
          formatDuration(this.snapshot.playbackMs) : formatDuration(this.selected.durationMs))
          .fontSize(36).fontColor(WatchTheme.primaryLight).fontFamily('monospace')
        Text(`${this.sizeLabel(this.selected.bytes)} · ${this.recordModeLabel(this.selected.mode)}`)
          .fontSize(11).fontColor(WatchTheme.textMuted)
        Button(this.snapshot.playingName === this.selected.name ?
          (this.snapshot.playbackStatus === 'loading' ? '正在加载' : '停止播放') : '播放录音')
          .height(42).width('92%').fontSize(15).fontColor(WatchTheme.onPrimary).backgroundColor(WatchTheme.primary)
          .enabled(this.snapshot.status === 'ready' && this.snapshot.playbackStatus !== 'loading')
          .onClick(() => {
            if (this.selected !== undefined) {
              if (this.snapshot.playingName === this.selected.name) {
                recorderController.stopPlayback().catch(() => {});
              } else { recorderController.play(this.selected).catch(() => {}); }
            }
          })
        Button('删除录音').width('85%').height(34).fontSize(13)
          .fontColor(WatchTheme.danger).backgroundColor(WatchTheme.dangerSurface)
          .enabled(this.snapshot.status === 'ready' && this.sync.currentId !== this.selected.name)
          .onClick(() => { if (this.selected !== undefined) { this.confirmDelete(this.selected); } })
        if (this.snapshot.error.length > 0) {
          Text(this.snapshot.error).fontSize(11).fontColor(WatchTheme.error).textAlign(TextAlign.Center)
        }
        Button('返回录音库').height(30).fontSize(12).backgroundColor(Color.Transparent).fontColor(WatchTheme.textMuted)
          .onClick(() => {
            recorderController.stopPlayback().catch(() => {});
            this.screen = 'library';
          })
      }
    }.width('100%')
  }

  @Builder private MainContent() {
    Scroll(this.pageScroller) {
      Column() {
        if (this.screen === 'library') { this.library(); }
        else if (this.screen === 'dates') { this.libraryDatePicker(); }
        else if (this.screen === 'detail') { this.detail(); }
        else if (this.screen === 'mode') { this.modePicker(); }
        else if (this.screen === 'sync') { this.syncPage(); }
        else { this.recorder(); }
      }
      .width('100%').padding({ left: 28, right: 28, top: 24, bottom: 42 })
      .constraintSize({ minHeight: '100%' })
    }
    .width('100%').height('100%').backgroundColor(WatchTheme.background)
    .scrollBar(BarState.Off)
    .id('watch-page-scroll').focusable(this.mainContentEnabled()).defaultFocus(true).focusOnTouch(true)
    .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
    .onAppear((): void => { this.restoreCrownFocus(); })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Up) { this.restoreCrownFocus(); }
    })
    .enabled(this.mainContentEnabled())
    .accessibilityLevel(this.mainContentEnabled() ? 'auto' : 'no-hide-descendants')
  }

  @Builder private PhoneConnectionInstructions() {
    Text('如需连接手机，请下载手机端 ClawMate。').fontSize(13).lineHeight(18)
      .fontColor(WatchTheme.textSecondary).width('100%')
    Text('汇总 → 录音分析\n→ 连接手表').fontSize(14).lineHeight(20)
      .fontColor(WatchTheme.primaryLight).width('100%').textAlign(TextAlign.Center)
    Text('目前仅支持 HarmonyOS 5.0 及以上版本的手机端应用同步。').fontSize(12).lineHeight(17)
      .fontColor(WatchTheme.textSecondary).width('100%')
  }

  @Builder private PhoneGuideMessage() {
    this.PhoneConnectionInstructions()
    if (this.phoneGuideError) {
      Text(this.phoneGuideError).fontSize(12).fontColor(WatchTheme.error).width('100%')
    }
  }

  @Builder private PhoneGuideChoice() {
    Row({ space: 4 }) {
      Checkbox({ name: 'hide-phone-guide' }).select(this.hidePhoneGuide).width(16).height(16).margin(0)
        .selectedColor(WatchTheme.primary).unselectedColor(WatchTheme.textMuted)
        .enabled(!this.phoneGuideBusy).focusOnTouch(false).accessibilityText('不再提醒')
        .onChange((checked: boolean): void => { this.hidePhoneGuide = checked; })
      Text('不再提醒').fontSize(11).maxLines(1).fontColor(WatchTheme.textSecondary)
        .onClick((): void => {
          if (!this.phoneGuideBusy) { this.hidePhoneGuide = !this.hidePhoneGuide; }
        })
    }.width(64).height(34).flexShrink(0).justifyContent(FlexAlign.Center)
  }

  @Builder private PhoneGuideDialog() {
    WatchRoundDialog({ title: '连接手机', showCancel: false,
      onFocusRequest: (): void => { this.restoreCrownFocus(); },
      confirmLabel: this.phoneGuideBusy ? '保存中' : '知道了', busy: this.phoneGuideBusy,
      onConfirm: (): void => { this.dismissPhoneGuide(); },
      contentBuilder: (): void => { this.PhoneGuideMessage(); },
      showFooterLeading: true, footerLeadingBuilder: (): void => { this.PhoneGuideChoice(); } })
  }

  @Builder private DeleteMessage() {
    Text('将删除手表上选中的录音，无法撤销。').fontSize(13).lineHeight(18)
      .fontColor(WatchTheme.textSecondary).width('100%').textAlign(TextAlign.Center)
  }

  @Builder private DeleteDialog() {
    WatchRoundDialog({ title: this.deletionTargets.length === 1 ? '删除这段录音？' : `删除 ${this.deletionTargets.length} 段录音？`,
      onFocusRequest: (): void => { this.restoreCrownFocus(); },
      cancelLabel: '保留', confirmLabel: '删除', dangerous: true,
      onCancel: (): void => { this.deletionTargets = []; }, onConfirm: (): void => { this.deleteConfirmed(); },
      contentBuilder: (): void => { this.DeleteMessage(); } })
  }

  @Builder private PrivacyMessage() {
    Text(WATCH_PRIVACY_APP_NAME + ' · 开发者：' + WATCH_PRIVACY_DEVELOPER)
      .fontSize(13).fontColor(WatchTheme.text).width('100%')
    Text('麦克风用于获取语音输入。录音由你主动开启，可保存在手表，并由你选择同步至已配对手机。')
      .fontSize(13).lineHeight(18).fontColor(WatchTheme.textSecondary).width('100%')
    if (this.privacyError) { Text(this.privacyError).fontSize(12).fontColor(WatchTheme.error).width('100%') }
  }

  @Builder private PrivacyPolicyAction() {
    Button('完整隐私政策 ›').width('100%').height(32).fontSize(12).padding(0)
      .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).enabled(!this.privacyBusy)
      .onClick((): void => { this.policyVisible = true; })
  }

  @Builder private PrivacyDialog() {
    WatchRoundDialog({ title: '隐私政策', cancelLabel: '不同意', confirmLabel: this.privacyBusy ? '请稍候' : '同意',
      onFocusRequest: (): void => { this.restoreCrownFocus(); },
      busy: this.privacyBusy, onCancel: (): void => { this.declinePrivacy(); },
      onConfirm: (): void => { this.agreePrivacy(); }, contentBuilder: (): void => { this.PrivacyMessage(); },
      showContentAction: true, contentActionBuilder: (): void => { this.PrivacyPolicyAction(); } })
  }

  build() {
    Stack() {
      if (this.policyVisible) {
        WatchPrivacyPolicyView({ onBack: (): void => { this.policyVisible = false; },
          onFocusRequest: (): void => { this.restoreCrownFocus(); } })
      } else if (!this.privacyAccepted) {
        this.PrivacyDialog()
      } else if (this.phoneGuideVisible) {
        this.PhoneGuideDialog()
      } else {
        this.MainContent()
        if (this.deletionTargets.length > 0) { this.DeleteDialog() }
      }
    }.width('100%').height('100%').backgroundColor(WatchTheme.background)
  }
}
