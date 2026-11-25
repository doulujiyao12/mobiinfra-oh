import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { appBackgroundTasks } from '../../utils/AppBackgroundTasks';
import { RecordingAnalysisRunner } from '../../utils/recording/RecordingAnalysisRunner';
import { RecordingSummaryService } from '../../utils/recording/RecordingSummaryService';
import { LocalTextInference } from '../../utils/LocalTextInference';
import { RecordingWatchSync, RecordingWatchDevice } from '../../utils/recording/RecordingWatchSync';
import { RecordingWatchItem, RecordingWatchSelection, selectWatchRecordings,
  watchRecordingProcessingStage } from '../../utils/recording/RecordingWatchSelection';
import { WatchRecordingPickerView } from './WatchRecordingPickerView';
import { AppLogger } from '../../utils/AppLogger';
import { RecordingSummaryView } from './RecordingSummaryView';
import { RecordingSettingsView } from './RecordingSettingsView';
import { RecordingCalendarView } from './RecordingCalendarView';
import { MarkdownView } from '../../components/MarkdownView';
import { RecordingSearchService } from '../../utils/recording/RecordingSearchService';
import { RecordingSearchHit, searchRecordingKeywords } from '../../utils/recording/RecordingSearch';
import { RecordingCalendarScope, RecordingCalendarWeek, recordingCalendarMonth, recordingCalendarMonthTitle,
  shiftRecordingCalendarMonth, recordingCalendarCounts, recordingCalendarWeeks, recordingCalendarWeekIndex,
  filterRecordingCalendar, recordingCardClock, recordingCardPreview } from '../../utils/recording/RecordingCalendar';
import { AppTheme, APP_DARK_MODE_KEY } from '../../utils/AppTheme';
import { FrostedPage } from '../../components/FrostedPage';
import { APP_HEADER_CONTENT_GAP, AppHeader } from '../../components/AppHeader';
import { ClassroomMaterialsView, ClassroomPhotoStrip } from './ClassroomMaterialsView';
import { CourseStudyView } from './CourseStudyView';
import { courseLibraryPath, courseRunIds } from '../../utils/recording/CourseStudy';
import { CodexChatService } from '../codex/CodexChatService';
import { ClassroomCourseView } from './ClassroomCourseView';
import { CLASSROOM_NOTE_LIMIT, CLASSROOM_UNASSIGNED, ClassroomCourse, ClassroomCourseRow, ClassroomCourseStore,
  classroomCourseRows, classroomRecordCourse } from '../../utils/recording/ClassroomCourses';
import { CLASSROOM_SOURCE, ClassroomPhoto, RecordingRouteParams } from '../../utils/recording/ClassroomMaterials';
import { classroomPhotos, photographLesson } from '../../utils/recording/ClassroomFiles';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { RecordingStore } from '../../utils/recording/RecordingStore';
import { DEFAULT_RECORDING_MODEL_URL, RecordingModelProgress, RecordingModels, RECORDING_MODELS } from '../../utils/recording/RecordingModels';
import { RecordingCapture } from '../../utils/recording/RecordingCapture';
import { RecordingLiveRunner } from '../../utils/recording/RecordingLiveRunner';
import { RecordingSystemAsrRunner } from '../../utils/recording/RecordingSystemAsrRunner';
import { SYSTEM_ASR_MODEL_ID } from '../../utils/recording/RecordingSystemAsrPolicy';
import { RecordingLiveCheckpoint } from '../../utils/recording/RecordingLiveCheckpoint';
import { RecordingLiveUpdate, RecordingLiveTranscriber, emptyLiveAnalysis } from '../../utils/recording/RecordingLiveTypes';
import { recordingAudioSource, recordingAudioSourceLabel } from '../../utils/recording/RecordingAudioSource';
import { RecordingPlayback } from '../../utils/recording/RecordingPlayback';
import { applyPageStatusBar } from '../../utils/PageStatusBar';
import { RECORDING_INBOX_KEY } from '../../utils/recording/RecordingInbox';
import { DEFAULT_RECORDING_TRANSCRIPTION_ENGINE, DEFAULT_RECORDING_SUMMARY_SOURCE, DEFAULT_RECORDING_LIVE_TRANSCRIBE,
  DEFAULT_RECORDING_AI_SEARCH, initializeRecordingPreferences } from '../../utils/recording/RecordingPreferences';
import { RecordingAnalysis, RecordingJob, RecordingRecord, RecordingSegment, RecordingSpeaker,
  RecordingWorkerMessage, SpeechRange, applyRecordingSummary, recordingUsesAutomaticTitle,
  recordingTime, recordingTimeline, voiceSimilarity } from '../../utils/recording/RecordingTypes';

initializeRecordingPreferences();
const SPEAKER_COLORS: string[] = ['#007AFF', '#AF52DE', '#229B78', '#DD8D24', '#DD5E83'];
const RECORDING_DOCK_INSET: number = 72;
// Keep the title's fade inside the breathing space above the first controls.
const RECORDING_TITLE_FADE_HEIGHT: number = 8;
interface VoiceReference { recordId: string; modelId: string; name: string; embedding: number[]; }
interface PendingWatchProcessing { recordIds: string[]; queue: number; transferError: string; }

@Entry
@Component
struct RecordingPage {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @State private classroom: boolean = false;
  @State private courseScope: string = '';
  @State private courseSection: string = 'lessons';
  @State private studySelected: string[] = [];
  @State private studyMode: string = '提取要点';
  @State private studyInstruction: string = '';
  private studyScroller: Scroller = new Scroller();
  @State private courses: ClassroomCourse[] = [];
  @State private courseRows: ClassroomCourseRow[] = [];
  @State private classroomRecords: RecordingRecord[] = [];
  @State private courseSheetOpen: boolean = false;
  @State private courseSheetMode: string = '';
  @State private courseDraft: string = '';
  @State private courseSelection: string[] = [];
  @State private courseError: string = '';
  @State private noteSheetOpen: boolean = false;
  @State private noteTitle: string = '';
  @State private noteDraft: string = '';
  @State private liveClassroomNotes: string = '';
  private courseStore: ClassroomCourseStore | null = null;
  private noteRecordId: string = '';
  private originalNoteRecording: RecordingRecord | null = null;
  @State private takingPhoto: boolean = false;
  @State private livePhotos: ClassroomPhoto[] = [];
  @State private livePhotoDirectory: string = '';
  @State private records: RecordingRecord[] = [];
  @State private recordingSearchQuery: string = '';
  @StorageLink('recordingAiSearch') private recordingAiSearch: boolean = DEFAULT_RECORDING_AI_SEARCH;
  @State private calendarMonth: string = recordingCalendarMonth(new Date());
  @State private calendarDay: string = '';
  @State private calendarScope: RecordingCalendarScope = 'all';
  @State private calendarWeeks: RecordingCalendarWeek[] = [];
  @State private calendarWeekIndex: number = 0;
  private calendarCounts: Map<string, number> = new Map<string, number>();
  @State private recordingSearchHits: RecordingSearchHit[] = [];
  @State private recordingSearchBusy: boolean = false;
  @State private recordingSearchRan: boolean = false;
  @State private recordingSearchAnswer: string = '';
  @State private recordingSearchStatus: string = '';
  @State private recordingSearchNotice: string = '';
  @State private recordingSearchRange: string = '';
  @State private recordingSearchError: string = '';
  private recordingSearchService: RecordingSearchService = new RecordingSearchService();
  private recordingSearchEpoch: number = 0;
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
  @StorageLink('recordingLanguageIndex') private languageIndex: number = 0;
  @State private playing: number = -2;
  @State private reference: VoiceReference | null = null;
  @State private comparison: string = '';
  private store: RecordingStore | null = null;
  private models: RecordingModels | null = null;
  private capture: RecordingCapture = new RecordingCapture();
  private playback: RecordingPlayback = new RecordingPlayback();
  @StorageLink('recordingAutoSummary') private autoSummary: boolean = true;
  @StorageLink('recordingAudioSource') private audioSource: string = 'environment';
  @StorageLink('recordingSummarySource') private summarySource: string = DEFAULT_RECORDING_SUMMARY_SOURCE;
  @StorageLink('recordingLiveTranscribe') private liveTranscribe: boolean = DEFAULT_RECORDING_LIVE_TRANSCRIBE;
  @StorageLink('recordingSpeakerSeparation') private separateSpeakers: boolean = false;
  @StorageLink('recordingTranscriptionEngine') private transcriptionEngine: string = DEFAULT_RECORDING_TRANSCRIPTION_ENGINE;
  @State private speakerSwitchOn: boolean = false;
  @State private confirmingSpeakerSeparation: boolean = false;
  @State private liveSegments: RecordingSegment[] = [];
  @State private livePreviewText: string = '';
  @State private livePreviewStart: number = 0;
  @State private liveStatus: string = '';
  private live: RecordingLiveTranscriber | null = null;
  private systemAsr: RecordingSystemAsrRunner | null = null;
  @State private showAudioSources: boolean = false;
  private audioSources: string[] = ['environment', 'mixed', 'system'];
  private captureStopPending: boolean = false;
  @State private showWatch: boolean = false;
  @State private showRecordingSettings: boolean = false;
  @State private showSpeakers: boolean = false;
  @State private showRename: boolean = false;
  @State private editTitle: string = '';
  @State private detailTab: string = 'text';
  @State private visibleSegments: number = 60;
  @State private watchDevices: RecordingWatchDevice[] = [];
  @State private watchScanning: boolean = false;
  @State private watchStatus: string = '接收手表上的录音，在手机上转写。';
  @State private watchAutoAnalyze: boolean = true;
  @State private watchDevice: RecordingWatchDevice | null = null;
  @State private watchItems: RecordingWatchItem[] = [];
  @State private watchSourceId: string = '';
  @State private watchSelectedIds: string[] = [];
  @State private watchQueueRunning: boolean = false;
  @State private queueRemaining: number = 0;
  private analyzer: RecordingAnalysisRunner = new RecordingAnalysisRunner();
  private summaryService: RecordingSummaryService = new RecordingSummaryService();
  private watchSync: RecordingWatchSync = new RecordingWatchSync();
  private jobKind: string = '';
  private queueEpoch: number = 0;
  private pendingWatchProcessing: PendingWatchProcessing | null = null;
  private recordingStartedAt: number = 0;
  private startingRecording: boolean = false;
  private timer: number = -1;
  private epoch: number = 0;
  private alive: boolean = true;
  private externalInteraction: boolean = false;
  private preparingModels: boolean = false;
  private recordingDraft: RecordingRecord | null = null;
  private scroller: Scroller = new Scroller();
  private classroomCourseScroller: Scroller = new Scroller();
  private recordingSettingsScroller: Scroller = new Scroller();
  private recordingListScroller: ListScroller = new ListScroller();
  private renameTarget: RecordingRecord | null = null;
  private languages: string[] = ['auto', 'zh', 'en', 'ja', 'ko', 'yue'];
  private backgroundCancelled: () => void = (): void => {
    if (this.recording) { this.error = '系统结束了后台录音，已保存录到的声音'; this.stopRecording().catch((e: Error): void => { this.message(e); }); }
  };
  private backgroundHandler: () => void = (): void => {
    let transcribing = this.busy && this.jobKind === 'analysis'; this.leavePage();
    if (transcribing) { this.status = '转写已暂停，已完成的进度已保存，返回后可继续'; }
  };

