import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { appBackgroundTasks } from '../../utils/AppBackgroundTasks';
import { RecordingAnalysisRunner } from '../../utils/recording/RecordingAnalysisRunner';
import { RecordingSummaryService } from '../../utils/recording/RecordingSummaryService';
import { LocalTextInference } from '../../utils/LocalTextInference';
import { RecordingWatchSync, RecordingWatchDevice } from '../../utils/recording/RecordingWatchSync';
import { RecordingSummaryView } from './RecordingSummaryView';
import { AppTheme, APP_DARK_MODE_KEY } from '../../utils/AppTheme';
import { FrostedPage } from '../../components/FrostedPage';
import { AppHeader } from '../../components/AppHeader';
import { picker } from '@kit.CoreFileKit';
import { RecordingStore } from '../../utils/recording/RecordingStore';
import { DEFAULT_RECORDING_MODEL_URL, RecordingModelProgress, RecordingModels, RECORDING_MODELS } from '../../utils/recording/RecordingModels';
import { RecordingCapture } from '../../utils/recording/RecordingCapture';
import { RecordingLiveRunner } from '../../utils/recording/RecordingLiveRunner';
import { RecordingLiveCheckpoint } from '../../utils/recording/RecordingLiveCheckpoint';
import { RecordingLiveUpdate, emptyLiveAnalysis } from '../../utils/recording/RecordingLiveTypes';
import { recordingAudioSource, recordingAudioSourceLabel } from '../../utils/recording/RecordingAudioSource';
import { RecordingPlayback } from '../../utils/recording/RecordingPlayback';
import { applyPageStatusBar } from '../../utils/PageStatusBar';
import { RECORDING_INBOX_KEY } from '../../utils/recording/RecordingInbox';
import { RecordingAnalysis, RecordingJob, RecordingRecord, RecordingSegment, RecordingSpeaker,
  RecordingWorkerMessage, SpeechRange, applyRecordingSummary, recordingUsesAutomaticTitle,
  recordingTime, recordingTimeline, voiceSimilarity } from '../../utils/recording/RecordingTypes';

PersistentStorage.persistProp('recordingAutoSummary', true);
PersistentStorage.persistProp('recordingAudioSource', 'environment');
PersistentStorage.persistProp('recordingSummarySource', 'cloud');
PersistentStorage.persistProp('recordingLiveTranscribe', true);
PersistentStorage.persistProp('recordingSpeakerSeparation', false);
const SPEAKER_COLORS: string[] = ['#007AFF', '#AF52DE', '#229B78', '#DD8D24', '#DD5E83'];
interface VoiceReference { recordId: string; modelId: string; name: string; embedding: number[]; }

@Entry
@Component
struct RecordingPage {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @State private records: RecordingRecord[] = [];
  @State private selected: RecordingRecord | null = null;
  @State private busy: boolean = false;
  @State private recording: boolean = false;
  @State private seconds: number = 0;
  @State private progress: number = 0;
  @State private status: string = '';
  @State private error: string = '';
  @State private modelCount: number = 0;
  @State private showModels: boolean = false;
  @State private showModelOptions: boolean = false;
  @State private modelDownloadUrl: string = DEFAULT_RECORDING_MODEL_URL;
  @State private modelSourceSaved: boolean = false;
  @State private modelProgress: number = 0;
  @State private modelProgressSize: string = '';
  @State private showModelProgress: boolean = false;
  @State private filterSpeaker: number = -2;
  @State private languageIndex: number = 0;
  @State private playing: number = -2;
  @State private reference: VoiceReference | null = null;
  @State private comparison: string = '';
  private store: RecordingStore | null = null;
  private models: RecordingModels | null = null;
  private capture: RecordingCapture = new RecordingCapture();
  private playback: RecordingPlayback = new RecordingPlayback();
  @StorageLink('recordingAutoSummary') private autoSummary: boolean = true;
  @StorageLink('recordingAudioSource') private audioSource: string = 'environment';
  @StorageLink('recordingSummarySource') private summarySource: string = 'cloud';
  @StorageLink('recordingLiveTranscribe') private liveTranscribe: boolean = true;
  @StorageLink('recordingSpeakerSeparation') private separateSpeakers: boolean = false;
  @State private speakerSwitchOn: boolean = false;
  @State private confirmingSpeakerSeparation: boolean = false;
  @State private liveSegments: RecordingSegment[] = [];
  @State private liveStatus: string = '';
  private live: RecordingLiveRunner | null = null;
  @State private showAudioSources: boolean = false;
  private audioSources: string[] = ['environment', 'mixed', 'system'];
  private captureStopPending: boolean = false;
  @State private showWatch: boolean = false;
  @State private showOptions: boolean = false;
  @State private showSpeakers: boolean = false;
  @State private showRename: boolean = false;
  @State private editTitle: string = '';
  @State private detailTab: string = 'text';
  @State private visibleSegments: number = 60;
  @State private watchDevices: RecordingWatchDevice[] = [];
  @State private watchScanning: boolean = false;
  @State private watchStatus: string = '接收手表上的录音，在手机上转写。';
  @State private watchAutoAnalyze: boolean = true;
  @State private queueRemaining: number = 0;
  private analyzer: RecordingAnalysisRunner = new RecordingAnalysisRunner();
  private summaryService: RecordingSummaryService = new RecordingSummaryService();
  private watchSync: RecordingWatchSync = new RecordingWatchSync();
  private jobKind: string = '';
  private queueEpoch: number = 0;
  private recordingStartedAt: number = 0;
  private startingRecording: boolean = false;
  private timer: number = -1;
  private epoch: number = 0;
  private alive: boolean = true;
  private externalInteraction: boolean = false;
  private preparingModels: boolean = false;
  private recordingDraft: RecordingRecord | null = null;
  private scroller: Scroller = new Scroller();
  private recordingListScroller: ListScroller = new ListScroller();
  private renameTarget: RecordingRecord | null = null;
  private languages: string[] = ['auto', 'zh', 'en', 'ja', 'ko', 'yue'];
  private languageLabels: string[] = ['自动识别', '普通话', '英语', '日语', '韩语', '粤语'];
  private backgroundCancelled: () => void = (): void => {
    if (this.recording) { this.error = '系统结束了后台录音，已保存录到的声音'; this.stopRecording().catch((e: Error): void => { this.message(e); }); }
  };
  private backgroundHandler: () => void = (): void => {
    let transcribing = this.busy && this.jobKind === 'analysis'; this.leavePage();
    if (transcribing) { this.status = '转写已暂停，已完成的进度已保存，返回后可继续'; }
  };

