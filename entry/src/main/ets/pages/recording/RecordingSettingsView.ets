import { AppTheme, APP_DARK_MODE_KEY } from '../../utils/AppTheme';
import { DEFAULT_RECORDING_TRANSCRIPTION_ENGINE, DEFAULT_RECORDING_SUMMARY_SOURCE, DEFAULT_RECORDING_LIVE_TRANSCRIBE,
  DEFAULT_RECORDING_AI_SEARCH, RECORDING_LANGUAGE_LABELS, initializeRecordingPreferences } from '../../utils/recording/RecordingPreferences';

initializeRecordingPreferences();

// Full-screen settings content. RecordingPage owns navigation and ongoing jobs
// so opening model management or a record action never duplicates controllers.
@Component
export struct RecordingSettingsView {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @StorageLink('recordingTranscriptionEngine') private engine: string = DEFAULT_RECORDING_TRANSCRIPTION_ENGINE;
  @StorageLink('recordingSummarySource') private summarySource: string = DEFAULT_RECORDING_SUMMARY_SOURCE;
  @StorageLink('recordingLiveTranscribe') private liveTranscribe: boolean = DEFAULT_RECORDING_LIVE_TRANSCRIBE;
  @StorageLink('recordingAutoSummary') private autoSummary: boolean = true;
  @StorageLink('recordingLanguageIndex') private languageIndex: number = 0;
  @StorageLink('recordingAiSearch') private aiSearch: boolean = DEFAULT_RECORDING_AI_SEARCH;
  @Prop busy: boolean = false;
  @Prop separateSpeakers: boolean = false;
  @Prop speakerSwitchOn: boolean = false;
  @Prop confirmingSpeakers: boolean = false;
  @Prop modelsReady: boolean = false;
  @Prop hasRecord: boolean = false;
  @Prop hasAudio: boolean = false;
  @Prop canResume: boolean = false;
  onEngineChange: (engine: string) => void = (_engine: string): void => {};
  onSpeakerChange: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onSearchModeChange: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onModels: () => void = (): void => {};
  onRename: () => void = (): void => {};
  onSpeakers: () => void = (): void => {};
  onTranscribe: () => void = (): void => {};
  onSummarize: () => void = (): void => {};
  onDeleteAudio: () => void = (): void => {};
  onDelete: () => void = (): void => {};
  @BuilderParam feedbackBuilder: () => void = this.Empty;
  @Builder private Empty() { Column() {} }