  aboutToAppear(): void {
    this.alive = true;
    this.classroom = (router.getParams() as RecordingRouteParams)?.classroom === true;
    this.speakerSwitchOn = this.separateSpeakers;
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.store = new RecordingStore(context.filesDir); this.models = new RecordingModels(context);
      if (this.classroom) { this.courseStore = new ClassroomCourseStore(this.store.root); }
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
      if (!this.classroom && id.length > 0 && !this.busy) {
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
    this.stopRecordingSearch(false);
    if (this.externalInteraction) { return; }
    if (this.recording) { return; }
    this.pendingWatchProcessing = null;
    if (this.busy || this.watchQueueRunning) { this.cancel(); }
    this.playback.stop().catch((): void => {}); this.playing = -2;
  }
  private reload(): void {
    if (this.store === null) { return; }
    const records = this.store.list();
    if (this.classroom) {
      this.courses = this.courseStore?.list() || [];
      this.classroomRecords = records.filter((item: RecordingRecord): boolean => item.source === CLASSROOM_SOURCE);
      this.courseRows = classroomCourseRows(this.courses, this.classroomRecords);
      this.records = this.classroomRecords.filter((item: RecordingRecord): boolean =>
        classroomRecordCourse(item, this.courses) === this.courseScope);
    } else { this.records = records.filter((item: RecordingRecord): boolean => !item.classroomNoteOnly); }
    this.refreshRecordingCalendar();
    if (!this.recordingAiSearch && this.recordingSearchActive()) {
      this.recordingSearchHits = searchRecordingKeywords(this.records, [this.recordingSearchQuery]);
    } else {
      let retained = this.recordingSearchHits.filter((hit: RecordingSearchHit): boolean =>
        this.records.some((record: RecordingRecord): boolean => record.id === hit.recordId));
      if (retained.length !== this.recordingSearchHits.length) {
        this.stopRecordingSearch(false); this.recordingSearchAnswer = '';
        this.recordingSearchNotice = '录音已变更，可重新搜索'; this.recordingSearchHits = retained;
      }
    }
  }
  private recordingSearchActive(): boolean { return this.recordingSearchQuery.trim().length > 0; }
  private recordingDockVisible(): boolean {
    return !this.showRecordingSettings && (this.recording || (this.selected === null && !this.recordingSearchActive() &&
      (!this.classroom || (this.hasCourse() && this.courseSection === 'lessons'))));
  }
  private stopRecordingSearch(notify: boolean): void {
    let running = this.recordingSearchBusy;
    this.recordingSearchEpoch++; this.recordingSearchService.cancel(); this.recordingSearchBusy = false;
    this.recordingSearchStatus = '';
    if (notify && running) { this.recordingSearchNotice = '搜索已停止'; }
  }
  private changeRecordingSearch(query: string): void {
    this.stopRecordingSearch(false); this.recordingSearchQuery = query;
    this.recordingSearchAnswer = ''; this.recordingSearchNotice = ''; this.recordingSearchRange = ''; this.recordingSearchError = '';
    this.recordingSearchRan = !this.recordingAiSearch && query.trim().length > 0;
    this.recordingSearchHits = this.recordingSearchRan ? searchRecordingKeywords(this.records, [query]) : [];
  }
  private recordingSearchRows(): RecordingRecord[] {
    if (!this.recordingSearchActive()) { return filterRecordingCalendar(this.records, this.calendarScope, this.calendarMonth, this.calendarDay); }
    let result: RecordingRecord[] = [];
    for (let hit of this.recordingSearchHits) {
      let record = this.records.find((value: RecordingRecord): boolean => value.id === hit.recordId);
      if (record) { result.push(record); }
    }
    return result;
  }
  private recordingSearchExcerpt(id: string): string {
    return this.recordingSearchHits.find((hit: RecordingSearchHit): boolean => hit.recordId === id)?.snippet || '';
  }
  private recordingSearchNumber(id: string): string {
    return String(this.recordingSearchHits.findIndex((hit: RecordingSearchHit): boolean => hit.recordId === id) + 1);
  }
  private refreshRecordingCalendar(anchor: string = ''): void {
    this.calendarCounts = recordingCalendarCounts(this.records);
    let previousAnchor = this.calendarWeeks[this.calendarWeekIndex]?.key || '';
    this.calendarWeeks = recordingCalendarWeeks(this.calendarMonth, this.calendarCounts);
    let today = new Date();
    let todayKey = recordingCalendarMonth(today) + '-' + String(today.getDate()).padStart(2, '0');
    this.calendarWeekIndex = recordingCalendarWeekIndex(this.calendarWeeks, anchor || this.calendarDay || previousAnchor || todayKey);
  }
  private shiftRecordingMonth(offset: number): void {
    if (this.busy) { return; }
    this.calendarMonth = shiftRecordingCalendarMonth(this.calendarMonth, offset);
    this.calendarDay = ''; this.calendarScope = 'month';
    this.refreshRecordingCalendar(this.calendarMonth + '-01');
  }
  private selectRecordingDay(key: string): void {
    if (this.busy || !this.calendarWeeks.some((week: RecordingCalendarWeek): boolean =>
      week.days.some((day): boolean => day.key === key))) { return; }
    this.calendarMonth = key.slice(0, 7); this.calendarDay = key; this.calendarScope = 'day';
    this.refreshRecordingCalendar(key);
    this.recordingListScroller.scrollToIndex(0);
  }
  private clearRecordingDate(): void {
    this.calendarDay = ''; this.calendarScope = 'all';
  }
  private recordingCardText(record: RecordingRecord): string {
    if (this.classroom && record.classroomNotes?.trim()) { return record.classroomNotes; }
    if (record.classroomNoteOnly) { return '可补充录音、笔记和课件'; }
    return this.recordingSearchActive() ? this.recordingSearchExcerpt(record.id) || recordingCardPreview(record) : recordingCardPreview(record);
  }
  private recordingCardMeta(record: RecordingRecord): string {
    if (record.classroomNoteOnly) { return '课堂笔记'; }
    return recordingTime(record.duration) + ' · ' + (record.summary ? '已摘要' : record.analysis ?
      record.transcriptionComplete === false ? '部分转写' : '已转写' : '待转写');
  }
  private async runRecordingSearch(): Promise<void> {
    if (this.busy || this.recording || !this.recordingSearchActive()) { return; }
    if (!this.recordingAiSearch) { this.changeRecordingSearch(this.recordingSearchQuery); return; }
    this.stopRecordingSearch(false);
    let epoch = this.recordingSearchEpoch;
    this.recordingSearchBusy = true; this.recordingSearchRan = true;
    this.recordingSearchHits = []; this.recordingSearchAnswer = ''; this.recordingSearchError = '';
    this.recordingSearchNotice = ''; this.recordingSearchRange = '';
    try {
      let result = await this.recordingSearchService.search(this.recordingSearchQuery, this.records.slice(),
        (text: string): void => { if (this.alive && epoch === this.recordingSearchEpoch) { this.recordingSearchStatus = text; } },
        (hits: RecordingSearchHit[]): void => { if (this.alive && epoch === this.recordingSearchEpoch) { this.recordingSearchHits = hits; } });
      if (this.alive && epoch === this.recordingSearchEpoch) {
        this.recordingSearchHits = result.hits; this.recordingSearchAnswer = result.answer;
        this.recordingSearchNotice = result.notice; this.recordingSearchRange = result.range;
      }
    } catch (e) {
      if (this.alive && epoch === this.recordingSearchEpoch) { this.recordingSearchError = (e as Error).message || '搜索未完成，请重试'; }
    } finally {
      if (this.alive && epoch === this.recordingSearchEpoch) { this.recordingSearchBusy = false; this.recordingSearchStatus = ''; }
    }
  }
  private message(error: Error): void { if (this.alive) { this.error = error.message || '操作未完成，请重试'; } }
  private hasCourse(): boolean { return this.courses.some((course: ClassroomCourse): boolean => course.id === this.courseScope); }
  private courseName(id: string): string {
    return this.courses.find((course: ClassroomCourse): boolean => course.id === id)?.name || '未归类';
  }
  private unassignedLessons(): RecordingRecord[] {
    return this.classroomRecords.filter((record: RecordingRecord): boolean => classroomRecordCourse(record, this.courses) === CLASSROOM_UNASSIGNED);
  }
  private resetStudyDraft(): void {
    this.studySelected = []; this.studyMode = '提取要点'; this.studyInstruction = '';
  }
  private studyLessons(fresh: boolean): RecordingRecord[] {
    if (!fresh) { return this.records; }
    if (!this.store || !this.courseStore?.list().some((c: ClassroomCourse): boolean => c.id === this.courseScope)) {
      throw new Error('课程已变更，请重新打开');
    }
    return this.store.list().filter((r: RecordingRecord): boolean => r.source === CLASSROOM_SOURCE && r.classroomCourseId === this.courseScope);
  }
  private openCourse(id: string): void {
    this.resetStudyDraft(); this.courseSection = 'lessons'; this.courseScope = id; this.error = ''; this.status = '';
    try {
      this.reload();
      if (id) { this.recordingListScroller.scrollToIndex(0); }
    } catch (e) { this.message(e as Error); }
  }
  private editCourse(id: string = ''): void {
    this.courseDraft = id ? this.courseName(id) : ''; this.courseError = '';
    this.courseSheetMode = id ? 'rename' : 'create'; this.courseSheetOpen = true;
  }
  private organizeLessons(record: RecordingRecord | null = null): void {
    this.courseSelection = record ? [record.id] : [];
    this.courseError = ''; this.courseSheetMode = record ? 'destination' : 'collect';
    this.courseSheetOpen = true;
  }
  private assignLessons(id: string): boolean {
    if (!this.store || !this.courseStore || !this.courseSelection.length) { return false; }
    let count = 0;
    try {
      if (id && !this.courseStore.list().some((course: ClassroomCourse): boolean => course.id === id)) {
        throw new Error('目标课程已不存在');
      }
      for (const record of this.store.list()) {
        if (!this.courseSelection.includes(record.id) || record.source !== CLASSROOM_SOURCE || record.capturing) { continue; }
        record.classroomCourseId = id || undefined;
        this.store.save(record); count++;
        if (this.selected?.id === record.id) { this.selected = record; }
      }
      this.reload();
      if (!count) { throw new Error('所选课堂已不存在或正在录音'); }
      if (this.selected !== null) {
        this.resetStudyDraft(); this.courseSection = 'lessons'; this.courseScope = id || CLASSROOM_UNASSIGNED; this.reload();
      }
      this.courseSheetOpen = false;
      promptAction.showToast({ message: '已整理 ' + count + ' 节课' });
      return true;
    } catch (e) {
      this.courseError = (count ? '已保存 ' + count + ' 节。' : '') + (e as Error).message;
      try { this.reload(); } catch (_) {}
      return false;
    }
  }
  private saveCourse(): void {
    if (!this.courseStore) { return; }
    try {
      const mode = this.courseSheetMode;
      const course = this.courseStore.saveCourse(this.courseDraft, mode === 'rename' ? this.courseScope : '');
      this.reload();
      if (mode === 'new-destination') {
        this.courseSheetMode = 'destination';
        if (this.assignLessons(course.id) && this.selected === null) { this.openCourse(course.id); }
      } else {
        this.courseSheetOpen = false;
        if (mode === 'create') { this.openCourse(course.id); }
      }
    } catch (e) { this.courseError = (e as Error).message; }
  }
  private async removeCourse(): Promise<void> {
    if (!this.hasCourse() || !this.store) { return; }
    const id = this.courseScope;
    const library = courseLibraryPath(this.store.root, id);
    const service = CodexChatService.get(this.context().filesDir);
    const pending = courseRunIds(library).some((runId: string): boolean => {
      const run = service.load(runId);
      return service.isActive(runId) || (!!run && run.submitted && !['completed', 'cancelled', 'failed'].includes(run.status));
    });
    if (pending) { this.courseError = '请先在课程学伴中结束或同步进行中的委托，再删除课程'; return; }
    const result = await promptAction.showDialog({ title: '删除课程？', message: '课时和已绑定课件会移到「未归类」。课程内未绑定课件、往年试卷和学习成果入口将一并移除。',
      buttons: [{ text: '取消', color: '#737D90' }, { text: '删除课程', color: '#B74D49' }] });
    if (result.index !== 1 || !this.alive || this.courseScope !== id) { return; }
    try {
      this.courseStore?.remove(id); this.courseSheetOpen = false; this.openCourse('');
      if (fs.accessSync(library)) { fs.rmdirSync(library); }
    }
    catch (e) { this.courseError = (e as Error).message; }
  }
  private editClassroomNote(record: RecordingRecord | null): void {
    if (this.busy || (!record && !this.hasCourse())) { return; }
    this.noteRecordId = record?.id || ''; this.noteTitle = record?.title || '';
    this.noteDraft = record?.classroomNotes || ''; this.noteSheetOpen = true;
  }
  private saveClassroomNote(): void {
    if (!this.store || this.busy || !this.noteTitle.trim()) { return; }
    let created: RecordingRecord | null = null;
    let saved = false;
    try {
      let record: RecordingRecord;
      if (this.noteRecordId) {
        const current = this.store.list().find((item: RecordingRecord): boolean => item.id === this.noteRecordId);
        if (!current || current.capturing) { throw new Error('课堂记录已不存在或正在录音'); }
        record = current;
      } else {
        if (!this.hasCourse()) { throw new Error('请先选择课程'); }
        record = this.store.create(CLASSROOM_SOURCE); created = record;
        record.classroomCourseId = this.courseScope; record.classroomNoteOnly = true;
      }
      if (created !== null || record.title !== this.noteTitle.trim()) { record.titleEdited = true; }
      record.title = this.noteTitle.trim(); record.classroomNotes = this.noteDraft.trim();
      this.store.save(record); saved = true;
      this.noteSheetOpen = false;
      this.reload(); this.openRecord(record); this.status = '笔记已保存';
    } catch (e) {
      if (created !== null && !saved) { try { this.store.remove(created.id); } catch (_) {} }
      this.message(e as Error); promptAction.showToast({ message: (e as Error).message || '笔记保存失败' });
    }
  }
  private async importAudio(): Promise<void> {
    if (this.busy || this.watchQueueRunning || this.store === null || (this.classroom && !this.hasCourse())) { return; }
    const courseId = this.classroom ? this.courseScope : '';
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
      let record = await this.store.importWav(uris[0], undefined, 0, courseId);
      if (this.alive && epoch === this.epoch) { this.selected = record; this.reload(); this.filterSpeaker = -2; }
    } catch (e) { this.message(e as Error); }
    finally { this.externalInteraction = false; if (this.alive && epoch === this.epoch) { this.busy = false; this.status = ''; } }
  }
  private async startRecording(note: RecordingRecord | null = null): Promise<void> {
    if (this.busy || this.watchQueueRunning || this.store === null || (this.classroom && !this.hasCourse() && note === null)) { return; }
    if (note !== null && (!note.classroomNoteOnly || this.store.hasAudio(note.id))) { return; }
    let source = recordingAudioSource(this.classroom ? 'environment' : this.audioSource);
    const courseId = this.courseScope;
    this.originalNoteRecording = note;
    this.liveClassroomNotes = note?.classroomNotes || '';
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
      let record: RecordingRecord;
      if (note) {
        record = { schema: note.schema, id: note.id, title: note.title, createdAt: note.createdAt,
          source: CLASSROOM_SOURCE, duration: 0, analysis: null, titleEdited: note.titleEdited,
          classroomCourseId: note.classroomCourseId, classroomNotes: note.classroomNotes };
      } else {
        record = this.store.create(this.classroom ? CLASSROOM_SOURCE : '录制');
        record.title = (this.classroom ? '课堂 ' : '录音 ') + this.clockTime(new Date(record.createdAt));
        if (this.classroom) { record.classroomCourseId = courseId; }
      }
      this.recordingDraft = record;
      if (this.classroom) {
        this.livePhotoDirectory = this.store.directory(record.id) + '/classroom';
        if (!fs.accessSync(this.livePhotoDirectory)) { fs.mkdirSync(this.livePhotoDirectory); }
        this.livePhotos = classroomPhotos(this.livePhotoDirectory);
      }
      const systemAsr = this.useSystemAsr();
      const useLive = this.liveTranscribe && (systemAsr || this.models?.readyForTranscription(false) === true);
      record.transcriptionEngine = systemAsr ? 'system' : 'sensevoice';
      if (useLive) { record.analysis = emptyLiveAnalysis(0); record.transcriptionComplete = false; }
      if (useLive && systemAsr && record.analysis !== null) { record.analysis.modelId = SYSTEM_ASR_MODEL_ID; record.analysis.method = 'system'; }
      record.capturing = true; record.audioSource = source;
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
      if (epoch !== this.epoch) { await this.capture.stop(); this.discardCapture(record); this.recordingDraft = null; return; }
      this.store.save(record);
      await appBackgroundTasks.set(context, 'recording', 'audioRecording', true);
      if (this.captureStopPending) { throw new Error(this.error || '系统已结束录音'); }
      if (epoch !== this.epoch || !this.alive) {
        record.duration = await this.capture.stop(); record.capturing = false;
        if (record.duration >= 0.3) { this.store.save(record); } else { this.discardCapture(record); }
        this.recordingDraft = null;
        await appBackgroundTasks.set(context, 'recording', 'audioRecording', false); return;
      }
      this.recording = true; this.selected = null; this.seconds = 0; this.recordingStartedAt = Date.now();
      this.liveSegments = []; this.livePreviewText = ''; this.livePreviewStart = 0; this.liveStatus = '';
      if (useLive) {
        const live: RecordingLiveTranscriber = systemAsr ? new RecordingSystemAsrRunner() : new RecordingLiveRunner(); this.live = live;
        const checkpoint = new RecordingLiveCheckpoint(systemAsr ? this.store.systemAsrPath(record.id) : this.store.livePath(record.id));
        this.liveStatus = '正在准备实时转写';
        live.start({ audioPath: this.store.audioPath(record.id), modelDir: this.models?.directory || '', language: this.languages[this.languageIndex] },
          (): number => this.capture.availableSamples(), (value: RecordingLiveUpdate): void => {
            if (value.segments.length > 0 || value.kind === 'checkpoint' || value.kind === 'done') { checkpoint.append(value); }
            if (!this.alive || epoch !== this.epoch) { return; }
            this.updateLiveTranscript(live, value);
            const lag = Math.max(0, (this.capture.availableSamples() - value.processed) / 16000);
            this.liveStatus = lag > 8 ? '转写处理中，录音继续保存' : systemAsr ? '系统正在实时转写' : '按说话停顿更新';
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
        } else { this.discardCapture(this.recordingDraft); }
        this.recordingDraft = null;
      }
      this.busy = false;
    } finally {
      this.externalInteraction = false; this.startingRecording = false;
      if (!this.recording) {
        this.originalNoteRecording = null;
        if (this.alive) { this.busy = false; this.jobKind = ''; }
      }
    }
  }
  private discardCapture(record: RecordingRecord): void {
    if (!this.store) { return; }
    const original = this.originalNoteRecording;
    if (record.source !== CLASSROOM_SOURCE || (!original && !this.liveClassroomNotes.trim() && this.livePhotos.length === 0)) {
      this.store.remove(record.id); return;
    }
    // Keep previously created notes and newly written notes when a recording is too short.
    const retained = original || record;
    retained.capturing = false; retained.duration = 0; retained.analysis = null;
    retained.transcriptionComplete = undefined; retained.classroomNoteOnly = true;
    retained.classroomNotes = this.liveClassroomNotes.trim();
    this.store.save(retained);
    const audio = this.store.audioPath(record.id);
    if (fs.accessSync(audio)) { fs.unlinkSync(audio); }
    this.store.clearLiveDraft(record.id); this.store.clearSystemAsrDraft(record.id);
    if (this.alive) { this.selected = retained; this.reload(); }
  }
  private async takeLessonPhoto(): Promise<void> {
    if (!this.recording || !this.classroom || !this.recordingDraft || this.takingPhoto) { return; }
    const directory = this.livePhotoDirectory;
    const seconds = this.capture.availableSamples() / 16000;
    this.takingPhoto = true; this.externalInteraction = true;
    try {
      if (await photographLesson(this.context(), directory, seconds) && this.alive && this.livePhotoDirectory === directory) {
        this.livePhotos = classroomPhotos(directory);
      }
    } catch (e) { promptAction.showToast({ message: (e as Error).message || '照片未保存' }); }
    finally { this.externalInteraction = false; this.takingPhoto = false; }
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
        if (duration < 0.3) { live?.cancel(); this.discardCapture(record); throw new Error('录音过短，请至少录制一秒'); }
        if (record.source === CLASSROOM_SOURCE) { record.classroomNotes = this.liveClassroomNotes.trim(); }
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
          if (record.transcriptionComplete) { this.store.clearLiveDraft(record.id); this.store.clearSystemAsrDraft(record.id); }
        }
        saved = record;
        if (this.alive && epoch === this.epoch) { this.selected = record; this.refreshSelected(); this.reload(); this.detailTab = 'text'; }
      }
    } finally {
      if (!released) { await appBackgroundTasks.set(this.context(), 'recording', 'audioRecording', false).catch((): void => {}); }
      live?.cancel();
      this.originalNoteRecording = null;
      if (this.live === live) { this.live = null; }
      if (this.alive && epoch === this.epoch) {
        this.busy = false; this.jobKind = '';
        this.status = saved?.transcriptionComplete ? '录音与转写已保存' : saved ? '录音已保存' : '';
      }
    }
    if (this.alive && epoch === this.epoch && saved && this.selected?.id === saved.id &&
      this.classroom && !saved.transcriptionComplete && !this.error) {
      await this.analyze(false, this.autoSummary);
      return;
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
    if (this.alive && epoch === this.epoch && !this.error) { await this.resumePendingWatchProcessing(); }
  }
  private saveModelSource(): void {
    if (this.busy || this.models === null) { return; }
    try {
      this.modelDownloadUrl = this.models.setDownloadBaseUrl(this.modelDownloadUrl);
      this.modelSourceSaved = true; this.error = '';
    } catch (e) { this.message(e as Error); }
  }
  private async analyze(restart: boolean = false, summarizeAfter: boolean = this.autoSummary): Promise<RecordingRecord | null> {
    if (this.busy || this.selected === null || this.models === null || this.store === null) { return null; }
    if (!this.store.hasAudio(this.selected.id)) { this.error = '音频已删除，无法重新转写；已有文字和摘要仍可查看'; return null; }
    const systemAsr = this.useSystemAsr(this.selected);
    if (!systemAsr && !this.models.readyForTranscription(this.separateSpeakers)) {
      this.showModels = true; this.error = '请先下载 SenseVoice 语音模型，录音已保存'; return null;
    }
    let record = this.selected; let epoch = ++this.epoch;
    let completed: RecordingRecord | null = null;
    const systemRunner: RecordingSystemAsrRunner | null = systemAsr ? new RecordingSystemAsrRunner() : null;
    this.systemAsr = systemRunner;
    this.busy = true; this.jobKind = 'analysis'; this.progress = 0; this.error = ''; this.status = '正在准备转写';
    try {
      await this.playback.stop();
      if (!this.alive || epoch !== this.epoch) { return null; }
      this.playing = -2;
      const job: RecordingJob = { audioPath: this.store.audioPath(record.id), modelDir: this.models.directory,
        language: this.languages[this.languageIndex], restart: restart, diarization: this.separateSpeakers };
      const report = (value: RecordingWorkerMessage): void => {
        if (this.alive && epoch === this.epoch) { this.progress = value.progress; this.status = value.message; }
      };
      let result: RecordingAnalysis;
      if (systemRunner !== null) {
        if (record.analysis === null || record.transcriptionComplete === false) {
          record.transcriptionEngine = 'system'; record.transcriptionComplete = false; this.store.save(record);
        }
        result = await systemRunner.run(job, this.store.systemAsrPath(record.id), report);
      } else { result = await this.analyzer.run(job, report); }
      if (!this.alive || epoch !== this.epoch) { return null; }
      record.analysis = result; record.transcriptionComplete = true; record.summary = undefined; record.localSummaryDraft = undefined;
      record.transcriptionEngine = systemAsr ? 'system' : 'sensevoice';
      record.duration = result.duration; this.store.save(record);
      this.store.clearAnalysisDraft(record.id);
      this.store.clearLiveDraft(record.id);
      this.store.clearSystemAsrDraft(record.id);
      this.selected = record; this.filterSpeaker = -2; this.visibleSegments = 60; this.reload();
      this.status = result.speech.length === 0 ? '未检测到人声，原录音已保留' : '转写已保存';
      completed = record;
    } catch (e) {
      if (this.alive && epoch === this.epoch) {
        if (systemRunner !== null && (record.analysis === null || record.transcriptionComplete === false)) {
          record.analysis = systemRunner.snapshot(record.duration); record.transcriptionComplete = false;
          try { this.store.save(record); this.selected = record; this.reload(); } catch (saveError) { this.message(saveError as Error); }
        }
        this.message(e as Error);
      }
    }
    finally { if (this.systemAsr === systemRunner) { this.systemAsr = null; } if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
    if (epoch === this.epoch && summarizeAfter && !this.error && record.analysis !== null &&
      record.analysis.segments.some((segment: RecordingSegment): boolean => segment.text.trim().length > 0)) { return await this.summarize(); }
    return epoch === this.epoch ? completed : null;
  }
  private async summarize(restart: boolean = false): Promise<RecordingRecord | null> {
    if (this.busy || this.selected === null || this.store === null) { return null; }
    let record = this.selected; let epoch = ++this.epoch;
    let completed: RecordingRecord | null = null;
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
      if (!this.alive || epoch !== this.epoch) { return null; }
      applyRecordingSummary(record, summary); this.store.save(record); this.selected = record; this.refreshSelected(); this.reload();
      this.detailTab = 'summary'; this.progress = 100; this.status = '摘要已保存';
      completed = record;
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
    return epoch === this.epoch ? completed : null;
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
    this.pendingWatchProcessing = null;
    this.epoch++; this.queueEpoch++; this.queueRemaining = 0; this.watchQueueRunning = false;
    this.analyzer.cancel(); this.systemAsr?.cancel(); this.summaryService.cancel(); this.watchSync.cancel().catch((): void => {});
    this.live?.cancel();
    if (this.models !== null) { this.models.cancel(); }
    this.busy = false; this.jobKind = ''; this.status = transcribing ?
      '转写已暂停，已完成的进度已保存，稍后可继续' : '已停止，录音和已有结果已保留';
  }
  private canResumeAnalysis(): boolean {
    return this.selected !== null && this.store !== null && (this.useSystemAsr(this.selected) ?
      this.store.hasSystemAsrDraft(this.selected.id) : this.store.hasAnalysisDraft(this.selected.id, this.separateSpeakers));
  }
  private useSystemAsr(record: RecordingRecord | null = null): boolean {
    // Watch files use SenseVoice independently of the preference for phone
    // recording/live transcription. Do not overwrite the user's phone setting.
    return record?.watch === undefined && this.transcriptionEngine === 'system' && !this.separateSpeakers;
  }
  private selectTranscriptionEngine(engine: string): void {
    if (this.busy || this.recording) { return; }
    this.transcriptionEngine = engine;
    if (engine === 'system') {
      this.separateSpeakers = false; this.speakerSwitchOn = false; this.liveTranscribe = true;
    }
  }
  private updateLiveTranscript(live: RecordingLiveTranscriber, value: RecordingLiveUpdate): void {
    const preview = value.preview;
    // ForEach rows below represent immutable, committed segments. Bind the
    // changing hypothesis directly to primitive @State so the same sentence
    // updates without relying on a new list key or an observable DTO object.
    this.liveSegments = live.recent().filter((segment: RecordingSegment): boolean =>
      preview === undefined || segment.id !== preview.id);
    this.livePreviewStart = preview?.start || 0;
    this.livePreviewText = preview?.text || '';
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
    this.stopRecordingSearch(false);
    if (this.courseSection === 'lessons') { this.recordingListScroller.closeAllSwipeActions(); }
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
        localSummaryDraft: record.localSummaryDraft, audioDeleted: record.audioDeleted,
        transcriptionComplete: record.transcriptionComplete, transcriptionEngine: record.transcriptionEngine,
        classroomCourseId: record.classroomCourseId, classroomNotes: record.classroomNotes, classroomNoteOnly: record.classroomNoteOnly };
    }
  }
  private beginRename(record: RecordingRecord): void {
    if (this.busy || this.watchQueueRunning) { return; }
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
    if (this.busy || this.watchQueueRunning || record === null || this.store === null) { return; }
    this.recordingListScroller.closeAllSwipeActions();
    let result = await promptAction.showDialog({ title: record.source === CLASSROOM_SOURCE ? '删除这节课？' : '删除这条录音？',
      message: this.recordTitle(record) + (record.source === CLASSROOM_SOURCE ? '\n录音、笔记、照片、附件和本课的资料入口将一起删除。' : '\n录音、转写和摘要将一起删除。') + (record.watch ? '手表原录音会保留。' : ''),
      buttons: [{ text: '取消', color: '#8E8E93' }, { text: '删除', color: '#FF3B30' }] });
    if (result.index !== 1 || this.busy || !this.alive || this.store === null) { return; }
    await this.playback.stop(); this.playing = -2;
    this.store.remove(record.id);
    if (this.selected?.id === record.id) { this.selected = null; }
    this.reload();
    if (this.reference?.recordId === record.id) { this.reference = null; this.comparison = ''; }
  }
  private audioAvailable(): boolean { return this.selected !== null && this.store?.hasAudio(this.selected.id) === true; }
  private async removeAudio(record: RecordingRecord | null = this.selected): Promise<void> {
    if (this.busy || this.watchQueueRunning || record === null || this.store === null || !this.store.hasAudio(record.id)) { return; }
    this.recordingListScroller.closeAllSwipeActions();
    const result = await promptAction.showDialog({ title: '仅删除音频文件？',
      message: '保留这条记录的标题、转写文字、摘要和已有声纹。删除后无法播放或重新转写。' +
        (record.analysis === null || record.transcriptionComplete === false ? '\n这条录音尚未完成转写，删除后无法再从音频恢复文字。' : '') + (record.watch ? '\n手表原录音会保留。' : ''),
      buttons: [{ text: '取消', color: AppTheme.dialogText('#8E8E93') }, { text: '仅删除音频', color: AppTheme.dialogText('#FF3B30') }] });
    if (result.index !== 1 || this.busy || this.watchQueueRunning || !this.alive || this.store === null) { return; }
    const current = this.store.list().find((item: RecordingRecord): boolean => item.id === record.id);
    if (current === undefined) { return; }
    const epoch = ++this.epoch; this.busy = true; this.jobKind = 'delete-audio';
    try {
      await this.playback.stop();
      if (!this.alive || epoch !== this.epoch) { return; }
      this.playing = -2; this.store.removeAudio(current);
      if (this.selected?.id === current.id) { this.selected = current; this.refreshSelected(); }
      this.reload(); this.status = '音频已删除，文字和摘要已保留';
    } finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
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
    if (this.selected === null || this.store === null || this.busy || this.watchQueueRunning) { return; }
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
    if (this.courseSheetOpen) { this.courseSheetOpen = false; return; }
    if (this.noteSheetOpen) { this.noteSheetOpen = false; return; }
    if (this.showWatch) {
      if (this.busy) { this.cancel(); }
      this.showWatch = false; return;
    }
    if (this.showRecordingSettings) {
      if (this.busy) { this.cancel(); return; }
      this.showRecordingSettings = false; return;
    }
    if (this.recording) {
      promptAction.showDialog({ title: '录音仍在继续', message: '结束并保存后可返回，锁屏不会中断录音。',
        buttons: [{ text: '继续录音', color: '#5260ED' }, { text: '结束并保存', color: '#FF453A' }] })
        .then((result): void => { if (result.index === 1) { this.stopRecording().catch((e: Error): void => { this.message(e); }); } });
      return;
    }
    if (this.busy || this.watchQueueRunning) { this.cancel(); return; }
    if (this.recordingSearchBusy) { this.stopRecordingSearch(true); return; }
    if (this.selected !== null) {
      this.save(); this.selected = null; this.playback.stop().catch((): void => {}); this.playing = -2; this.status = ''; return;
    }
    if (this.recordingSearchActive()) { this.changeRecordingSearch(''); return; }
    if (this.classroom && this.courseScope) { this.openCourse(''); return; }
    router.back();
  }
  private openRecordingSettings(): void {
    if (this.busy || this.watchQueueRunning || this.recording) { return; }
    this.stopRecordingSearch(false);
    this.speakerSwitchOn = this.separateSpeakers;
    this.showRecordingSettings = true;
    this.recordingSettingsScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  private openWatchPanel(): void {
    if (this.busy || this.watchQueueRunning || this.recording) { return; }
    this.showWatch = true;
    if (this.watchDevice !== null) { this.loadWatchDevice(this.watchDevice); }
    else { this.scanWatches(); }
  }
  private async scanWatches(): Promise<void> {
    if (this.watchScanning || this.busy || this.watchQueueRunning) { return; }
    this.watchScanning = true; this.watchStatus = '正在查找已配对的手表';
    try {
      const devices = await this.watchSync.discover(this.context());
      if (!this.alive || !this.showWatch) { return; }
      this.watchDevices = devices;
      this.watchStatus = this.watchDevices.length > 0 ? '选择一块手表' : '请先在运动健康中配对手表，并保持连接。';
    } catch (e) { this.watchStatus = (e as Error).message; }
    finally { this.watchScanning = false; }
  }
  private async loadWatchDevice(device: RecordingWatchDevice): Promise<void> {
    if (this.busy || this.watchQueueRunning || this.store === null) { return; }
    const epoch = ++this.epoch;
    const previousSource = this.watchSourceId, previousSelection = this.watchSelectedIds.slice();
    this.watchDevice = device; this.watchSourceId = ''; this.watchItems = []; this.watchSelectedIds = [];
    this.busy = true; this.jobKind = 'watch-list'; this.error = ''; this.watchStatus = '正在连接手表';
    try {
      const catalog = await this.watchSync.catalog(this.context(), device.id, this.store, (text: string): void => {
        if (this.alive && epoch === this.epoch) { this.watchStatus = text; }
      });
      if (!this.alive || epoch !== this.epoch) { return; }
      this.watchItems = catalog.items; this.watchSourceId = catalog.sourceId;
      this.watchSelectedIds = selectWatchRecordings(catalog.items, previousSource === catalog.sourceId ? previousSelection : [], [], true);
      this.watchStatus = catalog.items.length > 0 ? '' : '手表中还没有已完成的录音';
      AppLogger.info('WatchRecording', 'catalog items=' + catalog.items.length);
    } catch (e) {
      if (this.alive && epoch === this.epoch) { this.watchStatus = (e as Error).message; }
    } finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
  }
  private async syncWatchDevice(): Promise<void> {
    if (this.busy || this.watchQueueRunning || this.store === null || this.watchDevice === null) { return; }
    if (this.pendingWatchProcessing !== null) { this.showModels = true; return; }
    const selection: RecordingWatchSelection = { sourceId: this.watchSourceId,
      recordingIds: selectWatchRecordings(this.watchItems, this.watchSelectedIds, [], true) };
    if (!selection.sourceId || selection.recordingIds.length === 0) { return; }
    let epoch = ++this.epoch; let queue = ++this.queueEpoch; let received: RecordingRecord[] = [];
    let transferError = '';
    this.busy = true; this.jobKind = 'watch'; this.error = ''; this.progress = 0;
    AppLogger.info('WatchRecording', 'sync selected=' + selection.recordingIds.length + ' autoAnalyze=' + this.watchAutoAnalyze);
    try {
      let count = await this.watchSync.sync(this.context(), this.watchDevice.id, this.store, (text: string, percent?: number): void => {
        if (this.alive && epoch === this.epoch) {
          this.status = text; this.watchStatus = text;
          if (percent !== undefined) { this.progress = percent; }
        }
      }, (record: RecordingRecord): void => {
        received.push(record);
        if (this.alive && epoch === this.epoch) {
          this.watchSelectedIds = this.watchSelectedIds.filter((id: string): boolean => id !== record.watch?.recordingId);
          this.watchItems = this.watchItems.map((item: RecordingWatchItem): RecordingWatchItem => {
            if (item.id !== record.watch?.recordingId) { return item; }
            return { id: item.id, createdAt: item.createdAt, durationMs: item.durationMs, bytes: item.bytes,
              title: record.title, localState: 'saved' };
          });
          this.reload();
        }
      }, selection);
      if (epoch !== this.epoch) { return; }
      this.watchStatus = '已同步 ' + count + ' 条录音';
      this.status = this.watchStatus;
    } catch (e) {
      if (epoch === this.epoch) {
        transferError = '已接收 ' + received.length + '/' + selection.recordingIds.length + ' 条；' + (e as Error).message;
        this.error = transferError; this.watchStatus = transferError;
        AppLogger.warn('WatchRecording', 'sync failed received=' + received.length + ' error=' + (e as Error).message);
      }
    }
    finally { if (epoch === this.epoch) { this.busy = false; this.jobKind = ''; } }
    if (queue !== this.queueEpoch || !this.alive || !this.watchAutoAnalyze || received.length === 0) { return; }
    // Reserve the queue before dismissing the transfer sheet. Its deferred
    // disappearance callback must not cancel the next transcription stage.
    this.watchQueueRunning = true;
    this.showWatch = false;
    await this.completeWatchProcessing(received, queue, transferError);
  }
  private async completeWatchProcessing(received: RecordingRecord[], queue: number, transferError: string): Promise<void> {
    if (queue !== this.queueEpoch || !this.alive || received.length === 0) { return; }
    const needsTranscription = received.some((record: RecordingRecord): boolean =>
      watchRecordingProcessingStage(record) === 'transcribe');
    if (needsTranscription && (this.models === null || !this.models.readyForTranscription(this.separateSpeakers))) {
      this.pendingWatchProcessing = { recordIds: received.map((record: RecordingRecord): string => record.id),
        queue: queue, transferError: transferError };
      this.watchQueueRunning = false; this.queueRemaining = 0;
      this.status = '已接收 ' + received.length + ' 条录音，下载 SenseVoice 后自动继续转写与摘要';
      this.error = transferError; this.showModels = true;
      AppLogger.info('WatchRecording', 'queue waiting for SenseVoice received=' + received.length);
      return;
    }
    this.pendingWatchProcessing = null;
    this.watchQueueRunning = true; this.showModels = false;
    const failures = await this.processWatchRecordings(received, queue);
    if (this.alive && queue === this.queueEpoch) {
      this.error = [transferError, failures.length > 0 ? failures.length + ' 条录音未处理完成，原录音及已有结果已保留：' + failures.slice(0, 2).join('；') : '']
        .filter((text: string): boolean => text.length > 0).join('\n');
      if (!this.error) { this.status = '已同步 ' + received.length + ' 条录音，转写与摘要处理完成'; }
    }
  }
  private async resumePendingWatchProcessing(): Promise<void> {
    const pending = this.pendingWatchProcessing;
    if (pending === null || !this.alive || pending.queue !== this.queueEpoch || this.busy ||
      this.store === null || this.models === null || !this.models.readyForTranscription(this.separateSpeakers)) { return; }
    // Read current saved records: users may have renamed or removed audio while
    // the download sheet was open. Never restore an old transferred snapshot.
    const ids = new Set<string>(pending.recordIds);
    const received = this.store.list().filter((record: RecordingRecord): boolean => ids.has(record.id));
    this.pendingWatchProcessing = null;
    if (received.length === 0) { this.status = '录音列表已更新'; return; }
    AppLogger.info('WatchRecording', 'queue resuming after SenseVoice preparation received=' + received.length);
    await this.completeWatchProcessing(received, pending.queue, pending.transferError);
  }
  private async processWatchRecordings(received: RecordingRecord[], queue: number): Promise<string[]> {
    const pending = received.filter((record: RecordingRecord): boolean => watchRecordingProcessingStage(record) !== 'done');
    const failures: string[] = [];
    this.watchQueueRunning = true;
    AppLogger.info('WatchRecording', 'queue start received=' + received.length + ' pending=' + pending.length);
    try {
      for (let index = 0; index < pending.length; index++) {
        if (queue !== this.queueEpoch || !this.alive) { break; }
        let record = pending[index];
        this.queueRemaining = pending.length - index; this.selected = record; this.detailTab = 'text';
        this.filterSpeaker = -2; this.visibleSegments = 60; this.error = '';
        this.status = '正在处理手表录音 ' + (index + 1) + '/' + pending.length;
        AppLogger.info('WatchRecording', 'process id=' + record.id + ' stage=' + watchRecordingProcessingStage(record));
        try {
          // The watch queue owns both stages. Do not let the general auto-summary
          // preference skip this queue's requested summary, or run it twice.
          if (watchRecordingProcessingStage(record) === 'transcribe') {
            const transcribed = await this.analyze(false, false);
            if (queue !== this.queueEpoch || !this.alive) { break; }
            if (transcribed === null) { throw new Error(this.error || '转写未完成，录音已保留'); }
            // @State can wrap/replace the selected record. Advance from the
            // operation's saved result, never the stale pre-transfer reference.
            record = transcribed; this.selected = record;
            AppLogger.info('WatchRecording', 'transcribed id=' + record.id + ' item=' + (index + 1) + '/' + pending.length);
          }
          if (queue !== this.queueEpoch || !this.alive) { break; }
          if (!this.error && watchRecordingProcessingStage(record) === 'summarize') {
            const summarized = await this.summarize();
            if (queue !== this.queueEpoch || !this.alive) { break; }
            if (summarized === null) { throw new Error(this.error || '摘要未完成，转写已保留'); }
            record = summarized;
            AppLogger.info('WatchRecording', 'summarized id=' + record.id + ' item=' + (index + 1) + '/' + pending.length);
          }
          if (!this.error && watchRecordingProcessingStage(record) !== 'done') {
            throw new Error('录音尚未处理完成，已有结果已保留');
          }
        } catch (e) { this.error = (e as Error).message; }
        if (queue !== this.queueEpoch || !this.alive) { break; }
        if (this.error) {
          failures.push(this.recordTitle(record) + '：' + this.error);
          AppLogger.warn('WatchRecording', 'process failed id=' + record.id + ' error=' + this.error);
        } else {
          AppLogger.info('WatchRecording', 'process complete id=' + record.id + ' item=' + (index + 1) + '/' + pending.length);
        }
      }
    } finally {
      AppLogger.info('WatchRecording', 'queue finish failed=' + failures.length + ' cancelled=' + (queue !== this.queueEpoch || !this.alive));
      if (queue === this.queueEpoch) { this.queueRemaining = 0; this.watchQueueRunning = false; }
    }
    return failures;
  }
  private watchPanelClosed(): void {
    this.showWatch = false;
    if (!this.watchQueueRunning && (this.jobKind === 'watch' || this.jobKind === 'watch-list')) { this.cancel(); }
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
        Text('SenseVoice 语音模型').fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
        if (this.pendingWatchProcessing !== null) {
          Text('手表录音已保存，下载后自动继续转写与摘要。')
            .fontSize(15).lineHeight(23).fontColor(AppTheme.text('#007AFF')).width('100%')
        }
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
    Row({ space: 12 }) {
      Text('声音来源').fontSize(17).fontColor(AppTheme.text('#172033')).flexShrink(0)
      Text(recordingAudioSourceLabel(this.audioSource)).fontSize(16).fontColor(AppTheme.text('#007AFF'))
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('›').fontSize(24).fontColor(AppTheme.text('#8E8E93'))
    }.width('100%').padding(18).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      .enabled(!this.busy).onClick((): void => { this.showAudioSources = true; })
    Row({ space: 14 }) {
      Image($r('app.media.recording_watch')).width(28).height(28)
      Text('连接手表').fontSize(17).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Text('›').fontSize(24).fontColor(AppTheme.text('#8E8E93'))
    }.padding(18).width('100%').borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      .enabled(!this.busy && !this.watchQueueRunning).onClick((): void => { this.openWatchPanel(); })
    Row() {
      Text('所有录音').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
      Blank()
      Text(String(this.recordingSearchRows().length) + ' 段').fontSize(14).fontColor(AppTheme.text('#8E8E93'))
      Button('全部日期').fontSize(12).height(30).padding({ left: 10, right: 10 }).margin({ left: 8 })
        .fontColor(AppTheme.text(this.calendarScope === 'all' ? '#007AFF' : '#737D90'))
        .backgroundColor(this.calendarScope === 'all' ? AppTheme.background('#E5EEFF') : Color.Transparent)
        .onClick((): void => { this.clearRecordingDate(); })
    }.width('100%').margin({ top: 14, bottom: 4 })
    RecordingCalendarView({ monthTitle: recordingCalendarMonthTitle(this.calendarMonth), weeks: this.calendarWeeks,
      selectedDay: this.calendarScope === 'day' ? this.calendarDay : '', weekIndex: this.calendarWeekIndex, interactive: !this.busy,
      onMonthShift: (offset: number): void => { this.shiftRecordingMonth(offset); },
      onDaySelect: (key: string): void => { this.selectRecordingDay(key); },
      onWeekChange: (index: number): void => { if (index >= 0 && index < this.calendarWeeks.length) { this.calendarWeekIndex = index; } }
    })
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
          Text('仅删音频').fontSize(14).fontColor(Color.White).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.width(84).height(68).padding(0).borderRadius(14)
        .backgroundColor(AppTheme.filledBackground('#CA8425')).fontColor(Color.White)
        .enabled(!this.busy && !this.watchQueueRunning && this.store?.hasAudio(record.id) === true)
        .accessibilityText('仅删除录音文件，保留转写和摘要')
        .onClick((): void => { this.removeAudio(record).catch((e: Error): void => { this.message(e); }); })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Image($r('app.media.recording_delete')).width(21).height(21)
          Text('全部删除').fontSize(14).fontColor(Color.White).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.width(78).height(68).padding(0).borderRadius(14)
        .backgroundColor('#FF3B30').fontColor(Color.White).enabled(!this.busy)
        .accessibilityText('删除录音、转写和摘要')
        .onClick((): void => { this.remove(record).catch((e: Error): void => { this.message(e); }); })
    }.height(68).padding({ left: 10, right: 2 }).alignItems(VerticalAlign.Center)
  }
  @Builder private TimelineRecordingCard(record: RecordingRecord) {
    Row({ space: 8 }) {
      Column() {
        if (this.recordingSearchActive()) {
          Text(this.recordingSearchNumber(record.id)).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#326ADB')).height(20)
        } else {
          Row().width(9).height(9).borderRadius(5).backgroundColor(AppTheme.text('#326ADB'))
        }
        Row().width(1).height(56).margin({ top: 8 }).backgroundColor(AppTheme.border('#D5D9E3'))
      }.width(12).margin({ top: 20 }).flexShrink(0).alignItems(HorizontalAlign.Center)
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          Text(this.recordingCardMeta(record)).fontSize(12).fontColor(AppTheme.text('#737D90'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(recordingCardClock(record, !this.recordingSearchActive() && this.calendarScope === 'day'))
            .fontSize(12).fontColor(AppTheme.text('#8E8E93')).maxLines(1).flexShrink(0)
        }.width('100%')
        Text(this.recordTitle(record)).fontSize(18).fontWeight(FontWeight.Medium).lineHeight(25)
          .fontColor(AppTheme.text('#172033')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.recordingCardText(record)).fontSize(14).lineHeight(22).fontColor(AppTheme.text('#737D90'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        .padding(16).borderRadius(22).backgroundColor(AppTheme.background('#FFFFFF'))
    }.width('100%').alignItems(VerticalAlign.Top).enabled(!this.busy).onClick((): void => { this.openRecord(record); })
  }
  @Builder private SearchControls() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.recordingSearchQuery, placeholder: this.recordingAiSearch ? '例如：上周和谁聊了什么？' : '搜索标题、摘要或转写文字' })
          .id('recording-search-input')
          .fontSize(16).height(44).layoutWeight(1).maxLength(500).enterKeyType(EnterKeyType.Search)
          .fontColor(AppTheme.text('#172033')).placeholderColor(AppTheme.text('#8E8E93'))
          .backgroundColor(AppTheme.background('#EDEFF5')).borderRadius(14)
          .onChange((value: string): void => { this.changeRecordingSearch(value); })
          .onSubmit((): void => { this.runRecordingSearch(); })
        Button(this.recordingSearchBusy ? '停止' : '搜索').fontSize(15).height(44).padding({ left: 12, right: 12 })
          .fontColor(Color.White).backgroundColor(AppTheme.filledBackground(this.recordingSearchBusy ? '#D74D47' : '#326ADB'))
          .enabled(!this.busy)
          .onClick((): void => {
            if (!this.recordingSearchActive()) { this.getUIContext().getFocusController().requestFocus('recording-search-input'); }
            else if (this.recordingSearchBusy) { this.stopRecordingSearch(true); }
            else { this.runRecordingSearch(); }
          })
        if (this.recordingSearchActive()) {
          Button('取消').fontSize(15).height(44).padding({ left: 4, right: 0 })
            .fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
            .onClick((): void => { this.changeRecordingSearch(''); })
        }
      }.width('100%')
    }.width('100%').padding({ left: 22, right: 22, bottom: 10 }).enabled(!this.busy)
  }
  @Builder private SearchFeedback() {
    Column({ space: 12 }) {
      if (this.recordingSearchBusy) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(AppTheme.text('#326ADB'))
          Text(this.recordingSearchStatus || '正在搜索').fontSize(14).fontColor(AppTheme.text('#737D90')).layoutWeight(1)
        }.width('100%')
      }
      if (this.recordingSearchRange) {
        Text(this.recordingSearchRange).fontSize(13).fontColor(AppTheme.text('#8E8E93')).width('100%')
      }
      if (this.recordingSearchAnswer) {
        Column({ space: 10 }) {
          Text('AI 搜索结果').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#326ADB')).width('100%')
          MarkdownView({ text: this.recordingSearchAnswer, variant: 'chat_assistant' })
        }.width('100%').padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      }
      if (this.recordingSearchError) {
        Text(this.recordingSearchError).fontSize(14).lineHeight(21).fontColor(AppTheme.text('#D74D47')).width('100%')
      }
      if (this.recordingSearchNotice) {
        Text(this.recordingSearchNotice).fontSize(13).lineHeight(20).fontColor(AppTheme.text('#737D90')).width('100%')
      }
      Row() {
        Text('相关录音').fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Blank()
        Text(this.recordingSearchHits.length + ' 段').fontSize(14).fontColor(AppTheme.text('#8E8E93'))
      }.width('100%')
    }.width('100%').padding({ top: 4, bottom: 8 })
  }
  @Builder private CourseSectionButton(key: string, label: string) {
    Button(label).layoutWeight(1).height(37).fontSize(14).padding(0)
      .fontWeight(this.courseSection === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.courseSection === key ? Color.White : AppTheme.text('#526B68'))
      .backgroundColor(this.courseSection === key ? AppTheme.filledBackground('#316B69') : Color.Transparent)
      .onClick((): void => { this.courseSection = key; })
  }
  @Builder private CourseSections() {
    Row({ space: 3 }) {
      this.CourseSectionButton('lessons', '课时')
      this.CourseSectionButton('handouts', '课件')
      this.CourseSectionButton('exams', '往年试卷')
      this.CourseSectionButton('study', '学伴')
    }.padding(3).borderRadius(24).backgroundColor(AppTheme.background('#E7F2EF'))
      .margin({ left: 20, right: 20, top: 3, bottom: 3 })
  }
  @Builder private Home() {
    List({ scroller: this.recordingListScroller, space: 14 }) {
      ListItem() {
        Column({ space: 18 }) {
          if (this.classroom) {
            Row({ space: 10 }) {
              Text(this.records.length + ' 节课').fontSize(15).fontColor(AppTheme.text('#737D90'))
              Blank()
              if (this.unassignedLessons().length > 0) {
                Button(this.hasCourse() ? '加入已有笔记' : '批量归类').fontSize(13).height(37)
                  .fontColor(AppTheme.text('#316B69')).backgroundColor(AppTheme.background('#E7F2EF'))
                  .enabled(!this.busy).onClick((): void => { this.organizeLessons(); })
              }
              if (this.hasCourse()) {
                Button('编辑课程').fontSize(13).height(37).fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
                  .enabled(!this.busy).onClick((): void => { this.editCourse(this.courseScope); })
              }
            }.width('100%').padding({ top: 6, bottom: 4 })
          } else if (this.recordingSearchActive()) { this.SearchFeedback() } else { this.HomeHeader() }
        }.width('100%')
      }
      if (this.recordingSearchRows().length === 0) {
        ListItem() {
          Column({ space: 12 }) {
            Image(this.classroom ? $r('app.media.classroom_book') : $r('app.media.source_recording')).width(40).height(40).opacity(0.8)
            Text(this.recordingSearchActive() ? (this.recordingSearchBusy ? '正在寻找相关录音' :
              this.recordingSearchError ? '搜索未完成' : this.recordingSearchNotice === '搜索已停止' ? '搜索已停止' :
              this.recordingSearchRan ? '没有匹配的录音' : '点搜索，我来帮你找') :
              this.classroom ? '还没有课堂记录' : this.calendarScope === 'day' ? '这一天还没有录音' : this.calendarScope === 'month' ? '本月还没有录音' : '暂无录音')
              .fontSize(18).fontColor(AppTheme.text('#737D90'))
            if (!this.recordingSearchActive()) {
              Text(this.classroom ? (this.hasCourse() ? '开始录音、新建笔记，或加入已有的课堂记录。' : '已有课堂都已归入课程。') :
                '轻点下方录音，也可以导入 WAV。')
                .fontSize(15).lineHeight(24).fontColor(AppTheme.text('#8E8E93')).textAlign(TextAlign.Center)
            }
          }.width('100%').padding({ top: 44, bottom: 44 })
        }
      } else {
        ForEach(this.recordingSearchRows(), (record: RecordingRecord) => {
          ListItem() {
            this.TimelineRecordingCard(record)
          }.width('100%').enabled(!this.busy)
            .swipeAction({ end: { builder: (): void => { this.RecordActions(record); } }, edgeEffect: SwipeEdgeEffect.Spring })
        }, (record: RecordingRecord): string => record.id)
      }
      ListItem() { Column({ space: 18 }) { this.Feedback() }.width('100%').padding({ top: 10 }) }
    }.width('100%').layoutWeight(1).padding({ left: 22, right: 22, top: 14, bottom: 12 })
      .contentEndOffset(this.recordingDockVisible() ? RECORDING_DOCK_INSET : 0).scrollBar(BarState.Off)
  }
  @Builder private ClassroomDock() {
    Row({ space: 6 }) {
      if (this.recording) {
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 6 }) {
            Image($r('app.media.classroom_camera')).width(20).height(20)
            Text('拍照').fontSize(15).fontColor(AppTheme.text('#316B69'))
          }
        }.height(42).backgroundColor(Color.Transparent).enabled(!this.takingPhoto)
          .onClick((): void => { this.takeLessonPhoto(); })
      } else {
        Button('笔记').fontSize(14).height(42).fontColor(AppTheme.text('#316B69')).backgroundColor(Color.Transparent)
          .enabled(!this.busy).onClick((): void => { this.editClassroomNote(null); })
        Button('导入').fontSize(14).height(42).fontColor(AppTheme.text('#316B69')).backgroundColor(Color.Transparent)
          .enabled(!this.busy).onClick((): void => { this.importAudio(); })
      }
      Button(this.recording ? '结束课堂' : '上课录音').fontSize(15).fontWeight(FontWeight.Medium).height(42)
        .padding({ left: 24, right: 24 }).fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#316B69'))
        .enabled(!this.takingPhoto && (!this.busy || this.recording)).onClick((): void => {
          if (this.recording) { this.stopRecording().catch((e: Error): void => { this.message(e); }); }
          else { this.startRecording(); }
        })
    }.padding(4).borderRadius(26).backgroundColor($r('app.color.ui_glass_mask'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: ThemeColorMode.SYSTEM })
      .border({ width: 1, color: $r('app.color.ui_glass_border') }).margin({ bottom: 8 })
  }

  @Builder private RecordingDock() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 7 }) {
          Image($r('app.media.recording_import')).width(19).height(19)
          Text('导入').fontSize(14).fontColor(AppTheme.text('#5260ED')).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.layoutWeight(1).height(44).padding(0).borderRadius(22).backgroundColor(Color.Transparent).enabled(!this.busy)
        .accessibilityText('导入 WAV').onClick((): void => { this.importAudio(); })
      Row().width(1).height(20).backgroundColor(AppTheme.border('#D5D9E3'))
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Stack() {
            if (this.recording) { Row().width(11).height(11).borderRadius(3).backgroundColor(Color.White) }
            else { Row().width(18).height(18).borderRadius(9).backgroundColor('#FF453A') }
          }.width(30).height(30).borderRadius(15).border({ width: 1.5, color: '#FF453A' })
            .backgroundColor(this.recording ? '#FF453A' : Color.Transparent)
          Text(this.recording ? '停止' : '录音').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#D74D47')).maxLines(1)
        }.width('100%').justifyContent(FlexAlign.Center)
      }.layoutWeight(1.4).height(44).padding(0).borderRadius(22).backgroundColor(Color.Transparent).enabled(!this.busy || this.recording)
        .accessibilityText(this.recording ? '结束并保存录音' : '开始录音')
        .onClick((): void => { if (this.recording) { this.stopRecording().catch((e: Error): void => { this.message(e); }); } else { this.startRecording(); } })
    }.width(236).constraintSize({ maxWidth: '100%' }).alignItems(VerticalAlign.Center).padding(4).borderRadius(28)
      .backgroundColor($r('app.color.ui_glass_mask'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: ThemeColorMode.SYSTEM })
      .border({ width: 1, color: $r('app.color.ui_glass_border') })
      .shadow({ radius: 12, color: AppTheme.shadow('#18000000'), offsetY: 3 })
      .margin({ bottom: 8 })
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
  @Builder private ClassroomNote(record: RecordingRecord) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('我的笔记').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Blank()
        Button(record.classroomNotes ? '编辑笔记' : '写笔记').fontSize(14).height(38).padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#316B69')).enabled(!this.busy)
          .onClick((): void => { this.editClassroomNote(record); })
      }.width('100%')
      Text(record.classroomNotes || '记下老师强调的要点、问题或补充说明。')
        .fontSize(15).lineHeight(23).fontColor(AppTheme.text(record.classroomNotes ? '#172033' : '#737D90')).width('100%')
      if (record.classroomNoteOnly && this.classroom) {
        Button('为本节课录音').fontSize(14).height(40).width('100%').backgroundColor(AppTheme.background('#E7F2EF'))
          .fontColor(AppTheme.text('#316B69')).enabled(!this.busy).onClick((): void => { this.startRecording(record); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(18)
      .backgroundColor(AppTheme.background('#FFFFFF'))
  }
  private saveLiveClassroomNotes(): void {
    if (!this.store || !this.recordingDraft || !this.recording) { return; }
    try {
      this.recordingDraft.classroomNotes = this.liveClassroomNotes.trim();
      this.store.save(this.recordingDraft);
      promptAction.showToast({ message: '笔记已保存，录音仍在继续' });
    } catch (e) { this.message(e as Error); }
  }
  @Builder private LiveClassroomNote() {
    Column({ space: 8 }) {
      Row() {
        Text('随堂笔记').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Blank()
        Button('保存').fontSize(14).height(36).fontColor(AppTheme.text('#316B69')).backgroundColor(Color.Transparent)
          .onClick((): void => { this.saveLiveClassroomNotes(); })
      }.width('100%')
      TextArea({ text: this.liveClassroomNotes, placeholder: '随手记下重点，结束录音时会一起保存' })
        .width('100%').height(116).fontSize(15).maxLength(CLASSROOM_NOTE_LIMIT)
        .fontColor(AppTheme.text('#172033')).backgroundColor(AppTheme.background('#F4F5FA'))
        .onChange((value: string): void => { this.liveClassroomNotes = value; })
    }.width('100%').padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
  }
  @Builder private Detail() {
    if (this.selected !== null) {
      Column({ space: 14 }) {
        Row({ space: 10 }) {
          Text(this.recordDate(this.selected, false)).fontSize(13).fontColor(AppTheme.text('#737D90'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.classroom) {
            Button(this.courseName(this.selected.classroomCourseId || '') + '  ›').fontSize(13).height(36).constraintSize({ maxWidth: '56%' })
              .fontColor(AppTheme.text('#316B69')).backgroundColor(AppTheme.background('#E7F2EF')).enabled(!this.busy)
              .accessibilityText('更改课程归属')
              .onClick((): void => { if (this.selected) { this.organizeLessons(this.selected); } })
          }
        }.width('100%')
        if (!this.selected.classroomNoteOnly) {
        Row({ space: 12 }) {
          Button({ type: ButtonType.Circle }) {
            Image(this.playing === -1 ? $r('app.media.recording_stop') : $r('app.media.recording_play')).width(21).height(21)
          }.width(42).height(42).backgroundColor(AppTheme.background('#EDEFFC')).enabled(!this.busy && this.audioAvailable())
            .accessibilityText(this.playing === -1 ? '停止播放' : '播放录音').onClick((): void => { this.play(null); })
          Column({ space: 8 }) {
            Row() {
              Text(!this.audioAvailable() ? '音频已删除' : this.playing === -1 ? '正在播放' : '原始录音').fontSize(13).fontColor(AppTheme.text('#737D90'))
              Blank()
              Text(recordingTime(this.selected.duration)).fontSize(13).fontColor(AppTheme.text('#737D90'))
            }.width('100%')
            this.VoiceTimeline()
          }.layoutWeight(1)
        }.width('100%').padding(12).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
        }
        if (this.selected.source === CLASSROOM_SOURCE && this.store !== null) {
          this.ClassroomNote(this.selected)
          ClassroomMaterialsView({ directory: this.store.directory(this.selected.id) + '/classroom',
            getRecord: (): RecordingRecord | null => this.selected, working: this.busy || this.takingPhoto,
            photoRevision: this.livePhotos.length,
            courseTitle: this.classroom && this.courseScope !== CLASSROOM_UNASSIGNED ? this.courseName(this.courseScope) : '',
            noteAvailable: !!this.selected.classroomNotes?.trim(),
            needsTranscript: !this.selected.analysis || this.selected.transcriptionComplete === false,
            canPrepare: (!this.selected.summary || this.selected.summary.complete === false) &&
              (this.audioAvailable() || (!!this.selected.analysis && this.selected.transcriptionComplete !== false)),
            onPrepare: (): void => {
              if (!this.selected?.analysis || this.selected.transcriptionComplete === false) { this.analyze(false, true); }
              else { this.summarize(); }
            },
            ready: this.classroomHasText(this.selected) })
        }
        if (this.selected.source !== CLASSROOM_SOURCE && !this.busy && this.audioAvailable() && this.analysis() !== null && (this.canResumeAnalysis() || this.selected.transcriptionComplete === false)) {
          Button(this.canResumeAnalysis() ? '继续转写' : '完成转写').fontSize(17).height(48).padding({ left: 28, right: 28 })
            .width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#5260ED'))
            .onClick((): void => { this.analyze(); })
        }
        if (this.analysis() === null) {
          if (this.selected.source !== CLASSROOM_SOURCE && !this.busy && this.audioAvailable()) {
            Button(this.canResumeAnalysis() ? '继续转写' : '开始转写').fontSize(17).height(48).padding({ left: 28, right: 28 })
              .width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#5260ED'))
              .onClick((): void => { this.analyze(); })
          }
          if (!this.audioAvailable() && !this.selected.classroomNoteOnly) {
            Text('音频已删除，这条记录没有可用的转写文字。').fontSize(15).fontColor(AppTheme.text('#8E8E93')).width('100%')
          }
        } else {
          Row({ space: 8 }) {
            Button('转写文本').fontSize(15).fontWeight(FontWeight.Medium).height(36).padding({ left: 18, right: 18 })
              .backgroundColor(this.detailTab === 'text' ? AppTheme.filledBackground('#172033') : AppTheme.background('#EDEFF5'))
              .fontColor(this.detailTab === 'text' ? Color.White : AppTheme.text('#737D90'))
              .onClick((): void => { this.detailTab = 'text'; })
            Button('AI 摘要').fontSize(15).fontWeight(FontWeight.Medium).height(36).padding({ left: 18, right: 18 })
              .backgroundColor(this.detailTab === 'summary' ? AppTheme.filledBackground('#172033') : AppTheme.background('#EDEFF5'))
              .fontColor(this.detailTab === 'summary' ? Color.White : AppTheme.text('#737D90'))
              .onClick((): void => { this.detailTab = 'summary'; })
            Blank()
            if (this.detailTab === 'text') {
              Button('说话人').fontSize(13).height(36).padding({ left: 6, right: 6 })
                .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5260ED'))
                .onClick((): void => { this.showSpeakers = true; })
            }
          }.width('100%').padding({ top: 2, bottom: 2 })
          Column({ space: 14 }) {
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
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
      }.width('100%').alignItems(HorizontalAlign.Start).enabled(!this.watchQueueRunning)
    }
  }
  private classroomHasText(record: RecordingRecord): boolean {
    return (record.summary !== undefined && record.summary.complete !== false) ||
      (record.transcriptionComplete !== false && record.analysis?.segments.some((segment: RecordingSegment): boolean => !!segment.text.trim()) === true);
  }
  @Builder private Transcript() {
    // One reading column owns all paragraph spacing. Expanded builder children
    // must not inherit the surrounding detail column's card spacing.
    Column({ space: 0 }) {
      if (this.filterSpeaker !== -2) {
        Text('仅看 ' + this.speakerName(this.filterSpeaker) + ' · 显示全部').fontSize(13).fontColor(AppTheme.text('#5260ED'))
          .padding({ top: 4, bottom: 12 }).onClick((): void => { this.filterSpeaker = -2; this.visibleSegments = 60; })
      }
      if (this.segments().length === 0) {
        Text('这段录音没有可转写的人声。').fontSize(16).fontColor(AppTheme.text('#8E8E93')).padding({ top: 12, bottom: 12 })
      }
      ForEach(this.filteredSegments(), (segment: RecordingSegment) => {
        Column({ space: 6 }) {
          Row({ space: 9 }) {
            Row({ space: 5 }) {
              Row().width(5).height(5).borderRadius(3)
                .backgroundColor(segment.speaker < 0 ? AppTheme.text('#326ADB') : this.color(segment.speaker))
              Text(this.speakerName(segment.speaker)).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(segment.speaker < 0 ? AppTheme.text('#326ADB') : this.color(segment.speaker))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 140 })
            }.padding({ left: 7, right: 7, top: 4, bottom: 4 }).borderRadius(6).backgroundColor(AppTheme.background('#EAF0FB'))
            Text(recordingTime(segment.start)).fontSize(12).fontColor(AppTheme.text('#8E8E93'))
            Blank()
            Button({ type: ButtonType.Circle }) {
              Image(this.playing === segment.id ? $r('app.media.recording_stop') : $r('app.media.recording_play')).width(14).height(14)
            }.width(32).height(32)
              .backgroundColor(this.playing === segment.id ? AppTheme.background('#E6EBFF') : Color.Transparent)
              .enabled(!this.busy && this.audioAvailable()).accessibilityText(this.playing === segment.id ? '停止播放这段对话' : '播放这段对话')
              .onClick((): void => { this.play(segment); })
          }.width('100%').height(32)
          Text(segment.text || '未识别到文字').fontSize(17).lineHeight(27).fontColor(AppTheme.text('#172033'))
            .width('100%').copyOption(CopyOptions.InApp)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 16 })
      }, (segment: RecordingSegment): string => String(segment.id) + segment.text)
      if (this.segments().length > this.visibleSegments) {
        Text('继续阅读').fontSize(15).fontColor(AppTheme.text('#5260ED')).padding({ top: 8, bottom: 12 })
          .onClick((): void => { this.visibleSegments += 60; })
      }
      if (this.selected?.transcriptionComplete === false) {
        Text('部分转写已保存，可继续完成。').fontSize(13).lineHeight(21).fontColor(AppTheme.text('#B27A28'))
          .width('100%').padding({ top: 8, bottom: 8 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder private SettingsContent() {
    Scroll(this.recordingSettingsScroller) {
      RecordingSettingsView({ busy: this.busy, separateSpeakers: this.separateSpeakers,
        speakerSwitchOn: this.speakerSwitchOn, confirmingSpeakers: this.confirmingSpeakerSeparation,
        modelsReady: this.modelCount === RECORDING_MODELS.length, hasRecord: this.selected !== null,
        watchRecording: this.selected?.watch !== undefined,
        hasAudio: this.audioAvailable(), canResume: this.canResumeAnalysis(),
        onEngineChange: (engine: string): void => { this.selectTranscriptionEngine(engine); },
        onSpeakerChange: (value: boolean): void => { this.setSpeakerSeparation(value).catch((e: Error): void => { this.message(e); }); },
        onSearchModeChange: (value: boolean): void => { this.recordingAiSearch = value; this.changeRecordingSearch(this.recordingSearchQuery); },
        onModels: (): void => { this.showModels = true; },
        onRename: (): void => {
          if (this.selected !== null) { this.showRecordingSettings = false; this.beginRename(this.selected); }
        },
        onSpeakers: (): void => { this.showSpeakers = true; },
        onTranscribe: (): void => {
          this.showRecordingSettings = false; this.chooseAnalysis().catch((e: Error): void => { this.message(e); });
        },
        onSummarize: (): void => { this.showRecordingSettings = false; this.summarize(true); },
        onDeleteAudio: (): void => { this.removeAudio().catch((e: Error): void => { this.message(e); }); },
        onDelete: (): void => {
          this.remove().then((): void => { if (this.selected === null) { this.showRecordingSettings = false; } })
            .catch((e: Error): void => { this.message(e); });
        },
        feedbackBuilder: (): void => { this.Feedback(); }
      }).width('100%').padding({ left: 22, right: 22, top: 12, bottom: 28 })
    }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
  }
  @Builder private WatchPanel() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        if (this.watchDevice !== null) {
          Button('‹').fontSize(28).width(36).height(40).padding(0)
            .fontColor(AppTheme.text('#172033')).backgroundColor(Color.Transparent).accessibilityText('返回手表列表')
            .onClick((): void => {
              if (this.busy) { this.cancel(); }
              this.watchDevice = null; this.watchSourceId = ''; this.watchItems = []; this.watchSelectedIds = [];
              this.watchStatus = '选择一块手表';
            })
        }
        Text(this.watchDevice?.name || '连接手表').fontSize(21).fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text('#172033')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button(this.busy ? '停止' : '刷新').fontSize(14).height(40).padding({ left: 8, right: 0 })
          .fontColor(AppTheme.text('#007AFF')).backgroundColor(Color.Transparent).enabled(!this.watchScanning)
          .onClick((): void => {
            if (this.busy) { this.cancel(); }
            else if (this.watchDevice !== null) { this.loadWatchDevice(this.watchDevice); }
            else { this.scanWatches(); }
          })
      }.width('100%').padding({ right: 26 })
      if (this.watchStatus || this.watchScanning || this.busy) {
        Row({ space: 8 }) {
          if (this.watchScanning || this.busy) { LoadingProgress().width(18).height(18).color(AppTheme.text('#007AFF')) }
          Text(this.watchStatus).fontSize(14).lineHeight(21).fontColor(AppTheme.text('#737D90'))
            .layoutWeight(1).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }
      if (this.jobKind === 'watch') { Progress({ value: this.progress, total: 100, type: ProgressType.Linear }).width('100%') }
      if (this.watchDevice !== null && this.watchSourceId.length > 0) {
        WatchRecordingPickerView({ items: this.watchItems, selectedIds: this.watchSelectedIds,
          busy: this.busy, autoAnalyze: this.watchAutoAnalyze,
          onSelectionChange: (ids: string[]): void => { this.watchSelectedIds = ids; },
          onAutoAnalyzeChange: (value: boolean): void => { this.watchAutoAnalyze = value; },
          onSync: (): void => { this.syncWatchDevice().catch((e: Error): void => { this.message(e); }); }
        }).layoutWeight(1)
      } else if (this.watchDevice === null) {
        List({ space: 10 }) {
          ForEach(this.watchDevices, (device: RecordingWatchDevice) => {
            ListItem() {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 12 }) {
                  Image($r('app.media.recording_watch')).width(30).height(30)
                  Text(device.name).fontSize(17).fontWeight(FontWeight.Medium)
                    .fontColor(AppTheme.text('#172033')).layoutWeight(1)
                  Text('›').fontSize(23).fontColor(AppTheme.text('#8E8E93'))
                }.width('100%')
              }.width('100%').padding(18).borderRadius(18).backgroundColor(AppTheme.background('#F4F5FA'))
                .enabled(!this.busy && !this.watchScanning).onClick((): void => { this.loadWatchDevice(device); })
            }
          }, (device: RecordingWatchDevice): string => device.id)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      } else { Blank() }
    }.padding({ left: 22, right: 22, top: 28, bottom: 18 }).width('100%').height('100%').alignItems(HorizontalAlign.Start)
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
    if ((this.busy || this.watchQueueRunning) && !this.recording) {
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
    if (this.status.length > 0 && !this.busy && !this.watchQueueRunning) { Text(this.status).fontSize(15).lineHeight(24).fontColor(AppTheme.text('#737D90')).width('100%') }
  }
  @Builder private Content() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.showRecordingSettings) { this.SettingsContent() }
        else if (this.selected === null && !this.recording) {
          if (this.classroom && !this.courseScope) {
            ClassroomCourseView({ courses: this.courseRows, scroller: this.classroomCourseScroller,
              onCreate: (): void => { this.editCourse(); },
              onOpen: (id: string): void => { this.openCourse(id); } })
            if (this.error) { Text(this.error).fontSize(14).fontColor(AppTheme.text('#B74D49')).padding(16).width('100%') }
          } else {
            if (this.classroom && this.hasCourse()) { this.CourseSections() }
            if (this.classroom && this.hasCourse() && this.courseSection !== 'lessons' && this.store !== null) {
              CourseStudyView({ root: this.store.root, courseId: this.courseScope, courseTitle: this.courseName(this.courseScope),
                section: $courseSection, selected: $studySelected, mode: $studyMode, instruction: $studyInstruction,
                scroller: this.studyScroller, getLessons: (fresh: boolean): RecordingRecord[] => this.studyLessons(fresh),
                onLesson: (id: string): void => {
                  const record = this.records.find((row: RecordingRecord): boolean => row.id === id);
                  if (record) { this.openRecord(record); }
                } })
            } else {
              if (!this.classroom) { this.SearchControls() }
              this.Home()
            }
          }
        }
        else {
          Scroll(this.scroller) {
            Column({ space: 18 }) {
              if (this.recording) {
                Column({ space: 24 }) {
                  Text(this.classroom ? '课堂进行中' : '正在录音').fontSize(20).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                  Text(recordingTime(this.seconds)).fontSize(48).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#FF453A'))
                  Text(this.classroom ? '随堂照片 ' + this.livePhotos.length + ' 张' : recordingAudioSourceLabel(this.audioSource)).fontSize(17).fontColor(AppTheme.text('#8E8E93'))
                }.width('100%').padding({ top: 26, bottom: 24 })
                if (this.classroom && this.livePhotos.length > 0) {
                  ClassroomPhotoStrip({ photos: this.livePhotos, directory: this.livePhotoDirectory })
                }
                if (this.classroom) { this.LiveClassroomNote() }
                if (this.liveStatus) {
                  Column({ space: 14 }) {
                    Row() {
                      Text('实时转写').fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                      Blank()
                      if (this.live !== null && this.liveSegments.length === 0 && !this.livePreviewText) { LoadingProgress().width(20).height(20).color(AppTheme.text('#5260ED')) }
                    }.width('100%')
                    if (this.liveSegments.length === 0 && !this.livePreviewText) {
                      Text(this.live !== null ? '说话后稍作停顿，文字会出现在这里。' : this.liveStatus).fontSize(15).lineHeight(25).fontColor(AppTheme.text('#8E8E93')).width('100%')
                    }
                    ForEach(this.liveSegments.slice(this.livePreviewText ? -2 : -3), (segment: RecordingSegment) => {
                      Column({ space: 5 }) {
                        Text(recordingTime(segment.start)).fontSize(12).fontColor(AppTheme.text('#8E8E93')).width('100%')
                        Text(this.useSystemAsr() ? segment.text.slice(-100) : segment.text)
                          .fontSize(17).lineHeight(27).fontColor(AppTheme.text('#25304A')).width('100%')
                      }.width('100%').alignItems(HorizontalAlign.Start)
                    }, (segment: RecordingSegment): string => segment.id + ':' + segment.start)
                    if (this.livePreviewText) {
                      Column({ space: 5 }) {
                        Text(recordingTime(this.livePreviewStart)).fontSize(12).fontColor(AppTheme.text('#8E8E93')).width('100%')
                        Text(this.livePreviewText.slice(-100)).fontSize(17).lineHeight(27).fontColor(AppTheme.text('#25304A')).width('100%')
                      }.width('100%').alignItems(HorizontalAlign.Start)
                    }
                    Text(this.liveStatus).fontSize(12).fontColor(AppTheme.text('#8E8E93')).width('100%')
                  }.width('100%').alignItems(HorizontalAlign.Start).padding(20).borderRadius(20).backgroundColor(AppTheme.background('#FFFFFF'))
                }
              } else { this.Detail() }
              this.Feedback()
            }.width('100%').padding({ left: 20, right: 20, top: this.recording ? 14 : 2,
              bottom: this.recordingDockVisible() ? RECORDING_DOCK_INSET + 12 : 28 })
          }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
        }
      }.width('100%').height('100%').padding({ top: APP_HEADER_CONTENT_GAP })
      if (this.recordingDockVisible()) {
        if (this.classroom) { this.ClassroomDock() } else { this.RecordingDock() }
      }
    }.width('100%').height('100%')
  }
  @Builder private PageHeader() {
    AppHeader({ title: this.showRecordingSettings ? '录音设置' : this.selected === null ?
      (this.classroom ? (this.courseScope ? this.courseName(this.courseScope) : '智慧课堂') : '录音') : this.recordTitle(this.selected),
      showBackButton: true, actionLabel: this.showRecordingSettings ? '' : '更多',
      onBackClick: (): void => { this.goBack(); }, onActionClick: (): void => { this.openRecordingSettings(); } })
  }
  @Builder private ClassroomCourseSheet() {
    Column({ space: 14 }) {
      Text(this.courseSheetMode === 'collect' ? '选择已有课堂' : this.courseSheetMode === 'destination' ? '归入课程' :
        this.courseSheetMode === 'rename' ? '编辑课程' : '新建课程')
        .fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      if (this.courseSheetMode === 'collect') {
        Row() {
          Text('已选 ' + this.courseSelection.length + ' 节').fontSize(14).fontColor(AppTheme.text('#737D90'))
          Blank()
          Button(this.courseSelection.length === this.unassignedLessons().length ? '清空' : '全选')
            .fontSize(14).height(36).fontColor(AppTheme.text('#316B69')).backgroundColor(Color.Transparent)
            .onClick((): void => {
              this.courseSelection = this.courseSelection.length === this.unassignedLessons().length ? [] :
                this.unassignedLessons().map((record: RecordingRecord): string => record.id);
            })
        }.width('100%')
        List({ space: 8 }) {
          ForEach(this.unassignedLessons(), (record: RecordingRecord) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(this.recordTitle(record)).fontSize(16).fontColor(AppTheme.text('#172033'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  Text(this.recordDate(record, false)).fontSize(12).fontColor(AppTheme.text('#737D90'))
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text(this.courseSelection.includes(record.id) ? '✓' : '○').fontSize(20).fontColor(AppTheme.text('#316B69'))
              }.width('100%').padding(13).borderRadius(14).backgroundColor(AppTheme.background('#F4F5FA'))
                .onClick((): void => {
                  this.courseSelection = this.courseSelection.includes(record.id) ?
                    this.courseSelection.filter((id: string): boolean => id !== record.id) : this.courseSelection.concat([record.id]);
                })
            }
          }, (record: RecordingRecord): string => record.id)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        Button(this.hasCourse() ? '加入当前课程' : '选择课程').height(42).width('100%').fontColor(Color.White)
          .backgroundColor(AppTheme.filledBackground('#316B69')).enabled(this.courseSelection.length > 0)
          .onClick((): void => { if (this.hasCourse()) { this.assignLessons(this.courseScope); } else { this.courseSheetMode = 'destination'; } })
      } else if (this.courseSheetMode === 'destination') {
        Text('将 ' + this.courseSelection.length + ' 节课归入已有或新课程。')
          .fontSize(14).fontColor(AppTheme.text('#737D90')).width('100%')
        List({ space: 8 }) {
          ForEach(this.courses, (course: ClassroomCourse) => {
            ListItem() {
              Button(course.name).height(46).width('100%').fontSize(15).fontColor(AppTheme.text('#172033'))
                .backgroundColor(AppTheme.background('#F4F5FA')).onClick((): void => { this.assignLessons(course.id); })
            }
          }, (course: ClassroomCourse): string => course.id)
          if (this.selected && classroomRecordCourse(this.selected, this.courses) !== CLASSROOM_UNASSIGNED) {
            ListItem() {
              Button('移到未归类').height(46).width('100%').fontSize(14).fontColor(AppTheme.text('#737D90'))
                .backgroundColor(AppTheme.background('#F4F5FA')).onClick((): void => { this.assignLessons(''); })
            }
          }
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        Button('+ 新建课程并加入').height(42).width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#316B69'))
          .onClick((): void => { this.courseDraft = ''; this.courseError = ''; this.courseSheetMode = 'new-destination'; })
      } else {
        TextInput({ text: this.courseDraft, placeholder: '例如：线性代数' }).maxLength(48).width('100%').height(50)
          .backgroundColor(AppTheme.background('#F4F5FA')).fontColor(AppTheme.text('#172033'))
          .onChange((value: string): void => { this.courseDraft = value; this.courseError = ''; })
        Button(this.courseSheetMode === 'new-destination' ? '创建并加入' : '保存课程').height(42).width('100%').fontColor(Color.White)
          .backgroundColor(AppTheme.filledBackground('#316B69')).enabled(this.courseDraft.trim().length > 0)
          .onClick((): void => { this.saveCourse(); })
        if (this.courseSheetMode === 'rename') {
          Button('删除课程').height(42).width('100%').fontColor(AppTheme.text('#B74D49')).backgroundColor(Color.Transparent)
            .onClick((): void => { this.removeCourse().catch((e: Error): void => { this.courseError = e.message; }); })
        } else if (this.courseSheetMode === 'new-destination') {
          Button('返回课程选择').height(38).width('100%').fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
            .onClick((): void => { this.courseSheetMode = 'destination'; })
        }
      }
      if (this.courseError) { Text(this.courseError).fontSize(13).fontColor(AppTheme.text('#B74D49')).width('100%') }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 22, right: 22, top: 36, bottom: 24 })
  }
  @Builder private ClassroomNoteSheet() {
    Column({ space: 14 }) {
      Text(this.noteRecordId ? '编辑课堂笔记' : '新建课堂笔记').fontSize(23).fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.text('#172033')).width('100%')
      TextInput({ text: this.noteTitle, placeholder: '本节课的标题' }).width('100%').height(48).maxLength(80)
        .backgroundColor(AppTheme.background('#F4F5FA')).fontColor(AppTheme.text('#172033'))
        .onChange((value: string): void => { this.noteTitle = value; })
      TextArea({ text: this.noteDraft, placeholder: '记下重点、例题和问题' }).width('100%').layoutWeight(1)
        .fontSize(15).maxLength(CLASSROOM_NOTE_LIMIT).backgroundColor(AppTheme.background('#F4F5FA'))
        .fontColor(AppTheme.text('#172033')).onChange((value: string): void => { this.noteDraft = value; })
      Button('保存笔记').height(42).width('100%').fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#316B69'))
        .enabled(this.noteTitle.trim().length > 0).onClick((): void => { this.saveClassroomNote(); })
    }.width('100%').height('100%').padding({ left: 22, right: 22, top: 36, bottom: 24 })
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
    }.padding(24).width('100%')
  }
  build() {
    Stack() {
      FrostedPage({ pageBackgroundColor: '#F6F7FA', titleFadeHeight: RECORDING_TITLE_FADE_HEIGHT,
        scrollers: this.showRecordingSettings ? [this.recordingSettingsScroller] :
          (this.selected === null && !this.recording ?
            (this.classroom && !this.courseScope ? [this.classroomCourseScroller] :
              this.classroom && this.courseSection !== 'lessons' ? [this.studyScroller] : [this.recordingListScroller]) : [this.scroller]),
        headerBuilder: (): void => { this.PageHeader(); }, contentBuilder: (): void => { this.Content(); } })
      Row().width(0).height(0)
        .bindSheet(this.showAudioSources, this.AudioSourcesPanel(), { height: 460, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showAudioSources = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showModels, this.ModelsPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showModels = false; } })
      Row().width(0).height(0)
        .bindSheet(this.showWatch, this.WatchPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.watchPanelClosed(); } })
      Row().width(0).height(0)
        .bindSheet(this.showSpeakers, this.SpeakersPanel(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showSpeakers = false; this.save(); } })
      Row().width(0).height(0)
        .bindSheet(this.showRename, this.RenamePanel(), { height: 300, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.showRename = false; this.renameTarget = null; } })
      Row().width(0).height(0)
        .bindSheet(this.courseSheetOpen, this.ClassroomCourseSheet(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.courseSheetOpen = false; } })
      Row().width(0).height(0)
        .bindSheet(this.noteSheetOpen, this.ClassroomNoteSheet(), { height: SheetSize.LARGE, showClose: true,
          backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.noteSheetOpen = false; } })
    }.width('100%').height('100%')
  }
}
