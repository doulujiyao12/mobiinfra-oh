import { WatchState, RecordingInfo } from '../model/RecorderModels';
import { formatDuration } from '../core/Wav';
import { recorderController } from '../services/RecorderController';
import { WatchTheme } from '../theme/WatchTheme';
import { SyncViewState } from '../sync/SyncProtocol';
import { phoneSyncController } from '../services/PhoneSyncController';

@Entry
@Component
struct Index {
  @State snapshot: WatchState = new WatchState();
  @State screen: string = 'recorder';
  @State selected: RecordingInfo | undefined = undefined;
  @State sync: SyncViewState = new SyncViewState();
  private bars: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];

  aboutToAppear(): void {
    recorderController.subscribe((value: WatchState) => { this.snapshot = value; });
    phoneSyncController.subscribe((value: SyncViewState) => { this.sync = value; });
  }

  aboutToDisappear(): void { recorderController.unsubscribe(); phoneSyncController.unsubscribe(); }

  onBackPress(): boolean {
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
      this.snapshot.status === 'loading';
  }

  private recording(): boolean { return this.snapshot.status === 'recording'; }

  private modeLabel(): string { return this.snapshot.mode === 'speech' ? '仅保留人声' : '有声音才保存'; }

  private recordModeLabel(mode: string): string {
    return mode === 'speech' ? '人声' : (mode === 'sound' ? '声音' : '手动');
  }

  private statusLabel(): string {
    if (this.recording()) {
      if (this.snapshot.saving) { return this.snapshot.mode === 'speech' ? '正在保存人声' : '正在保存声音'; }
      return this.snapshot.mode === 'speech' ? '等待人声' : '等待声音';
    }
    if (this.snapshot.status === 'starting') { return '正在开启麦克风'; }
    if (this.snapshot.status === 'stopping') { return '正在保存录音'; }
    if (this.snapshot.status === 'loading') { return '正在读取录音'; }
    if (this.snapshot.status === 'failed') { return '请重新打开应用'; }
    return '随手记下这一刻';
  }

  private dateLabel(timestamp: number): string {
    const date: Date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日 ${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
  }

  private sizeLabel(bytes: number): string { return `${(bytes / 1024 / 1024).toFixed(1)} MB`; }

  private confirmDelete(record: RecordingInfo): void {
    this.getUIContext().showAlertDialog({
      title: '删除这段录音？',
      message: '录音仅保存在手表，删除后无法恢复。',
      primaryButton: { value: '保留', action: () => {} },
      secondaryButton: {
        value: '删除', fontColor: WatchTheme.danger,
        action: () => {
          recorderController.deleteRecording(record).catch(() => {});
          this.selected = undefined;
          this.screen = 'library';
        }
      }
    });
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
      Text('CLAWMATE').fontSize(11).fontWeight(FontWeight.Medium).fontColor(WatchTheme.textMuted).letterSpacing(2)
      Text(this.statusLabel()).fontSize(13).fontColor(this.recording() ? WatchTheme.primaryLight : WatchTheme.textSecondary)
      Text('已保存时长').fontSize(10).fontColor(WatchTheme.textMuted)
      Text(formatDuration(this.snapshot.durationMs))
        .fontSize(36).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
        .fontFamily('monospace').maxLines(1).margin({ top: 2 })
      this.waveform()
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.recording()) {
            Rect().width(12).height(12).radius(3).fill(WatchTheme.onPrimaryLight)
          } else {
            Circle().width(12).height(12).fill(WatchTheme.onPrimary)
          }
          Text(this.recording() ? '结束监听' : (this.busy() ? '请稍候' : '开启监听'))
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
        Text(`监听 ${formatDuration(this.snapshot.listeningMs)} · ${this.snapshot.segment} 个片段`)
          .fontSize(11).fontColor(WatchTheme.textMuted).margin({ top: 5 })
        Text(`${this.modeLabel()} · 熄屏继续监听`)
          .fontSize(10).fontColor(WatchTheme.textMuted)
      } else {
        Button(`模式 · ${this.modeLabel()}`)
          .width('92%').height(30).fontSize(12)
          .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).margin({ top: 4 })
          .enabled(this.snapshot.status === 'ready')
          .onClick(() => { this.screen = 'mode'; })
        Button(`录音库 · ${this.snapshot.records.length}`)
          .width('80%').height(28).fontSize(12)
          .fontColor(WatchTheme.textSecondary).backgroundColor(WatchTheme.surface).margin({ top: 4 })
          .enabled(!this.busy())
          .onClick(() => { recorderController.refresh(); this.screen = 'library'; })
      }
      if (this.snapshot.error.length > 0) {
        Text(this.snapshot.error).fontSize(12).fontColor(WatchTheme.error).textAlign(TextAlign.Center)
          .margin({ top: 8 }).width('90%')
      } else if (this.snapshot.notice.length > 0 && !this.recording()) {
        Text(this.snapshot.notice).fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
          .margin({ top: 5 }).width('90%')
      }
      Text('监听时麦克风保持开启 · 本地保存')
        .fontSize(10).fontColor(WatchTheme.textSubtle).margin({ top: 8, bottom: 8 })
      Button('手机同步').width('80%').height(28).fontSize(12)
        .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface)
        .onClick(() => { this.screen = 'sync'; })
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
      if (this.sync.status === 'transferring' || this.sync.status === 'awaiting_ack') {
        Text(`${Math.round(this.sync.progress)}%`).fontSize(30).fontColor(WatchTheme.text)
      }
      Text(`手机已确认 ${this.sync.syncedIds.length} 段`)
        .fontSize(12).fontColor(WatchTheme.textSecondary)
      Text('在配对手机打开 ClawMate 发起同步。接收并校验成功后才标记已同步，手表原文件会保留。')
        .fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
      Button('重新连接').width('90%').height(36).fontSize(14)
        .fontColor(WatchTheme.onPrimary).backgroundColor(WatchTheme.primary)
        .enabled(this.sync.status !== 'connecting' && this.sync.currentId.length === 0 && this.sync.status !== 'unsupported')
        .onClick(() => { phoneSyncController.reconnect().catch(() => {}); })
      Button('返回录音').height(32).fontSize(12).backgroundColor(Color.Transparent).fontColor(WatchTheme.textMuted)
        .onClick(() => { this.screen = 'recorder'; })
    }.width('100%')
  }

  @Builder
  modePicker() {
    Column({ space: 10 }) {
      Text('保存模式').fontSize(20).fontWeight(FontWeight.Medium).fontColor(WatchTheme.text)
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          Text(this.snapshot.mode === 'sound' ? '✓ 有声音才保存' : '有声音才保存')
            .fontSize(15).fontColor(WatchTheme.text)
          Text('默认模式，声音达到强度后保存；音乐和环境声音也可能触发。')
            .fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
        }.padding(12).width('100%')
      }.width('100%').borderRadius(20)
      .backgroundColor(this.snapshot.mode === 'sound' ? WatchTheme.primarySurface : WatchTheme.surface)
      .enabled(this.snapshot.status === 'ready')
      .onClick(() => { recorderController.selectMode('sound').catch(() => {}); })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          Text(this.snapshot.mode === 'speech' ? '✓ 仅保留人声' : '仅保留人声')
            .fontSize(15).fontColor(WatchTheme.text)
          Text('本地检测说话声，不区分说话者。音乐、噪声可能误触发，低声讲话可能漏检。')
            .fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
        }.padding(12).width('100%')
      }.width('100%').borderRadius(20)
      .backgroundColor(this.snapshot.mode === 'speech' ? WatchTheme.primarySurface : WatchTheme.surface)
      .enabled(this.snapshot.status === 'ready')
      .onClick(() => { recorderController.selectMode('speech').catch(() => {}); })
      Text('保留约 1 秒前置缓存；连续安静约 2 秒后保存片段。两种模式都持续使用麦克风。')
        .fontSize(11).fontColor(WatchTheme.textMuted).textAlign(TextAlign.Center)
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
      Text(`可用空间 ${(this.snapshot.availableBytes / 1024 / 1024 / 1024).toFixed(1)} GB`)
        .fontSize(11).fontColor(WatchTheme.textMuted)
      if (this.snapshot.records.length === 0) {
        Text('还没有录音').fontSize(16).fontColor(WatchTheme.textSecondary).margin({ top: 24 })
        Text('回到首页，记下第一段声音。').fontSize(12).fontColor(WatchTheme.textMuted)
          .textAlign(TextAlign.Center).margin({ bottom: 18 })
      } else {
        ForEach(this.snapshot.records, (record: RecordingInfo) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 5 }) {
              Text(this.dateLabel(record.createdAt)).fontSize(14).fontColor(WatchTheme.text)
              Text(`${formatDuration(record.durationMs)} · ${this.sizeLabel(record.bytes)} · ${this.recordModeLabel(record.mode)}`)
                .fontSize(10).fontColor(WatchTheme.textMuted)
              Text(this.sync.currentId === record.name ? '正在同步' :
                (this.sync.syncedIds.indexOf(record.name) >= 0 ? '手机已确认' : '待同步'))
                .fontSize(10).fontColor(WatchTheme.primaryLight)
            }.width('100%').padding(12)
          }
          .width('100%').borderRadius(20).backgroundColor(WatchTheme.surface)
          .onClick(() => { this.selected = record; this.screen = 'detail'; })
        }, (record: RecordingInfo) => record.name)
      }
      Button('返回录音').height(36).width('85%').fontSize(13)
        .fontColor(WatchTheme.primaryLight).backgroundColor(WatchTheme.primarySurface).margin({ top: 6 })
        .onClick(() => { this.screen = 'recorder'; })
    }.width('100%')
  }

  @Builder
  detail() {
    Column({ space: 10 }) {
      if (this.selected !== undefined) {
        Text('声音记录').fontSize(12).fontColor(WatchTheme.textMuted)
        Text(this.dateLabel(this.selected.createdAt)).fontSize(17).fontColor(WatchTheme.text)
        Text(this.snapshot.playingName === this.selected.name ?
          formatDuration(this.snapshot.playbackMs) : formatDuration(this.selected.durationMs))
          .fontSize(36).fontColor(WatchTheme.primaryLight).fontFamily('monospace')
        Text(`${this.sizeLabel(this.selected.bytes)} · WAV · ${this.recordModeLabel(this.selected.mode)}`)
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

  build() {
    Scroll() {
      Column() {
        if (this.screen === 'library') { this.library(); }
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
  }
}