  private systemModel(): boolean { return this.engine === 'system' && !this.separateSpeakers; }
  @Builder private GroupLabel(text: string) {
    Text(text).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#8E8E93'))
      .width('100%').padding({ left: 16, bottom: 8 })
  }
  @Builder private CellDivider() { Divider().color(AppTheme.border('#EDF0F5')).margin({ left: 16, right: 16 }) }
  @Builder private Transcription() {
    Column({ space: 0 }) {
      Column({ space: 12 }) {
        Text('转写模型').fontSize(17).fontColor(AppTheme.text('#172033')).width('100%')
        Row({ space: 8 }) {
          Button('系统模型').fontSize(15).height(38).layoutWeight(1).padding(0)
            .fontColor(this.systemModel() ? Color.White : AppTheme.text('#737D90'))
            .backgroundColor(this.systemModel() ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
            .onClick((): void => { this.onEngineChange('system'); })
          Button('SenseVoice').fontSize(15).height(38).layoutWeight(1).padding(0)
            .fontColor(!this.systemModel() ? Color.White : AppTheme.text('#737D90'))
            .backgroundColor(!this.systemModel() ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
            .onClick((): void => { this.onEngineChange('sensevoice'); })
        }.width('100%')
      }.width('100%').padding(16)
      this.CellDivider()
      Row() {
        Text('边录边转写').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.liveTranscribe })
          .onChange((value: boolean): void => { this.liveTranscribe = value; })
      }.width('100%').padding(16)
      this.CellDivider()
      Row() {
        Text('区分说话人').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.speakerSwitchOn }).enabled(!this.confirmingSpeakers)
          .onChange((value: boolean): void => { this.onSpeakerChange(value); })
      }.width('100%').padding(16)
      this.CellDivider()
      Row() {
        Text('音频语言').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Select(RECORDING_LANGUAGE_LABELS.map((label: string): SelectOption => ({ value: label })))
          .selected(this.languageIndex).value(this.systemModel() ? '普通话' : RECORDING_LANGUAGE_LABELS[this.languageIndex])
          .font({ size: 15 }).fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
          .enabled(!this.systemModel()).onSelect((index: number): void => { this.languageIndex = index; })
      }.width('100%').padding({ left: 16, right: 10, top: 10, bottom: 10 })
    }.width('100%').borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF')).enabled(!this.busy)
  }
  @Builder private Summary() {
    Column({ space: 0 }) {
      Column({ space: 12 }) {
        Text('摘要方式').fontSize(17).fontColor(AppTheme.text('#172033')).width('100%')
        Row({ space: 8 }) {
          Button('云端').fontSize(15).height(38).layoutWeight(1).padding(0)
            .fontColor(this.summarySource !== 'local' ? Color.White : AppTheme.text('#737D90'))
            .backgroundColor(this.summarySource !== 'local' ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
            .onClick((): void => { this.summarySource = 'cloud'; })
          Button('本地').fontSize(15).height(38).layoutWeight(1).padding(0)
            .fontColor(this.summarySource === 'local' ? Color.White : AppTheme.text('#737D90'))
            .backgroundColor(this.summarySource === 'local' ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
            .onClick((): void => { this.summarySource = 'local'; })
        }.width('100%')
      }.width('100%').padding(16)
      this.CellDivider()
      Row() {
        Text('转写后自动摘要').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoSummary }).onChange((value: boolean): void => { this.autoSummary = value; })
      }.width('100%').padding(16)
    }.width('100%').borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF')).enabled(!this.busy)
  }
  @Builder private ActionRow(title: string, action: () => void, destructive: boolean = false, available: boolean = true) {
    Row() {
      Text(title).fontSize(16).fontColor(AppTheme.text(destructive ? '#D74D47' : '#172033')).layoutWeight(1)
      Text('›').fontSize(24).fontColor(AppTheme.text('#A3A9B4'))
    }.width('100%').padding(16).enabled(!this.busy && available).onClick(action)
  }
  build() {
    Column({ space: 22 }) {
      Column({ space: 0 }) { this.GroupLabel('转写'); this.Transcription() }.width('100%')
      Column({ space: 0 }) { this.GroupLabel('摘要'); this.Summary() }.width('100%')
      Row() {
        Text('AI 搜索').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.aiSearch }).onChange((value: boolean): void => {
          this.aiSearch = value; this.onSearchModeChange(value);
        })
      }.width('100%').padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF')).enabled(!this.busy)
      Row() {
        Text('离线语音模型').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Text(this.modelsReady ? '已就绪' : '管理').fontSize(15).fontColor(AppTheme.text('#8E8E93'))
        Text('›').fontSize(24).fontColor(AppTheme.text('#A3A9B4')).margin({ left: 8 })
      }.width('100%').padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
        .enabled(!this.busy).onClick((): void => { this.onModels(); })
      if (this.hasRecord) {
        Column({ space: 0 }) {
          this.GroupLabel('这条录音')
          Column({ space: 0 }) {
            this.ActionRow('重命名', this.onRename)
            this.CellDivider()
            this.ActionRow('说话人与声纹', this.onSpeakers)
            this.CellDivider()
            this.ActionRow(this.canResume ? '继续或重新转写' : '重新转写', this.onTranscribe, false, this.hasAudio)
            this.CellDivider()
            this.ActionRow('重新生成摘要', this.onSummarize)
            this.CellDivider()
            this.ActionRow(this.hasAudio ? '仅删除音频文件' : '音频已删除', this.onDeleteAudio, true, this.hasAudio)
            this.CellDivider()
            this.ActionRow('删除录音', this.onDelete, true)
          }.width('100%').borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
        }.width('100%')
      }
      this.feedbackBuilder()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