  aboutToAppear(): void {
    this.alive = true;
    this.speakerSwitchOn = this.separateSpeakers;
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.store = new RecordingStore(context.filesDir); this.models = new RecordingModels(context);
      this.store.recoverCaptures(); this.reload(); this.modelCount = this.models.readyCount();
      this.modelDownloadUrl = this.models.downloadBaseUrl();
      context.eventHub.on('recording-analysis-background', this.backgroundHandler);
      context.eventHub.on('recording-background-cancelled', this.backgroundCancelled);
    } catch (e) { this.error = (e as Error).message; }
  }
  onPageShow(): void {
    applyPageStatusBar(this.getUIContext(), '#F6F7FA');
    try {
      this.reload();
      let importError = AppStorage.get<string>('recordingAnalysisImportError') || '';
      if (importError) { this.error = importError; AppStorage.setOrCreate('recordingAnalysisImportError', ''); }
      let id = AppStorage.get<string>(RECORDING_INBOX_KEY) || '';
      if (id.length > 0 && !this.busy) {
        this.selected = this.records.find((record: RecordingRecord): boolean => record.id === id) || null;
        AppStorage.setOrCreate(RECORDING_INBOX_KEY, '');
      }
    } catch (e) { this.error = (e as Error).message; }
  }
  onPageHide(): void { this.leavePage(); }
  aboutToDisappear(): void {
    if (this.startingRecording) { this.epoch++; this.capture.stop().catch((): void => {}); }
    this.externalInteraction = false;
    if (this.recording) { this.stopRecording().catch((): void => {}); }
    this.leavePage(); this.alive = false;
    this.context().eventHub.off('recording-background-cancelled', this.backgroundCancelled);
    (this.getUIContext().getHostContext() as common.UIAbilityContext).eventHub.off('recording-analysis-background', this.backgroundHandler);
  }
  private leavePage(): void {
    if (this.externalInteraction) { return; }
    if (this.recording) { return; }
    if (this.busy) { this.cancel(); }
    this.playback.stop().catch((): void => {}); this.playing = -2;
  }
  private reload(): void { if (this.store !== null) { this.records = this.store.list(); } }
  private message(error: Error): void { if (this.alive) { this.error = error.message || '操作未完成，请重试'; } }
  private async importAudio(): Promise<void> {
    if (this.busy || this.store === null) { return; }
    this.busy = true; this.error = ''; let epoch = ++this.epoch;
    try {
      let options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['WAV 音频|.wav'];
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.externalInteraction = true;
      let uris = await new picker.DocumentViewPicker(context).select(options);
      this.externalInteraction = false;
      if (uris.length === 0 || epoch !== this.epoch) { return; }
      this.status = '正在保存音频';
      let record = await this.store.importWav(uris[0]);
      if (this.alive && epoch === this.epoch) { this.selected = record; this.reload(); this.filterSpeaker = -2; }
    } catch (e) { this.message(e as Error); }
    finally { this.externalInteraction = false; if (this.alive && epoch === this.epoch) { this.busy = false; this.status = ''; } }
  }
  private async startRecording(): Promise<void> {
    if (this.busy || this.store === null) { return; }
    let source = recordingAudioSource(this.audioSource);
    this.captureStopPending = false;
    this.busy = true; this.startingRecording = true; this.jobKind = 'capture';
    this.status = source === 'environment' ? '正在准备麦克风' : '请确认系统屏幕授权，仅采集声音，不录制画面';
    this.error = ''; let epoch = ++this.epoch;
    try {
      await this.playback.stop(); this.playing = -2;
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (source !== 'system') {
        let permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
        this.externalInteraction = true;
        let grant = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
        this.externalInteraction = false;
        if (grant.authResults[0] !== 0) { throw new Error('录音需要麦克风权限，可在系统设置中开启'); }
      }
      if (epoch !== this.epoch) { return; }
      let record = this.store.create('录制'); record.title = '录音 ' + this.clockTime(new Date(record.createdAt));
      const useLive = this.liveTranscribe && this.models?.readyForTranscription(false) === true;
      if (useLive) { record.analysis = emptyLiveAnalysis(0); record.transcriptionComplete = false; }
      record.capturing = true; record.audioSource = source; this.recordingDraft = record;
      this.externalInteraction = source !== 'environment';
      await this.capture.start(this.store.audioPath(record.id), (): void => {
        if (this.startingRecording) { this.captureStopPending = true; return; }
        this.stopRecording().catch((e: Error): void => { this.message(e); });
      }, (message: string): void => {
        this.error = message;
        if (this.startingRecording) { this.captureStopPending = true; return; }
        this.stopRecording().catch((e: Error): void => { this.message(e); });
      }, source);
      this.externalInteraction = false;
      if (this.captureStopPending) { throw new Error(this.error || '系统已结束录音'); }
      if (epoch !== this.epoch) { await this.capture.stop(); this.store.remove(record.id); this.recordingDraft = null; return; }
      this.store.save(record);
      await appBackgroundTasks.set(context, 'recording', 'audioRecording', true);
      if (this.captureStopPending) { throw new Error(this.error || '系统已结束录音'); }
      if (epoch !== this.epoch || !this.alive) {
        record.duration = await this.capture.stop(); record.capturing = false;
        if (record.duration >= 0.3) { this.store.save(record); } else { this.store.remove(record.id); }
        this.recordingDraft = null;
        await appBackgroundTasks.set(context, 'recording', 'audioRecording', false); return;
      }
      this.recording = true; this.selected = null; this.seconds = 0; this.recordingStartedAt = Date.now();
      this.liveSegments = []; this.liveStatus = '';
      if (useLive && this.models !== null) {
        const live = new RecordingLiveRunner(); this.live = live;
        const checkpoint = new RecordingLiveCheckpoint(this.store.livePath(record.id));
        this.liveStatus = '正在准备实时转写';
        live.start({ audioPath: this.store.audioPath(record.id), modelDir: this.models.directory, language: this.languages[this.languageIndex] },
          (): number => this.capture.availableSamples(), (value: RecordingLiveUpdate): void => {
            if (value.segments.length > 0 || value.kind === 'done') { checkpoint.append(value); }
            if (!this.alive || epoch !== this.epoch) { return; }
            this.liveSegments = this.liveSegments.concat(value.segments).slice(-8);
            const lag = Math.max(0, (this.capture.availableSamples() - value.processed) / 16000);
            this.liveStatus = lag > 8 ? '转写处理中，录音继续保存' : '按说话停顿更新';
            if (!this.recording) {
              this.progress = Math.min(99, Math.floor(value.processed * 100 / Math.max(1, this.capture.availableSamples())));
              this.status = '正在保存最后的转写 · ' + recordingTime(value.processed / 16000);
            }
          }, (message: string): void => {
            if (this.alive && epoch === this.epoch) { this.liveStatus = '实时转写已暂停，录音继续保存'; this.error = message; }
          });
      } else if (this.liveTranscribe) {
        this.liveStatus = '语音模型未准备，本次仅录音';
      }
      this.status = '';
      this.timer = setInterval((): void => { this.seconds = Math.floor((Date.now() - this.recordingStartedAt) / 1000); }, 1000);
    } catch (e) {
      let duration = await this.capture.stop().catch((): number => 0);
      await appBackgroundTasks.set(this.context(), 'recording', 'audioRecording', false).catch((): void => {});
      this.message(e as Error);
      if (this.recordingDraft !== null) {
        if (duration >= 0.3) {
          this.recordingDraft.duration = duration; this.recordingDraft.capturing = false; this.store.save(this.recordingDraft); this.reload();
        } else { this.store.remove(this.recordingDraft.id); }
        this.recordingDraft = null;
      }
      this.busy = false;
    } finally {
      this.externalInteraction = false; this.startingRecording = false;
      if (this.alive && !this.recording) { this.busy = false; this.jobKind = ''; }
    }
  }
  private async stopRecording(): Promise<void> {
    if (!this.recording) { return; }
    this.recording = false; clearInterval(this.timer); this.timer = -1;
    const epoch = this.epoch; const live = this.live; let saved: RecordingRecord | null = null; let released = false;
    try {
      let duration = await this.capture.stop(); let record = this.recordingDraft; this.recordingDraft = null;
      await appBackgroundTasks.set(this.context(), 'recording', 'audioRecording', false).catch((): void => {}); released = true;
      if (this.capture.errorMessage()) { this.error = this.capture.errorMessage(); }
      if (record !== null && this.store !== null) {
        if (duration < 0.3) { live?.cancel(); this.store.remove(record.id); throw new Error('录音过短，请至少录制一秒'); }
        record.duration = duration; record.capturing = false; this.store.save(record);
        if (this.alive && epoch === this.epoch) { this.selected = record; this.filterSpeaker = -2; this.reload(); }
        if (live !== null) {
          if (this.alive && epoch === this.epoch) { this.jobKind = 'live-finalizing'; this.status = '录音已保存，正在保存最后的转写'; this.progress = 0; }
          try { record.analysis = await live.finish(this.capture.availableSamples()); record.transcriptionComplete = true; }
          catch (e) {
            record.analysis = live.snapshot(duration); record.transcriptionComplete = false;
            if (this.alive && epoch === this.epoch) { this.error = '已有文字和录音已保存，可稍后完成转写：' + (e as Error).message; }
          }
          this.store.save(record);
          if (record.transcriptionComplete) { this.store.clearLiveDraft(record.id); }
        }
        saved = record;
        if (this.alive && epoch === this.epoch) { this.selected = record; this.refreshSelected(); this.reload(); this.detailTab = 'text'; }
      }
    } finally {
      if (!released) { await appBackgroundTasks.set(this.context(), 'recording', 'audioRecording', false).catch((): void => {}); }
      live?.cancel();
      if (this.live === live) { this.live = null; }
      if (this.alive && epoch === this.epoch) { this.busy = false; this.jobKind = ''; this.status = saved?.transcriptionComplete ? '录音与转写已保存' : '录音已保存'; }
    }
    if (this.alive && epoch === this.epoch && this.autoSummary && saved?.transcriptionComplete && !this.error &&
      this.selected?.id === saved.id && saved.analysis?.segments.some((segment: RecordingSegment): boolean => !!segment.text.trim())) { await this.summarize(); }
  }
  private async prepareModels(importing: boolean): Promise<void> {
    if (this.busy || this.models === null) { return; }
    this.busy = true; this.error = ''; let epoch = ++this.epoch;
    this.preparingModels = true;
    this.showModelProgress = !importing; this.modelProgress = 0; this.modelProgressSize = '';
    let report = (text: string): void => { if (this.alive && epoch === this.epoch) { this.status = text; } };
    try {
      if (importing) {
        this.externalInteraction = true;
        await this.models.importFiles(report, (): void => { this.externalInteraction = false; });
      } else {
        this.modelDownloadUrl = this.models.setDownloadBaseUrl(this.modelDownloadUrl);
        this.modelSourceSaved = true;
        await this.models.prepare(report, this.modelDownloadUrl, (value: RecordingModelProgress): void => {
          if (!this.alive || epoch !== this.epoch) { return; }
          this.modelProgress = value.percent;
          this.modelProgressSize = (value.preparedBytes / 1048576).toFixed(1) + ' / ' +
            (value.totalBytes / 1048576).toFixed(1) + ' MB';
        });
      }
    } catch (e) { if (epoch === this.epoch) { this.message(e as Error); } }
    finally {
      this.externalInteraction = false; this.preparingModels = false;
      if (this.alive && epoch === this.epoch) { this.busy = false; this.status = ''; this.modelCount = this.models.readyCount(); }
    }
  }
  private saveModelSource(): void {
    if (this.busy || this.models === null) { return; }
    try {
      this.modelDownloadUrl = this.models.setDownloadBaseUrl(this.modelDownloadUrl);
      this.modelSourceSaved = true; this.error = '';
    } catch (e) { this.message(e as Error); }
  }
  private async analyze(restart: boolean = false): Promise<void> {
    if (this.busy || this.selected === null || this.models === null || this.store === null) { return; }
    if (!this.store.hasAudio(this.selected.id)) { this.error = '音频已删除，无法重新转写；已有文字和摘要仍可查看'; return; }
    if (!this.models.readyForTranscription(this.separateSpeakers)) { this.showModels = true; return; }
    await this.playback.stop(); this.playing = -2;
    let record = this.selected; let epoch = ++this.epoch;
    this.busy = true; this.jobKind = 'analysis'; this.progress = 0; this.error = ''; this.status = '正在准备转写';
    try {
      let result = await this.analyzer.run({ audioPath: this.store.audioPath(record.id), modelDir: this.models.directory,
        language: this.languages[this.languageIndex], restart: restart, diarization: this.separateSpeakers },
        (value: RecordingWorkerMessage): void => {
        if (this.alive && epoch === this.epoch) { this.progress = value.progress; this.status = value.message; }
      });
      if (!this.alive || epoch !== this.epoch) { return; }
      record.analysis = result; record.transcriptionComplete = true; record.summary = undefined; record.localSummaryDraft = undefined;
      record.duration = result.duration; this.store.save(record);
      this.store.clearAnalysisDraft(record.id);
      this.store.clearLiveDraft(record.id);
      this.selected = record; this.filterSpeaker = -2; this.visibleSegments = 60; this.reload();
      this.status = result.speech.length === 0 ? '未检测到人声，原录音已保留' : '转写已保存';
    } catch (e) { if (this.alive && epoch === this.epoch) { this.message(e as Error); } }
    finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
    if (epoch === this.epoch && this.autoSummary && !this.error && record.analysis !== null &&
      record.analysis.segments.some((segment: RecordingSegment): boolean => segment.text.trim().length > 0)) { await this.summarize(); }
  }
  private async summarize(restart: boolean = false): Promise<void> {
    if (this.busy || this.selected === null || this.store === null) { return; }
    let record = this.selected; let epoch = ++this.epoch;
    this.busy = true; this.jobKind = 'summary'; this.error = ''; this.progress = 0;
    try {
      let summary = await this.summaryService.generate(record, (text: string): void => {
        if (this.alive && epoch === this.epoch) { this.status = text; }
      }, { source: this.summarySource === 'local' ? 'local' : 'cloud', restart: restart,
        onCheckpoint: (completed: number, total: number): void => {
          if (!this.alive || epoch !== this.epoch || this.store === null) { return; }
          this.store.save(record); this.selected = record; this.refreshSelected(); this.reload();
          this.progress = Math.round(completed * 100 / Math.max(1, total));
          if (record.summary?.source === 'local') { this.detailTab = 'summary'; }
        } });
      if (!this.alive || epoch !== this.epoch) { return; }
      applyRecordingSummary(record, summary); this.store.save(record); this.selected = record; this.refreshSelected(); this.reload();
      this.detailTab = 'summary'; this.progress = 100; this.status = '摘要已保存';
    } catch (e) {
      if (epoch === this.epoch) {
        let message = (e as Error).message || String(e);
        this.status = '';
        this.error = '转写及已完成的摘要已保留：' + message.replace('LOCAL_MODEL_REQUIRED: ', '');
        if (message.indexOf('LOCAL_MODEL_REQUIRED:') === 0) {
          await promptAction.showDialog({ title: '请先下载本地模型',
            message: '本地摘要使用聊天中的本地大模型，请先到“我的 → 模型与智能体 → 本地模型”下载。',
            buttons: [{ text: '稍后', color: AppTheme.dialogText('#737D90') }, { text: '去下载', color: AppTheme.dialogText('#5260ED') }] })
            .then((choice): void => {
              if (choice.index === 1 && this.alive) { LocalTextInference.openDownload(); router.back(); }
            }).catch((): void => {});
        }
      }
    }
    finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
  }
  private cancel(): void {
    if (this.jobKind === 'live-finalizing' && this.live !== null) {
      this.status = '正在保留已有转写'; this.live.cancel(); return;
    }
    if (this.startingRecording) {
      this.epoch++; this.queueEpoch++; this.status = '正在结束录音准备';
      this.capture.stop().catch((e: Error): void => { this.message(e); }); return;
    }
    if (this.preparingModels) { this.models?.cancel(); this.status = '正在停止模型准备'; return; }
    let transcribing = this.jobKind === 'analysis';
    this.epoch++; this.queueEpoch++; this.queueRemaining = 0;
    this.analyzer.cancel(); this.summaryService.cancel(); this.watchSync.cancel().catch((): void => {});
    this.live?.cancel();
    if (this.models !== null) { this.models.cancel(); }
    this.busy = false; this.jobKind = ''; this.status = transcribing ?
      '转写已暂停，已完成的进度已保存，稍后可继续' : '已停止，录音和已有结果已保留';
  }
  private canResumeAnalysis(): boolean {
    return this.selected !== null && this.store !== null &&
      this.store.hasAnalysisDraft(this.selected.id, this.separateSpeakers);
  }
  private async setSpeakerSeparation(value: boolean): Promise<void> {
    if (this.busy || this.recording || this.confirmingSpeakerSeparation) {
      this.speakerSwitchOn = this.separateSpeakers; return;
    }
    this.speakerSwitchOn = value;
    if (!value) { this.separateSpeakers = false; return; }
    this.confirmingSpeakerSeparation = true;
    try {
      let choice = await promptAction.showDialog({ title: '开启说话人区分？',
        message: '说话人区分可能不准确，并会明显增加转写耗时。开启后，在转写录音文件时生效；边录边转写仍使用快速模式。已有结果保留，可从“更多”重新转写。',
        buttons: [{ text: '取消', color: AppTheme.dialogText('#737D90') },
          { text: '开启', color: AppTheme.dialogText('#5260ED') }] });
      if (this.alive && !this.busy) { this.separateSpeakers = choice.index === 1; }
    } finally {
      this.speakerSwitchOn = this.separateSpeakers; this.confirmingSpeakerSeparation = false;
    }
  }
  private async restartAnalysis(): Promise<void> {
    let choice = await promptAction.showDialog({ title: '从头转写？',
      message: '本次将重新分析整条录音。原录音和已有成功结果会保留，新转写完成后再替换。',
      buttons: [{ text: '取消', color: AppTheme.dialogText('#737D90') },
        { text: '从头转写', color: AppTheme.dialogText('#5260ED') }] });
    if (choice.index === 1 && this.alive && !this.busy) { await this.analyze(true); }
  }
  private async chooseAnalysis(): Promise<void> {
    if (!this.canResumeAnalysis()) { await this.analyze(); return; }
    let choice = await promptAction.showActionMenu({ title: '转写进度已保存', buttons: [
      { text: '继续转写', color: '#172033' }, { text: '从头转写', color: '#172033' }] });
    if (choice.index === 0) { await this.analyze(); }
    else if (choice.index === 1) { await this.restartAnalysis(); }
  }
  private openRecord(record: RecordingRecord): void {
    if (this.busy) { return; }
    this.recordingListScroller.closeAllSwipeActions();
    this.playback.stop().catch((): void => {}); this.playing = -2;
    this.selected = record; this.detailTab = record.summary ? 'summary' : 'text'; this.visibleSegments = 60;
    this.filterSpeaker = -2; this.comparison = ''; this.error = ''; this.status = '';
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  private save(): void {
    if (this.selected === null || this.store === null) { return; }
    try { this.store.save(this.selected); this.reload(); this.status = '已保存到本机'; }
    catch (e) { this.message(e as Error); }
  }
  private refreshSelected(): void {
    let record = this.selected;
    if (record !== null) {
      this.selected = { schema: record.schema, id: record.id, title: record.title, createdAt: record.createdAt,
        source: record.source, duration: record.duration, analysis: record.analysis, summary: record.summary, watch: record.watch,
        capturing: record.capturing, audioSource: record.audioSource, titleEdited: record.titleEdited,
        localSummaryDraft: record.localSummaryDraft };
    }
  }
  private beginRename(record: RecordingRecord): void {
    if (this.busy) { return; }
    this.recordingListScroller.closeAllSwipeActions();
    this.renameTarget = record; this.editTitle = this.recordTitle(record); this.showRename = true;
  }
  private finishRename(): void {
    let record = this.renameTarget; let title = this.editTitle.trim();
    if (this.busy || record === null || this.store === null || !title) { return; }
    let oldTitle = record.title; let oldEdited = record.titleEdited;
    try {
      record.title = title; record.titleEdited = true; this.store.save(record);
      if (this.selected?.id === record.id) { this.selected = record; this.refreshSelected(); }
      this.reload(); this.showRename = false; this.renameTarget = null;
    } catch (e) { record.title = oldTitle; record.titleEdited = oldEdited; this.message(e as Error); }
  }
  private async remove(record: RecordingRecord | null = this.selected): Promise<void> {
    if (this.busy || record === null || this.store === null) { return; }
    this.recordingListScroller.closeAllSwipeActions();
    let result = await promptAction.showDialog({ title: '删除这条录音？',
      message: this.recordTitle(record) + '\n录音、转写和摘要将一起删除。' + (record.watch ? '手表原录音会保留。' : ''),
      buttons: [{ text: '取消', color: '#8E8E93' }, { text: '删除', color: '#FF3B30' }] });
    if (result.index !== 1 || this.busy || !this.alive || this.store === null) { return; }
    await this.playback.stop(); this.playing = -2;
    this.store.remove(record.id);
    if (this.selected?.id === record.id) { this.selected = null; }
    this.reload();
    if (this.reference?.recordId === record.id) { this.reference = null; this.comparison = ''; }
  }
  private audioAvailable(): boolean { return this.selected !== null && this.store?.hasAudio(this.selected.id) === true; }
  private async removeAudio(): Promise<void> {
    const record = this.selected;
    if (this.busy || record === null || this.store === null || !this.audioAvailable()) { return; }
    const result = await promptAction.showDialog({ title: '仅删除音频文件？',
      message: '保留这条记录的标题、转写文字、摘要和已有声纹。删除后无法播放或重新转写。' +
        (record.analysis === null || record.transcriptionComplete === false ? '\n这条录音尚未完成转写，删除后无法再从音频恢复文字。' : '') + (record.watch ? '\n手表原录音会保留。' : ''),
      buttons: [{ text: '取消', color: AppTheme.dialogText('#8E8E93') }, { text: '仅删除音频', color: AppTheme.dialogText('#FF3B30') }] });
    if (result.index !== 1 || this.busy || !this.alive || this.selected?.id !== record.id || this.store === null) { return; }
    await this.playback.stop(); this.playing = -2;
    this.store.removeAudio(record); this.selected = record; this.refreshSelected(); this.reload(); this.status = '音频已删除，文字和摘要已保留';
  }
  private analysis(): RecordingAnalysis | null { return this.selected?.analysis || null; }
  private segments(): RecordingSegment[] {
    return (this.analysis()?.segments || []).filter((s: RecordingSegment): boolean => this.filterSpeaker === -2 || s.speaker === this.filterSpeaker);
  }
  private speakerName(id: number): string {
    return this.analysis()?.speakers.find((s: RecordingSpeaker): boolean => s.id === id)?.name || '未区分';
  }
  private color(id: number): ResourceColor { return AppTheme.text(id < 0 ? '#8E8E93' : SPEAKER_COLORS[id % SPEAKER_COLORS.length]); }
  private async play(segment: RecordingSegment | null): Promise<void> {
    if (this.selected === null || this.store === null || this.busy) { return; }
    if (!this.audioAvailable()) { this.error = '音频已删除，已有文字和摘要仍可查看'; return; }
    let id = segment === null ? -1 : segment.id;
    if (this.playing === id) { await this.playback.stop(); this.playing = -2; return; }
    this.playing = id;
    try {
      await this.playback.play(this.store.audioPath(this.selected.id), segment?.start || 0, segment?.end || 0,
        (): void => { if (this.alive) { this.playing = -2; } }, (message: string): void => { if (this.alive) { this.error = message; } });
    } catch (e) { this.playing = -2; this.message(e as Error); }
  }
  private compare(speaker: RecordingSpeaker): void {
    if (this.selected === null || this.analysis() === null || speaker.embedding.length === 0) { return; }
    if (this.reference === null) {
      this.reference = { recordId: this.selected.id, modelId: this.analysis()!.modelId,
        name: this.selected.title + ' · ' + speaker.name, embedding: speaker.embedding.slice() };
      this.comparison = '已选为参考声纹，请打开另一条录音或选择其他说话人进行比较。'; return;
    }
    try {
      if (this.reference.modelId !== this.analysis()!.modelId) { throw new Error('模型版本不同，请重新分析后比较'); }
      let score = voiceSimilarity(this.reference.embedding, speaker.embedding);
      this.comparison = this.reference.name + ' ↔ ' + speaker.name + '\n余弦相似度 ' + score.toFixed(3) +
        '（越接近 1 越相似）\n仅供辅助判断，不能作为身份认证结果。';
    } catch (e) { this.message(e as Error); }
  }


  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  onBackPress(): boolean { this.goBack(); return true; }
  private goBack(): void {
    if (this.recording) {
      promptAction.showDialog({ title: '录音仍在继续', message: '结束并保存后可返回，锁屏不会中断录音。',
        buttons: [{ text: '继续录音', color: '#5260ED' }, { text: '结束并保存', color: '#FF453A' }] })
        .then((result): void => { if (result.index === 1) { this.stopRecording().catch((e: Error): void => { this.message(e); }); } });
      return;
    }
    if (this.busy) { this.cancel(); return; }
    if (this.selected !== null) {
      this.save(); this.selected = null; this.playback.stop().catch((): void => {}); this.playing = -2; this.status = ''; return;
    }
    router.back();
  }
  private async actions(): Promise<void> {
    if (this.busy) { return; }
    if (this.selected === null) {
      let result = await promptAction.showActionMenu({ title: '录音', buttons: [
        { text: '连接手表', color: '#172033' }, { text: '离线语音模型', color: '#172033' }, { text: '录音与转写设置', color: '#172033' }] });
      if (result.index === 0) { this.showWatch = true; this.scanWatches(); }
      if (result.index === 1) { this.showModels = true; }
      if (result.index === 2) { this.showOptions = true; }
    } else {
      let result = await promptAction.showActionMenu({ title: '这段录音', buttons: [
        { text: '重命名', color: '#172033' }, { text: '说话人与声纹', color: '#172033' },
        { text: this.canResumeAnalysis() ? '转写进度' : '重新转写', color: '#172033' },
        { text: '重新生成摘要', color: '#172033' }, { text: this.audioAvailable() ? '仅删除音频文件' : '音频已删除', color: '#FF453A' },
        { text: '删除整条记录', color: '#FF453A' }] });
      if (result.index === 0 && this.selected !== null) { this.beginRename(this.selected); }
      if (result.index === 1) { this.showSpeakers = true; }
      if (result.index === 2) { this.chooseAnalysis().catch((e: Error): void => { this.message(e); }); }
      if (result.index === 3) { this.summarize(true); }
      if (result.index === 4) { this.removeAudio().catch((e: Error): void => { this.message(e); }); }
      if (result.index === 5) { this.remove().catch((e: Error): void => { this.message(e); }); }
    }
  }
  private async scanWatches(): Promise<void> {
    if (this.watchScanning || this.busy) { return; }
    this.watchScanning = true; this.watchStatus = '正在查找已配对的手表';
    try {
      this.watchDevices = await this.watchSync.discover(this.context());
      this.watchStatus = this.watchDevices.length > 0 ? '选择手表，接收其中的录音。' : '请先在运动健康中配对手表，并保持连接。';
    } catch (e) { this.watchStatus = (e as Error).message; }
    finally { this.watchScanning = false; }
  }
  private async syncWatchDevice(device: RecordingWatchDevice): Promise<void> {
    if (this.busy || this.store === null) { return; }
    let epoch = ++this.epoch; let queue = ++this.queueEpoch; let received: RecordingRecord[] = [];
    this.busy = true; this.jobKind = 'watch'; this.error = ''; this.progress = 0;
    try {
      let count = await this.watchSync.sync(this.context(), device.id, this.store, (text: string): void => {
        if (this.alive && epoch === this.epoch) { this.status = text; this.watchStatus = text; }
      }, (record: RecordingRecord): void => { received.push(record); if (this.alive) { this.reload(); } });
      if (epoch !== this.epoch) { return; }
      this.watchStatus = count > 0 ? '已保存 ' + count + ' 条录音，手表原文件也会保留。' : '手表中还没有已完成的录音。';
      this.status = this.watchStatus;
    } catch (e) { if (epoch === this.epoch) { this.error = (e as Error).message; this.watchStatus = this.error; } }
    finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
    if (queue !== this.queueEpoch || !this.alive || !this.watchAutoAnalyze || received.length === 0) { return; }
    this.showWatch = false;
    let pending = received.filter((record: RecordingRecord): boolean => record.analysis === null);
    for (let index = 0; index < pending.length; index++) {
      if (queue !== this.queueEpoch || !this.alive) { break; }
      this.queueRemaining = pending.length - index; this.selected = pending[index]; this.detailTab = 'text';
      await this.analyze();
      if (this.error || this.showModels) { break; }
    }
    this.queueRemaining = 0;
  }
  private clockTime(date: Date): string {
    return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
  }
  private recordTitle(record: RecordingRecord): string {
    if (record.summary?.title.trim() && recordingUsesAutomaticTitle(record)) {
      return record.summary.title.replace(/\s+/g, ' ').trim().substring(0, 80);
    }
    // Compact legacy generated timestamp names for display only.
    if (record.titleEdited !== true && (record.source === '录制' || record.source === '手表') &&
      /^(录音|手表录音) \d{1,4}[\/-]\d{1,2}[\/-]\d{1,4}[,， ]+\d{1,2}:\d{2}:\d{2}(\s*[AP]M)?$/.test(record.title)) {
      let date = new Date(record.createdAt);
      if (Number.isFinite(date.getTime())) {
        return (record.source === '手表' ? '手表录音 ' : '录音 ') + this.clockTime(date);
      }
    }
    return record.title;
  }
  private recordDate(record: RecordingRecord, includeDuration: boolean = true): string {
    let date = new Date(record.createdAt);
    let label = (date.getFullYear() === new Date().getFullYear() ? '' : String(date.getFullYear()) + '年') +
      String(date.getMonth() + 1) + '月' + String(date.getDate()) + '日';
    return label + (includeDuration ? ' · ' + recordingTime(record.duration) : '') + ' · ' +
      (record.source === '录制' ? recordingAudioSourceLabel(record.audioSource || 'environment') : record.source);
  }
  private filteredSegments(): RecordingSegment[] { return this.segments().slice(0, this.visibleSegments); }

  @Builder private ModelsPanel() {
    Scroll() {
      Column({ space: 20 }) {
        Text('离线语音模型').fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
        Text('支持普通话、英语、日语、韩语和粤语')
          .fontSize(15).lineHeight(23).fontColor(AppTheme.text('#737D90')).width('100%')
        Row({ space: 14 }) {
          Text(this.modelCount === RECORDING_MODELS.length ? '✓' : '↓').fontSize(26)
            .fontColor(AppTheme.text('#5260ED')).width(44).height(44).textAlign(TextAlign.Center)
          Column({ space: 5 }) {
            Text(this.preparingModels ? '正在准备' : this.modelCount === RECORDING_MODELS.length ? '已就绪' : this.modelCount > 0 ? '尚未下载完成' : '待下载')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
            Text(this.modelCount === RECORDING_MODELS.length ? '可离线转写' : '约 270 MB · 下载后可离线转写')
              .fontSize(14).fontColor(AppTheme.text('#737D90'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(18).borderRadius(18).backgroundColor(AppTheme.background('#F2F4F8'))
        if (this.preparingModels) {
          Row({ space: 10 }) {
            LoadingProgress().width(22).height(22)
            Text(this.status).fontSize(15).lineHeight(22).fontColor(AppTheme.text('#007AFF')).layoutWeight(1)
          }.width('100%')
        }
        if (this.showModelProgress) {
          Column({ space: 8 }) {
            Progress({ value: this.modelProgress, total: 100, type: ProgressType.Linear })
              .width('100%').color(AppTheme.filledBackground('#5260ED')).backgroundColor(AppTheme.background('#EDEFF5'))
              .accessibilityText('模型准备进度 ' + this.modelProgress + '%')
            Row() {
              Text(this.modelProgressSize).fontSize(14).fontColor(AppTheme.text('#737D90')).layoutWeight(1)
              Text(String(this.modelProgress) + '%').fontSize(14).fontColor(AppTheme.text('#5260ED'))
            }.width('100%')
          }.width('100%')
        }
        if (this.error) { Text(this.error).fontSize(15).lineHeight(23).fontColor(AppTheme.text('#D74D47')).width('100%') }
        Button(this.modelCount === RECORDING_MODELS.length ? '检查模型' : '下载模型')
          .width('100%').height(50).fontSize(17).backgroundColor(AppTheme.filledBackground('#5260ED')).fontColor(Color.White)
          .enabled(!this.busy).onClick((): void => { this.prepareModels(false); })
        if (this.preparingModels) {
          Button('取消').fontSize(16).height(44).width('100%').backgroundColor(Color.Transparent)
            .fontColor(AppTheme.text('#D74D47')).onClick((): void => { this.cancel(); })
        }
        Row() {
          Text('更多选项').fontSize(16).fontColor(AppTheme.text('#737D90')).layoutWeight(1)
          Text('›').fontSize(22).fontColor(AppTheme.text('#8E8E93')).rotate({ angle: this.showModelOptions ? 90 : 0 })
        }.width('100%').padding({ top: 10, bottom: 10 })
          .accessibilityText(this.showModelOptions ? '收起更多选项' : '展开更多选项')
          .onClick((): void => { this.showModelOptions = !this.showModelOptions; })
        if (this.showModelOptions) {
          Column({ space: 12 }) {
            Row() {
              Text('下载地址').fontSize(16).fontColor(AppTheme.text('#172033'))
              Blank()
              Button('恢复默认').fontSize(14).height(40).backgroundColor(Color.Transparent).fontColor(AppTheme.text('#007AFF'))
                .enabled(!this.busy).onClick((): void => {
                  this.modelDownloadUrl = DEFAULT_RECORDING_MODEL_URL; this.saveModelSource();
                })
            }.width('100%')
            TextArea({ text: this.modelDownloadUrl, placeholder: 'https://…/resolve/master' })
              .width('100%').height(88).fontSize(14).fontColor(AppTheme.text('#172033'))
              .placeholderColor(AppTheme.text('#8E8E93')).backgroundColor(AppTheme.background('#F2F4F8'))
              .borderRadius(12).padding(12).maxLength(2048).enabled(!this.busy)
              .onChange((value: string): void => { this.modelDownloadUrl = value; this.modelSourceSaved = false; })
            Button(this.modelSourceSaved ? '地址已保存' : '保存地址')
              .width('100%').height(44).fontSize(16).backgroundColor(AppTheme.background('#EDF3FF')).fontColor(AppTheme.text('#007AFF'))
              .enabled(!this.busy).onClick((): void => { this.saveModelSource(); })
            Divider().color(AppTheme.border('#EDF0F5')).margin({ top: 4, bottom: 4 })
            Button('从文件导入').width('100%').height(44).fontSize(16)
              .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#007AFF'))
              .enabled(!this.busy).onClick((): void => { this.prepareModels(true); })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
      }
      .padding(24).width('100%')
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }

  @Builder private HomeHeader() {
    Column({ space: 12 }) {
      Text('留住每一刻的声音').fontSize(28).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      Text('从手腕到手机，让声音留下来。').fontSize(17).lineHeight(26).fontColor(AppTheme.text('#737D90')).width('100%')
    }.width('100%').padding({ top: 12, bottom: 20 })
    Row({ space: 12 }) {
      Text('声音来源').fontSize(17).fontColor(AppTheme.text('#172033'))
      Blank()
      Text(recordingAudioSourceLabel(this.audioSource)).fontSize(16).fontColor(AppTheme.text('#007AFF'))
      Text('›').fontSize(24).fontColor(AppTheme.text('#8E8E93'))
    }.width('100%').padding(18).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      .enabled(!this.busy).onClick((): void => { this.showAudioSources = true; })
    if (this.audioSource !== 'environment') {
      Text('系统内录会显示屏幕授权，仅录制声音，不录制画面。')
        .fontSize(14).lineHeight(21).fontColor(AppTheme.text('#737D90')).width('100%').padding({ left: 6, right: 6 })
    }
    this.SummarySourceSelector()
    Row() {
      Text('边录边转写').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.liveTranscribe }).enabled(!this.busy)
        .onChange((value: boolean): void => { this.liveTranscribe = value; })
    }.width('100%').padding(18).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
    Row({ space: 14 }) {
      Image($r('app.media.recording_watch')).width(28).height(28)
      Column({ space: 5 }) {
        Text('手表录音').fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Text('连接并接收录音').fontSize(15).fontColor(AppTheme.text('#737D90'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(28).fontColor(AppTheme.text('#8E8E93'))
    }.padding(20).width('100%').borderRadius(20).backgroundColor(AppTheme.background('#FFFFFF'))
      .enabled(!this.busy).onClick((): void => { this.showWatch = true; this.scanWatches(); })
    Row() {
      Text('所有录音').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
      Blank()
      Text(String(this.records.length) + ' 段').fontSize(15).fontColor(AppTheme.text('#8E8E93'))
    }.width('100%').margin({ top: 24, bottom: 4 })
  }
  @Builder private RecordActions(record: RecordingRecord) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Image($r('app.media.recording_rename')).width(21).height(21)
          Text('重命名').fontSize(14).fontColor(Color.White).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.width(78).height(68).padding(0).borderRadius(14)
        .backgroundColor(AppTheme.filledBackground('#5260ED')).fontColor(Color.White).enabled(!this.busy)
        .accessibilityText('重命名录音')
        .onClick((): void => { this.beginRename(record); })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Image($r('app.media.recording_delete')).width(21).height(21)
          Text('删除').fontSize(14).fontColor(Color.White).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.width(70).height(68).padding(0).borderRadius(14)
        .backgroundColor('#FF3B30').fontColor(Color.White).enabled(!this.busy)
        .accessibilityText('删除录音')
        .onClick((): void => { this.remove(record).catch((e: Error): void => { this.message(e); }); })
    }.height('100%').padding({ left: 10, right: 2 }).alignItems(VerticalAlign.Center)
  }
  @Builder private Home() {
    List({ scroller: this.recordingListScroller, space: 8 }) {
      ListItem() {
        Column({ space: 18 }) { this.HomeHeader() }.width('100%')
      }
      if (this.records.length === 0) {
        ListItem() {
          Column({ space: 12 }) {
            Image($r('app.media.source_recording')).width(40).height(40).opacity(0.6)
            Text('第一段声音，从这里开始').fontSize(18).fontColor(AppTheme.text('#737D90'))
            Text('轻点下方录音，也可以导入 WAV。').fontSize(15).lineHeight(24).fontColor(AppTheme.text('#8E8E93'))
          }.width('100%').padding({ top: 44, bottom: 44 })
        }
      } else {
        ForEach(this.records, (record: RecordingRecord) => {
          ListItem() {
            Row({ space: 14 }) {
              Image(record.watch ? $r('app.media.recording_watch') : $r('app.media.source_recording')).width(26).height(26)
              Column({ space: 7 }) {
                Text(this.recordTitle(record)).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(this.recordDate(record)).fontSize(14).fontColor(AppTheme.text('#8E8E93')).maxLines(1).width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Column({ space: 6 }) {
                Text(record.summary ? '摘要' : record.analysis ? (record.transcriptionComplete === false ? '部分转写' : '已转写') : '待转写').fontSize(14).fontColor(AppTheme.text('#737D90'))
                Text('›').fontSize(23).fontColor(AppTheme.text('#A3A9B4'))
              }
            }.width('100%').padding({ left: 18, right: 18, top: 20, bottom: 20 }).enabled(!this.busy)
              .onClick((): void => { this.openRecord(record); })
          }.width('100%').borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF')).clip(true).enabled(!this.busy)
            .swipeAction({ end: { builder: (): void => { this.RecordActions(record); } }, edgeEffect: SwipeEdgeEffect.Spring })
        }, (record: RecordingRecord): string => record.id)
      }
      ListItem() { Column({ space: 18 }) { this.Feedback() }.width('100%').padding({ top: 10 }) }
    }.width('100%').layoutWeight(1).padding({ left: 22, right: 22, top: 14, bottom: 20 }).scrollBar(BarState.Off)
  }
  @Builder private RecordingDock() {
    Row() {
      Column({ space: 8 }) {
        Button({ type: ButtonType.Circle }) { Image($r('app.media.recording_import')).width(25).height(25) }
          .width(48).height(48).backgroundColor(AppTheme.background('#EDEFF8')).enabled(!this.busy)
          .accessibilityText('导入 WAV').onClick((): void => { this.importAudio(); })
        Text('导入').fontSize(15).fontColor(AppTheme.text('#737D90'))
      }.layoutWeight(1)
      Column({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.recording) { Row().width(22).height(22).borderRadius(5).backgroundColor(Color.White) }
          else { Row().width(42).height(42).borderRadius(21).backgroundColor('#FF453A') }
        }.width(72).height(72).backgroundColor(this.recording ? '#FF453A' : AppTheme.background('#FFFFFF'))
          .border({ width: 3, color: '#FF453A' }).enabled(!this.busy || this.recording)
          .accessibilityText(this.recording ? '结束并保存录音' : '开始录音')
          .onClick((): void => { if (this.recording) { this.stopRecording().catch((e: Error): void => { this.message(e); }); } else { this.startRecording(); } })
        Text(this.recording ? '结束并保存' : '轻点录音').fontSize(15).fontColor(AppTheme.text('#737D90'))
      }.layoutWeight(1)
      Column({ space: 8 }) {
        Button({ type: ButtonType.Circle }) { Image($r('app.media.recording_watch')).width(27).height(27) }
          .width(48).height(48).backgroundColor(AppTheme.background('#EDEFF8')).enabled(!this.busy)
          .accessibilityText('连接手表').onClick((): void => { this.showWatch = true; this.scanWatches(); })
        Text('手表').fontSize(15).fontColor(AppTheme.text('#737D90'))
      }.layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 14, bottom: 28 })
  }

  @Builder private VoiceTimeline() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(6).borderRadius(3).backgroundColor(AppTheme.background('#E8EBF3'))
      ForEach(recordingTimeline(this.analysis()?.speech || [], this.analysis()?.duration || 0), (range: SpeechRange) => {
        Row().height(6).borderRadius(3).backgroundColor(AppTheme.filledBackground('#5260ED'))
          .width(String((range.end - range.start) / Math.max(0.01, this.analysis()?.duration || 0) * 100) + '%')
          .position({ x: String(range.start / Math.max(0.01, this.analysis()?.duration || 0) * 100) + '%', y: 0 })
      })
    }.height(6).width('100%').clip(true).accessibilityText('人声在整段录音中的分布')
  }
  @Builder private Detail() {
    if (this.selected !== null) {
      Column({ space: 16 }) {
        Text(this.recordTitle(this.selected)).fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.recordDate(this.selected, false)).fontSize(14).lineHeight(22).fontColor(AppTheme.text('#8E8E93')).width('100%')
        Row({ space: 18 }) {
          Button({ type: ButtonType.Circle }) {
            Image(this.playing === -1 ? $r('app.media.recording_stop') : $r('app.media.recording_play')).width(27).height(27)
          }.width(64).height(64).backgroundColor(AppTheme.background('#EDEFFC')).enabled(!this.busy && this.audioAvailable())
            .accessibilityText(this.playing === -1 ? '停止播放' : '播放录音').onClick((): void => { this.play(null); })
          Column({ space: 13 }) {
            this.VoiceTimeline()
            Row() {
              Text(!this.audioAvailable() ? '音频已删除' : this.playing === -1 ? '正在播放' : '播放录音').fontSize(15).fontColor(AppTheme.text('#737D90'))
              Blank()
              Text(recordingTime(this.selected.duration)).fontSize(15).fontColor(AppTheme.text('#737D90'))
            }.width('100%')
          }.layoutWeight(1)
        }.width('100%').padding({ top: 8, bottom: 16 })
        this.SummarySourceSelector()
        this.SpeakerSeparationSelector()
        if (!this.busy && this.audioAvailable() && this.analysis() !== null && (this.canResumeAnalysis() || this.selected.transcriptionComplete === false)) {
          Button(this.canResumeAnalysis() ? '继续转写' : '完成转写').fontSize(17).height(48).padding({ left: 28, right: 28 })
            .width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#5260ED'))
            .onClick((): void => { this.analyze(); })
        }
        if (this.analysis() === null) {
          if (!this.busy && this.audioAvailable()) {
            Button(this.canResumeAnalysis() ? '继续转写' : '开始转写').fontSize(17).height(48).padding({ left: 28, right: 28 })
              .width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#5260ED'))
              .onClick((): void => { this.analyze(); })
          }
          if (!this.audioAvailable()) { Text('音频已删除，这条记录没有可用的转写文字。').fontSize(15).fontColor(AppTheme.text('#8E8E93')).width('100%') }
        } else {
          Row({ space: 4 }) {
            Button('转写').fontSize(17).fontWeight(FontWeight.Medium).height(42).layoutWeight(1)
              .backgroundColor(AppTheme.background(this.detailTab === 'text' ? '#FFFFFF' : '#EDEFF5'))
              .fontColor(AppTheme.text(this.detailTab === 'text' ? '#172033' : '#737D90'))
              .onClick((): void => { this.detailTab = 'text'; })
            Button('摘要').fontSize(17).fontWeight(FontWeight.Medium).height(42).layoutWeight(1)
              .backgroundColor(AppTheme.background(this.detailTab === 'summary' ? '#FFFFFF' : '#EDEFF5'))
              .fontColor(AppTheme.text(this.detailTab === 'summary' ? '#172033' : '#737D90'))
              .onClick((): void => { this.detailTab = 'summary'; })
          }.width('100%').padding(4).borderRadius(16).backgroundColor(AppTheme.background('#EDEFF5'))
          Column({ space: 18 }) {
            if (this.detailTab === 'summary') {
              if (this.selected.summary) { RecordingSummaryView({ summary: this.selected.summary }) }
              if (!this.selected.summary || (this.selected.summary.source || 'cloud') !== this.summarySource ||
                (this.summarySource === 'local' && this.selected.summary.complete === false)) {
                if (!this.selected.summary) {
                Text('还没有摘要').fontSize(17).fontColor(AppTheme.text('#737D90')).width('100%')
                }
                Button(this.summarySource === 'local' && this.selected.summary?.complete === false ? '继续生成本地摘要' : '生成摘要')
                  .fontSize(17).height(46).padding({ left: 24, right: 24 }).fontColor(AppTheme.text('#5260ED'))
                  .backgroundColor(AppTheme.background('#EDEFFC')).enabled(!this.busy).onClick((): void => { this.summarize(); })
              }
            } else { this.Transcript() }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(22).borderRadius(22).backgroundColor(AppTheme.background('#FFFFFF'))
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
  @Builder private Transcript() {
    Row() {
      Text('对话记录').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
      Blank()
      Text('说话人').fontSize(16).fontColor(AppTheme.text('#5260ED')).padding({ top: 10, bottom: 10 })
        .onClick((): void => { this.showSpeakers = true; })
    }.width('100%')
    if (this.filterSpeaker !== -2) {
      Text('仅看 ' + this.speakerName(this.filterSpeaker) + ' · 显示全部').fontSize(15).fontColor(AppTheme.text('#5260ED'))
        .onClick((): void => { this.filterSpeaker = -2; this.visibleSegments = 60; })
    }
    if (this.segments().length === 0) { Text('这段录音没有可转写的人声。').fontSize(17).fontColor(AppTheme.text('#8E8E93')) }
    ForEach(this.filteredSegments(), (segment: RecordingSegment) => {
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Row().width(7).height(7).borderRadius(4).backgroundColor(this.color(segment.speaker))
          Text(this.speakerName(segment.speaker)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.color(segment.speaker)).layoutWeight(1)
          Text(recordingTime(segment.start)).fontSize(14).fontColor(AppTheme.text('#8E8E93'))
          Button({ type: ButtonType.Circle }) {
            Image(this.playing === segment.id ? $r('app.media.recording_stop') : $r('app.media.recording_play')).width(15).height(15)
          }.width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.busy && this.audioAvailable()).accessibilityText('播放这段对话')
            .onClick((): void => { this.play(segment); })
        }.width('100%')
        Text(segment.text || '未识别到文字').fontSize(18).lineHeight(30).fontColor(AppTheme.text('#172033')).width('100%').copyOption(CopyOptions.InApp)
      }.width('100%').padding({ top: 6, bottom: 20 })
      Divider().color(AppTheme.border('#EDF0F5'))
    }, (segment: RecordingSegment): string => String(segment.id) + segment.text)
    if (this.segments().length > this.visibleSegments) {
      Text('继续阅读').fontSize(17).fontColor(AppTheme.text('#5260ED')).padding(14).onClick((): void => { this.visibleSegments += 60; })
    }
    Text(this.analysis()?.method === 'live' || this.analysis()?.method === 'transcription' ?
      '当前转写未区分说话人，可开启上方开关后重新转写。' :
      '转写与说话人区分可能有误，可点播放核对。').fontSize(14).lineHeight(23).fontColor(AppTheme.text('#8E8E93')).width('100%')
    if (this.selected?.transcriptionComplete === false) {
      Text('这是已保存的部分转写，录音仍在时可以完成转写。').fontSize(14).lineHeight(23).fontColor(AppTheme.text('#B27A28')).width('100%')
    }
  }

  @Builder private SpeakerSeparationSelector() {
    Row({ space: 12 }) {
      Column({ space: 5 }) {
        Text('区分说话人').fontSize(17).fontColor(AppTheme.text('#172033')).width('100%')
        Text(this.separateSpeakers ? '区分不同声音，转写耗时更长' : '仅转写文字，速度更快')
          .fontSize(15).fontColor(AppTheme.text('#737D90')).width('100%')
      }.layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.speakerSwitchOn })
        .enabled(!this.busy && !this.recording && !this.confirmingSpeakerSeparation)
        .onChange((value: boolean): void => {
          this.setSpeakerSeparation(value).catch((e: Error): void => { this.message(e); });
        })
    }.width('100%').padding(16).borderRadius(16).backgroundColor(AppTheme.background('#FFFFFF'))
  }
  @Builder private SummarySourceSelector() {
    Row({ space: 8 }) {
      Text('摘要方式').fontSize(16).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Button('本地').fontSize(15).height(36).width(72).padding(0)
        .fontColor(this.summarySource === 'local' ? Color.White : AppTheme.text('#737D90'))
        .backgroundColor(this.summarySource === 'local' ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
        .onClick((): void => { this.summarySource = 'local'; })
      Button('云端').fontSize(15).height(36).width(72).padding(0)
        .fontColor(this.summarySource !== 'local' ? Color.White : AppTheme.text('#737D90'))
        .backgroundColor(this.summarySource !== 'local' ? AppTheme.filledBackground('#5260ED') : AppTheme.background('#EDEFF5'))
        .onClick((): void => { this.summarySource = 'cloud'; })
    }.width('100%').padding(14).borderRadius(16).backgroundColor(AppTheme.background('#FFFFFF')).enabled(!this.busy)
  }
  @Builder private OptionsPanel() {
    Column({ space: 24 }) {
      Text('录音与转写').fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      Row() {
        Text('音频语言').fontSize(18).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Select(this.languageLabels.map((label: string): SelectOption => ({ value: label }))).selected(this.languageIndex)
          .value(this.languageLabels[this.languageIndex]).font({ size: 17 }).onSelect((index: number): void => { this.languageIndex = index; })
      }.width('100%')
      Divider().color(AppTheme.border('#EDF0F5'))
      Row() {
        Text('边录边转写').fontSize(18).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.liveTranscribe }).enabled(!this.busy)
          .onChange((value: boolean): void => { this.liveTranscribe = value; })
      }.width('100%')
      Row() {
        Text('转写后生成摘要').fontSize(18).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoSummary }).onChange((value: boolean): void => { this.autoSummary = value; })
      }.width('100%')
      this.SummarySourceSelector()
      Text(this.summarySource === 'local' ? '在本机分段整理，每段保留摘要与待办。' : '转写在本机完成，摘要使用云端模型。')
        .fontSize(14).lineHeight(22).fontColor(AppTheme.text('#737D90')).width('100%')
      Text('单段最长 12 小时').fontSize(14).fontColor(AppTheme.text('#8E8E93')).width('100%')
      Text('管理离线语音模型').fontSize(17).fontColor(AppTheme.text('#5260ED')).padding({ top: 12, bottom: 12 })
        .onClick((): void => { this.showOptions = false; setTimeout((): void => { if (this.alive) { this.showModels = true; } }, 320); })
    }.padding(26).width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private WatchPanel() {
    Scroll() {
      Column({ space: 22 }) {
        Image($r('app.media.recording_watch')).width(42).height(42)
        Text('手腕上的声音，\n回到手机里。').fontSize(28).fontWeight(FontWeight.Bold).lineHeight(40).fontColor(AppTheme.text('#172033')).width('100%')
        Text(this.watchStatus).fontSize(17).lineHeight(28).fontColor(AppTheme.text('#737D90')).width('100%')
        if (this.watchScanning || this.jobKind === 'watch') { LoadingProgress().width(32).height(32) }
        ForEach(this.watchDevices, (device: RecordingWatchDevice) => {
          Row() {
            Text(device.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).layoutWeight(1)
            Text('接收录音 ›').fontSize(16).fontColor(AppTheme.text('#5260ED'))
          }.width('100%').padding({ top: 18, bottom: 18 }).enabled(!this.busy)
            .onClick((): void => { this.syncWatchDevice(device); })
          Divider().color(AppTheme.border('#EDF0F5'))
        }, (device: RecordingWatchDevice): string => device.id)
        Row() {
          Text('接收后自动转写').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.watchAutoAnalyze }).enabled(!this.busy)
            .onChange((value: boolean): void => { this.watchAutoAnalyze = value; })
        }.width('100%')
        Text('手表需先在运动健康中配对并安装 ClawMate。接收会核对文件完整性；重复同步保留已有转写，手表原录音不会删除。')
          .fontSize(15).lineHeight(25).fontColor(AppTheme.text('#8E8E93')).width('100%')
        Text(this.jobKind === 'watch' ? '停止接收' : '重新查找手表').fontSize(17).fontColor(AppTheme.text('#5260ED')).padding(12)
          .onClick((): void => { if (this.jobKind === 'watch') { this.cancel(); } else { this.scanWatches(); } })
      }.padding(26).width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  @Builder private SpeakersPanel() {
    Scroll() {
      Column({ space: 20 }) {
        Text('说话人与声纹').fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
        Text('修改称呼，或选取另一段清晰声音作比较。').fontSize(16).lineHeight(26).fontColor(AppTheme.text('#737D90')).width('100%')
        ForEach(this.analysis()?.speakers || [], (speaker: RecordingSpeaker) => {
          Column({ space: 12 }) {
            TextInput({ text: speaker.name, placeholder: '说话人称呼' }).fontSize(18).height(48).maxLength(32).enabled(!this.busy)
              .onChange((text: string): void => { speaker.name = text; this.refreshSelected(); }).onBlur((): void => { this.save(); })
            Row() {
              Text('只看此人的对话').fontSize(16).fontColor(AppTheme.text('#5260ED')).padding({ top: 10, bottom: 10 })
                .onClick((): void => { this.filterSpeaker = speaker.id; this.detailTab = 'text'; this.showSpeakers = false; })
              Blank()
              Text(this.reference === null ? '选作参考' : '比较声纹').fontSize(16)
                .fontColor(AppTheme.text(speaker.embedding.length > 0 ? '#5260ED' : '#A3A9B4')).padding({ top: 10, bottom: 10 })
                .enabled(speaker.embedding.length > 0).onClick((): void => { this.compare(speaker); })
            }.width('100%')
            if (speaker.embedding.length === 0) { Text('独立语音较短，尚未提取可用声纹。').fontSize(15).fontColor(AppTheme.text('#8E8E93')).width('100%') }
            Divider().color(AppTheme.border('#EDF0F5'))
          }.width('100%')
        }, (speaker: RecordingSpeaker): string => String(speaker.id))
        if (this.reference !== null) {
          Text(this.comparison || this.reference.name).fontSize(16).lineHeight(26).fontColor(AppTheme.text('#737D90')).width('100%')
          Text('清除参考声纹').fontSize(16).fontColor(AppTheme.text('#5260ED')).padding(12)
            .onClick((): void => { this.reference = null; this.comparison = ''; })
        }
      }.padding(26).width('100%').alignItems(HorizontalAlign.Start)
    }.height('100%').width('100%').scrollBar(BarState.Off)
  }
  @Builder private RenamePanel() {
    Column({ space: 24 }) {
      Text('重命名').fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      TextInput({ text: this.editTitle, placeholder: '录音名称' }).fontSize(19).height(54).maxLength(80)
        .onChange((value: string): void => { this.editTitle = value; })
      Text('完成').fontSize(18).fontColor(AppTheme.text('#5260ED')).padding(12).enabled(!this.busy && this.editTitle.trim().length > 0)
        .onClick((): void => { this.finishRename(); })
    }.padding(26).width('100%')
  }
  @Builder private Feedback() {
    if (this.busy && !this.recording) {
      Column({ space: 14 }) {
        Row({ space: 14 }) {
          LoadingProgress().width(24).height(24)
          Text(this.status || '正在准备').fontSize(16).lineHeight(25).fontColor(AppTheme.text('#5260ED')).layoutWeight(1)
          Text('停止').fontSize(16).fontColor(AppTheme.text('#8E8E93')).padding(12).onClick((): void => { this.cancel(); })
        }.width('100%')
        if (this.jobKind === 'analysis' || this.jobKind === 'live-finalizing' || (this.jobKind === 'summary' && this.summarySource === 'local')) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear }).width('100%')
        }
        if (this.preparingModels && this.showModelProgress) {
          Progress({ value: this.modelProgress, total: 100, type: ProgressType.Linear }).width('100%')
          Text(this.modelProgressSize + ' · ' + this.modelProgress + '%').fontSize(14).fontColor(AppTheme.text('#737D90'))
        }
        if (this.queueRemaining > 0) { Text('手表录音队列剩余 ' + this.queueRemaining + ' 段').fontSize(15).fontColor(AppTheme.text('#8E8E93')) }
      }.width('100%').padding(20).borderRadius(20).backgroundColor(AppTheme.background('#FFFFFF'))
    }
    if (this.error.length > 0) { Text(this.error).fontSize(16).lineHeight(26).fontColor(AppTheme.text('#D74D47')).width('100%') }
    if (this.status.length > 0 && !this.busy) { Text(this.status).fontSize(15).lineHeight(24).fontColor(AppTheme.text('#737D90')).width('100%') }
  }
  @Builder private Content() {
    Column() {
      if (this.selected === null && !this.recording) { this.Home() }
      else {
        Scroll(this.scroller) {
          Column({ space: 18 }) {
            if (this.recording) {
              Column({ space: 24 }) {
                Text('正在留住这一刻').fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
                Text(recordingTime(this.seconds)).fontSize(48).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#FF453A'))
                Text(recordingAudioSourceLabel(this.audioSource)).fontSize(17).fontColor(AppTheme.text('#8E8E93'))
              }.width('100%').padding({ top: 26, bottom: 24 })
              if (this.liveStatus) {
                Column({ space: 14 }) {
                  Row() {
                    Text('实时转写').fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                    Blank()
                    if (this.live !== null && this.liveSegments.length === 0) { LoadingProgress().width(20).height(20).color(AppTheme.text('#5260ED')) }
                  }.width('100%')
                  if (this.liveSegments.length === 0) {
                    Text(this.live !== null ? '说话后稍作停顿，文字会出现在这里。' : this.liveStatus).fontSize(15).lineHeight(25).fontColor(AppTheme.text('#8E8E93')).width('100%')
                  }
                  ForEach(this.liveSegments.slice(-3), (segment: RecordingSegment) => {
                    Column({ space: 5 }) {
                      Text(recordingTime(segment.start)).fontSize(12).fontColor(AppTheme.text('#8E8E93')).width('100%')
                      Text(segment.text).fontSize(17).lineHeight(27).fontColor(AppTheme.text('#25304A')).width('100%')
                    }.width('100%').alignItems(HorizontalAlign.Start)
                  }, (segment: RecordingSegment): string => segment.start.toString())
                  Text(this.liveStatus).fontSize(12).fontColor(AppTheme.text('#8E8E93')).width('100%')
                }.width('100%').alignItems(HorizontalAlign.Start).padding(20).borderRadius(20).backgroundColor(AppTheme.background('#FFFFFF'))
              }
            } else { this.Detail() }
            this.Feedback()
          }.width('100%').padding({ left: 22, right: 22, top: 14, bottom: 30 })
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
      }
      if (this.selected === null || this.recording) { this.RecordingDock() }
    }.width('100%').height('100%')
  }
  @Builder private PageHeader() {
    AppHeader({ title: this.selected === null ? '录音' : '录音详情', showBackButton: true, actionLabel: '更多',
      onBackClick: (): void => { this.goBack(); }, onActionClick: (): void => { this.actions().catch((): void => {}); } })
  }
  @Builder private AudioSourcesPanel() {
    Column({ space: 16 }) {
      Text('声音来源').fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      ForEach(this.audioSources, (source: string) => {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(recordingAudioSourceLabel(source)).fontSize(18).fontColor(AppTheme.text('#172033'))
            Text(source === 'environment' ? '通过麦克风录制周围的声音' : source === 'mixed' ? '同时录制麦克风与手机播放的声音' : '录制手机播放的声音，不使用麦克风')
              .fontSize(14).lineHeight(20).fontColor(AppTheme.text('#737D90'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(this.audioSource === source ? '✓' : '○').fontSize(22).fontColor(AppTheme.text('#007AFF'))
        }.padding(16).width('100%').borderRadius(16).backgroundColor(AppTheme.background('#F4F5FA'))
          .onClick((): void => { this.audioSource = source; this.showAudioSources = false; })
      }, (source: string): string => source)
      Text('系统内录会显示屏幕授权，仅采集声音，不录制画面。部分应用或受保护内容可能无法录制。')
        .fontSize(14).lineHeight(21).fontColor(AppTheme.text('#8E8E93')).width('100%')
    }.padding(24).width('100%')
  }
  build() {
    Stack() {
      FrostedPage({ pageBackgroundColor: '#F6F7FA', scrollers: [this.scroller, this.recordingListScroller],
        headerBuilder: (): void => { this.PageHeader(); }, contentBuilder: (): void => { this.Content(); } })
      Row().width(0).height(0)
        .bindSheet(this.showAudioSources, this.AudioSourcesPanel(), { height: 460, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showAudioSources = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showModels, this.ModelsPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showModels = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showWatch, this.WatchPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showWatch = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showOptions, this.OptionsPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showOptions = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showSpeakers, this.SpeakersPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showSpeakers = false; this.save(); } })
      Row().width(0).height(0)
        .bindSheet(this.showRename, this.RenamePanel(), { height: 300, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showRename = false; this.renameTarget = null; } })
    }.width('100%').height('100%')
  }
}
